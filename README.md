🧪 Example Input
{
  "query": "What is the retention policy for customer transaction logs?"
}


➡️ Routed to AWS Q (RAG)

{
  "query": "Analyze logs and suggest steps to reduce API latency"
}


➡️ Routed to Multi-step Agent

---

## 📦 Packaging & CI

**Quick summary:** this repo includes simple packaging scripts and two GitHub Actions workflows that produce a Lambda-ready zip (`langgraph_lambda.zip`) and upload it as an artifact.

### Scripts
- PowerShell: `scripts/package_lambda.ps1`
  - Usage (Windows / PowerShell Core):
    ```powershell
    ./scripts/package_lambda.ps1 -RequirementsFile requirements.txt -OutputZip langgraph_lambda.zip -BuildDir build
    # Slim mode (use requirements-slim.txt if present, or prune heavy packages):
    ./scripts/package_lambda.ps1 -RequirementsFile requirements.txt -Slim
    ```
- Bash: `scripts/package_lambda.sh`
  - Usage (Linux / macOS):
    ```bash
    ./scripts/package_lambda.sh requirements.txt . langgraph_lambda.zip
    # Slim mode (use requirements-slim.txt if present, or prune heavy packages):
    ./scripts/package_lambda.sh requirements.txt . langgraph_lambda.zip --slim
    ```

Create an optional `requirements-slim.txt` listing only the truly required runtime packages (e.g., `boto3` and any minimal libs). The repo includes a sample `requirements-slim.txt` that fits this project. If present and slim mode is requested, the script installs only those packages. If `requirements-slim.txt` is missing, slim mode installs the full `requirements.txt` then prunes known heavy packages (numpy, scipy, pandas, etc.) and removes test files and caches to reduce zip size.

> Both scripts install Python dependencies into `build/` using the local `python -m pip` (Docker-free by default). If you need Amazon Linux-compatible binary wheels (native/compiled deps), consider building inside the AWS Lambda runtime image (add Docker support or run a Docker-based job).

### GitHub Actions workflows
- `.github/workflows/package-lambda-no-docker.yml` — **Docker-free** workflow using `ubuntu-latest` and `setup-python`, runs the packaging script and uploads artifacts.
- `.github/workflows/docker-build-and-package.yml` — builds a Docker image (if a `Dockerfile` exists), optionally pushes on tag, then runs the packaging script and uploads artifacts.

Artifacts produced and uploaded by the workflows:
- `langgraph_lambda.zip` (artifact name: `lambda-package`)
- `build/` directory (artifact name: `build-directory`)

Triggers: workflows run on pushes to `main`, pull requests targeting `main`, and can also be triggered manually from the Actions tab (`workflow_dispatch`).

### .gitignore
- Packaging artifacts are ignored: `build/` and `langgraph_lambda.zip` (and `*.zip`), so local packaging outputs won't be committed by accident.

### Local testing tips
- Create and activate a virtual environment, then run the packaging script to confirm expected files are in `build/` and the zip is created.
- Inspect the produced zip to validate that `main.py` and dependencies are present:
  ```bash
  unzip -l langgraph_lambda.zip
  ```

### Notes
- If your project requires compiled binary wheels (e.g., `numpy`, `cryptography`), building on Amazon Linux (Docker) or using Lambda Layers is recommended to ensure runtime compatibility.
- If you'd like, we can add an explicit `--use-docker` flag or a workflow input that performs Docker-based packaging on-demand.

---

If you'd like a short README badge or a small section showing how to download the artifact from a successful run, I can add that too.