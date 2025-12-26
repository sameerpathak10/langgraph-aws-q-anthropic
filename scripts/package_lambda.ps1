Param(
    [string]$RequirementsFile = "requirements.txt",
    [string]$SourceDir = ".",
    [string]$OutputZip = "langgraph_lambda.zip",
    [string]$BuildDir = "build",
    [switch]$Slim,
    [string]$SlimRequirementsFile = "requirements-slim.txt",
    [string]$TargetPlatform = "linux",
    [int]$MaxZipSizeMB = 50
)

Write-Host "Packaging Lambda: output -> $OutputZip"

if (Test-Path $BuildDir) {
    Write-Host "Cleaning previous build..."
    Remove-Item -Recurse -Force $BuildDir
}

New-Item -ItemType Directory -Path $BuildDir | Out-Null

# Install dependencies into the build dir
if (Test-Path $RequirementsFile) {
    if ($Slim.IsPresent) {
        Write-Host "Slim mode requested"
        if (Test-Path $SlimRequirementsFile) {
            Write-Host "Installing SLIM requirements from $SlimRequirementsFile..."
            python -m pip install --upgrade pip
            $constraints = "constraints.txt"
            if (Test-Path $constraints) {
                Write-Host "Applying constraints from $constraints"
                python -m pip install -r $SlimRequirementsFile -c $constraints -t $BuildDir
            } else {
                python -m pip install -r $SlimRequirementsFile -t $BuildDir
            }
            if ($LASTEXITCODE -ne 0) { Write-Error "pip install for slim requirements failed (exit code $LASTEXITCODE). Aborting packaging."; exit 1 }
        } else {
            Write-Host "No $SlimRequirementsFile found; installing regular requirements then pruning heavy files..."
            python -m pip install --upgrade pip
            $constraints = "constraints.txt"
            if (Test-Path $constraints) {
                python -m pip install -r $RequirementsFile -c $constraints -t $BuildDir
            } else {
                python -m pip install -r $RequirementsFile -t $BuildDir
            }
            if ($LASTEXITCODE -ne 0) { Write-Error "pip install for requirements failed (exit code $LASTEXITCODE). Aborting packaging."; exit 1 }

            # Prune heavy or unnecessary packages/files to reduce ZIP size
            Write-Host "Pruning heavy packages and unnecessary files to create a slim package..."
            $heavyPkgs = @('numpy','scipy','pandas','zstandard','xxhash','orjson')
            foreach ($pkg in $heavyPkgs) {
                Get-ChildItem -Path $BuildDir -Recurse -Force -ErrorAction SilentlyContinue | Where-Object { $_.PSIsContainer -and ($_.Name -like "$pkg*" -or $_.FullName -match "\\$pkg\\") } | ForEach-Object { Write-Host "Removing: $($_.FullName)"; Remove-Item -Recurse -Force -ErrorAction SilentlyContinue $_.FullName }
            }

            # Remove tests and caches
            Get-ChildItem -Path $BuildDir -Recurse -Directory -Include 'tests','test','__pycache__','docs','examples','bench' -ErrorAction SilentlyContinue | ForEach-Object { Remove-Item -Recurse -Force -ErrorAction SilentlyContinue $_.FullName }
            # Remove Python test files and compiled test artifacts and typing stubs
            Get-ChildItem -Path $BuildDir -Recurse -File -Include '*test*.*','*test*','*.pyc','*.pyo','*.pyi','*.whl' -ErrorAction SilentlyContinue | ForEach-Object { Remove-Item -Force -ErrorAction SilentlyContinue $_.FullName }

            # If target is linux, remove windows-specific compiled binaries which bloat the package
            if ($TargetPlatform -eq 'linux') {
                Write-Host "Targeting linux: removing Windows binaries (*.pyd, *.dll) from build to reduce size"
                Get-ChildItem -Path $BuildDir -Recurse -File -Include '*.pyd','*.dll' -ErrorAction SilentlyContinue | ForEach-Object { Write-Host "Removing binary: $($_.FullName)"; Remove-Item -Force -ErrorAction SilentlyContinue $_.FullName }
            }
        }
    } else {
        Write-Host "Installing dependencies from $RequirementsFile..."
        Write-Host "Using local pip to install dependencies..."
        python -m pip install --upgrade pip
        $constraints = "constraints.txt"
        if (Test-Path $constraints) {
            Write-Host "Applying constraints from $constraints"
            python -m pip install -r $RequirementsFile -c $constraints -t $BuildDir
        } else {
            python -m pip install -r $RequirementsFile -t $BuildDir
        }
    }
} else {
    Write-Host "No requirements file found at $RequirementsFile, skipping pip install."
}

# Attempt to set permissive ACLs on build dir (best-effort)
try { icacls $BuildDir /grant *S-1-1-0:(OI)(CI)F } catch { }

# Validate required modules are present (fail fast if missing)
$requiredModules = @('langgraph','langchain_core','langchain_aws','boto3')
foreach ($mod in $requiredModules) {
    $foundDir = Get-ChildItem -Path $BuildDir -Recurse -Directory -ErrorAction SilentlyContinue | Where-Object { $_.Name -ieq $mod -or $_.Name -like "$mod*" }
    $foundDist = Get-ChildItem -Path $BuildDir -Recurse -Directory -ErrorAction SilentlyContinue | Where-Object { $_.Name -like "$mod-*.dist-info" }
    if (-not $foundDir -and -not $foundDist) {
        Write-Error "Required module '$mod' not found in $BuildDir. Packaging aborted. Please ensure dependencies install successfully or add '$mod' to your slim requirements.";
        exit 1
    }
}

# Copy source files (edit if you need more files)
Write-Host "Copying source files..."
$filesToInclude = @("main.py")
foreach ($f in $filesToInclude) {
    $src = Join-Path $SourceDir $f
    if (Test-Path $src) {
        Copy-Item -Path $src -Destination $BuildDir -Force
    } else {
        Write-Host "Warning: $f not found in $SourceDir"
    }
}

# Create zip package
if (Test-Path $OutputZip) { Remove-Item $OutputZip -Force }
Write-Host "Preparing to create $OutputZip..."

# Diagnostics: count files and total size
$items = Get-ChildItem -Path $BuildDir -Recurse -File -ErrorAction SilentlyContinue
$fileCount = $items.Count
$totalBytes = 0
if ($fileCount -gt 0) { $totalBytes = ($items | Measure-Object -Property Length -Sum).Sum }
Write-Host "Files to zip: $fileCount items, total size: $([math]::Round(($totalBytes/1MB),2)) MB"
# Show top 10 largest files
if ($fileCount -gt 0) {
    Write-Host "Top 10 largest files in build/ (size, path):"
    $items | Sort-Object -Property Length -Descending | Select-Object -First 10 | ForEach-Object { Write-Host "  $([math]::Round(($_.Length/1MB),3)) MB - $($_.FullName)" }
}

# Try Compress-Archive in a job so we can timeout if it hangs
$timeoutSeconds = 600  # 10 minutes
Write-Host "Starting Compress-Archive with a $timeoutSeconds second timeout..."
$job = Start-Job -ArgumentList $BuildDir, $OutputZip -ScriptBlock {
    param($b, $o)
    Compress-Archive -Path (Join-Path $b '*') -DestinationPath $o -Force -ErrorAction Stop
}
$completed = Wait-Job $job -Timeout $timeoutSeconds
if (-not $completed) {
    Write-Host "Compress-Archive job timed out after $timeoutSeconds seconds. Stopping job..."
    try { Stop-Job $job -ErrorAction SilentlyContinue } catch { }
    try { Remove-Job $job -ErrorAction SilentlyContinue } catch { }
    Write-Host "Attempting fallback methods..."
    $compressSucceeded = $false
} else {
    try {
        Receive-Job $job -ErrorAction Stop | Out-Null
        Remove-Job $job -ErrorAction SilentlyContinue
        $compressSucceeded = (Test-Path $OutputZip)
        if ($compressSucceeded) { Write-Host "Compress-Archive completed successfully" }
    } catch {
        Write-Host "Compress-Archive job failed: $($_.Exception.Message)"
        $compressSucceeded = $false
    }
}

if (-not $compressSucceeded) {
    Write-Host "Compress-Archive failed or timed out. Trying .NET ZipFile fallback..."
    try {
        Add-Type -AssemblyName System.IO.Compression.FileSystem -ErrorAction Stop
        $src = (Resolve-Path $BuildDir).Path
        $dst = (Resolve-Path $OutputZip -ErrorAction SilentlyContinue)
        if ($dst) { Remove-Item $dst -Force }
        [System.Diagnostics.Stopwatch]::StartNew() | Out-Null
        [System.IO.Compression.ZipFile]::CreateFromDirectory($src, $OutputZip)
        Write-Host ".NET ZipFile completed"
        $compressSucceeded = (Test-Path $OutputZip)
    } catch {
        Write-Host ".NET ZipFile failed: $($_.Exception.Message)"
        $compressSucceeded = $false
    }
}

if (-not $compressSucceeded) {
    Write-Host "Attempting Python-based zipping as last resort (with timeout)..."
    try {
        $pyScript = @"
import shutil, sys, os
base_out = sys.argv[1]
src = sys.argv[2]
# shutil.make_archive creates base_out.zip in current working dir
shutil.make_archive(base_out, 'zip', src)
"@
        $tmp = Join-Path $env:TEMP "make_zip.py"
        $pyScript | Out-File -FilePath $tmp -Encoding ASCII
        $base = [IO.Path]::GetFileNameWithoutExtension($OutputZip)
        $cwd = Get-Location
        $psi = New-Object System.Diagnostics.ProcessStartInfo
        $psi.FileName = "python"
        $psi.Arguments = "$tmp `"$base`" `"$(Resolve-Path $BuildDir).Path`""
        $psi.RedirectStandardOutput = $true
        $psi.RedirectStandardError = $true
        $psi.UseShellExecute = $false
        $proc = [System.Diagnostics.Process]::Start($psi)
        if ($proc -eq $null) { throw "Failed to start python process" }
        $finished = $proc.WaitForExit(600000)  # 10 minutes
        $stdOut = $proc.StandardOutput.ReadToEnd()
        $stdErr = $proc.StandardError.ReadToEnd()
        Write-Host $stdOut
        if (-not $finished -or $proc.ExitCode -ne 0) {
            Write-Host "Python zipping failed or timed out. ExitCode=$($proc.ExitCode)"
            Write-Host $stdErr
            throw "Python zip failed"
        }
        # Move created zip to desired path
        $created = Join-Path $cwd.Path ($base + ".zip")
        if (Test-Path $created) { Move-Item -Path $created -Destination $OutputZip -Force }
        $compressSucceeded = (Test-Path $OutputZip)
        if ($compressSucceeded) { Write-Host "Python-based zipping completed" }
    } catch {
        Write-Error "Python zip fallback failed: $($_.Exception.Message)"
        exit 1
    }
}

if (Test-Path $OutputZip) {
    Write-Host "Package created: $OutputZip"
    try {
        $sizeBytes = (Get-Item $OutputZip).Length
        $sizeMB = [math]::Round(($sizeBytes / 1MB),2)
        Write-Host "Package size: $sizeMB MB"
        if ($sizeMB -gt $MaxZipSizeMB) {
            Write-Error "Package size ($sizeMB MB) exceeds max allowed ($MaxZipSizeMB MB). Aborting (consider using slimmer requirements or Lambda Layers)."
            exit 2
        }
    } catch {
        Write-Host "Could not determine zip size: $($_.Exception.Message)"
    }
} else {
    Write-Error "Failed to create package: $OutputZip"
    exit 1
}
Write-Host "To upload to S3: aws s3 cp $OutputZip s3://<your-bucket>/<your-key>"