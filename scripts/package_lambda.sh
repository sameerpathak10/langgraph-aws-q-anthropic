#!/usr/bin/env bash
set -euo pipefail

REQ=${1:-requirements.txt}
SRCDIR=${2:-.}
OUT=${3:-langgraph_lambda.zip}
BUILD=build
SLIM=false
SLIM_REQ="requirements-slim.txt"
# Target platform and size threshold (MB)
TARGET=${5:-linux}
MAX_ZIP_MB=${6:-50}
# optional 4th arg: --slim
if [ "${4:-}" = "--slim" ]; then
  SLIM=true
fi

echo "Packaging Lambda: output -> $OUT"

rm -rf "$BUILD"
mkdir -p "$BUILD"

if [ -f "$REQ" ]; then
  python -m pip install --upgrade pip
  if [ "$SLIM" = "true" ]; then
    echo "Slim mode requested"
    if [ -f "$SLIM_REQ" ]; then
      echo "Installing SLIM requirements from $SLIM_REQ..."
      if [ -f constraints.txt ]; then
        echo "Applying constraints from constraints.txt"
        python -m pip install -r "$SLIM_REQ" -c constraints.txt -t "$BUILD"
      else
        python -m pip install -r "$SLIM_REQ" -t "$BUILD"
      fi
      if [ $? -ne 0 ]; then
        echo "pip install for slim requirements failed. Aborting packaging.";
        exit 1
      fi
    else
      echo "No $SLIM_REQ found; installing regular requirements then pruning heavy files..."
      if [ -f constraints.txt ]; then
        python -m pip install -r "$REQ" -c constraints.txt -t "$BUILD"
      else
        python -m pip install -r "$REQ" -t "$BUILD"
      fi
      if [ $? -ne 0 ]; then
        echo "pip install failed. Aborting packaging.";
        exit 1
      fi

      echo "Pruning heavy packages and unnecessary files to create a slim package..."
      HEAVY_PKGS=(numpy scipy pandas zstandard xxhash orjson)
      for pkg in "${HEAVY_PKGS[@]}"; do
        echo "Removing package files matching: $pkg"
        find "$BUILD" -type d -name "$pkg*" -prune -exec rm -rf '{}' + 2>/dev/null || true
      done

      # Remove tests, docs and caches
      find "$BUILD" -type d \( -name tests -o -name test -o -name __pycache__ -o -name docs -o -name examples -o -name bench \) -prune -exec rm -rf '{}' + 2>/dev/null || true
      # Remove compiled and stub files
      find "$BUILD" -type f \( -name "*test*.*" -o -name "*.pyc" -o -name "*.pyo" -o -name "*.pyi" -o -name "*.whl" \) -delete 2>/dev/null || true

      # If target is linux, remove windows-specific binaries
      if [ "$TARGET" = "linux" ]; then
        echo "Targeting linux: removing Windows binaries (*.pyd, *.dll) from build to reduce size"
        find "$BUILD" -type f \( -name "*.pyd" -o -name "*.dll" \) -delete 2>/dev/null || true
      fi
    fi
  else
    echo "Installing dependencies from $REQ..."
    echo "Using local pip to install dependencies..."
    if [ -f constraints.txt ]; then
      echo "Applying constraints from constraints.txt"
      python -m pip install -r "$REQ" -c constraints.txt -t "$BUI
LD"
    else
      python -m pip install -r "$REQ" -t "$BUILD"
    fi
    if [ $? -ne 0 ]; then
      echo "pip install failed. Aborting packaging.";
      exit 1
    fi
  fi
else
  echo "No requirements file found ($REQ) - skipping deps"
fi

# Validate required modules are present (fail fast if missing)
required=("langgraph" "langchain_core" "langchain_aws" "boto3")
for mod in "${required[@]}"; do
  if ! ( find "$BUILD" -maxdepth 2 -type d -name "$mod" -print -quit >/dev/null 2>&1 || find "$BUILD" -maxdepth 2 -type d -name "$mod-*.dist-info" -print -quit >/dev/null 2>&1 ); then
    echo "Required module $mod not found in $BUILD; aborting packaging. Please ensure dependencies installed or add $mod to your slim requirements."
    exit 1
  fi
done

echo "Copying source files..."
cp "$SRCDIR/main.py" "$BUILD/" || echo "Warning: main.py not found"

echo "Creating $OUT..."
( cd "$BUILD" && zip -r "../$OUT" . )

SIZE_MB=$(du -m "../$OUT" | awk '{print $1}') || SIZE_MB=0
echo "Package size: ${SIZE_MB} MB"
if [ "$SIZE_MB" -gt "$MAX_ZIP_MB" ]; then
  echo "Package size ($SIZE_MB MB) exceeds maximum allowed ($MAX_ZIP_MB MB). Aborting. Consider using a slimmer requirements file or Lambda Layers."
  exit 2
fi

echo "Package created: $OUT"
echo "To upload to S3: aws s3 cp $OUT s3://<your-bucket>/<your-key>"