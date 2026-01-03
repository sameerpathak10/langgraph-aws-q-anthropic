# LangGraph AWS Q and Claude Agentic Router

This project demonstrates a sophisticated routing mechanism using LangGraph to intelligently delegate tasks between AWS Q for enterprise-grade Retrieval-Augmented Generation (RAG) and a powerful multi-step agent powered by Anthropic's Claude 3 Sonnet.

## Project Overview

The core of this solution is a LangGraph state machine that acts as a smart router. When a user submits a query, the graph first directs it to a decision-making node. This node, powered by Claude 3 Sonnet, analyzes the user's intent and determines the most appropriate downstream path:

1.  **AWS Q (RAG)**: If the query requires fetching information from an enterprise knowledge base, such as internal documentation, policies, or FAQs, the request is routed to AWS Q Business. AWS Q excels at providing accurate, context-aware answers by searching indexed enterprise data sources.

2.  **Multi-step Agent**: If the query demands complex reasoning, a series of actions, or orchestration across multiple steps, it is routed to an autonomous agent also powered by Claude 3 Sonnet. This agent can break down the problem, execute intermediate steps, and produce a comprehensive final answer.

This dual-path architecture ensures that simple informational queries are handled efficiently by a specialized RAG service, while complex tasks that require reasoning and orchestration are managed by a capable agent.

## Architecture

The repository is structured to support a serverless deployment on AWS Lambda.

-   `main.py`: This is the core file containing the Lambda handler and the LangGraph state machine definition.
    -   **State Management**: The `AgentState` TypedDict defines the data structure that is passed between nodes in the graph.
    -   **Nodes**:
        -   `decide_route`: Uses Claude 3 Sonnet to determine if the query is for `RAG` or an `AGENT`.
        -   `aws_q_rag`: Queries the AWS Q Business application using the `boto3` SDK.
        -   `agent_orchestration`: Invokes the Claude 3 Sonnet model to perform multi-step reasoning.
    -   **Graph**: The `StateGraph` object wires the nodes together, defining the entry point and conditional edges based on the output of the `decide_route` node.
    -   **Lambda Handler**: `lambda_handler` is the entry point for the AWS Lambda invocation. It parses the incoming event, invokes the LangGraph application, and returns a JSON response.
-   `requirements.txt`: Lists all Python dependencies for the project. A `requirements-slim.txt` is also included for a minimal deployment package.
-   `cloudformation/q-rag-lambda.yml`: An AWS CloudFormation template to provision the necessary infrastructure, including the Lambda function, an IAM role, and necessary permissions.
-   `scripts/`: Contains helper scripts for packaging the Lambda function and deploying it using CloudFormation change sets.
    -   `package_lambda.ps1`/`.sh`: Scripts to create the `langgraph_lambda.zip` deployment package.
    -   `create_changeset.ps1`/`.sh`: Scripts to automate the CloudFormation deployment process.

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

For detailed instructions, see [PACKAGING.md](PACKAGING.md).

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
- Inspect the produced zip to validate that `main.py` and dependencies are present (works on Linux, macOS, and modern Windows):
  ```bash
  tar -tf langgraph_lambda.zip
  ```

### Notes
- If your project requires compiled binary wheels (e.g., `numpy`, `cryptography`), building on Amazon Linux (Docker) or using Lambda Layers is recommended to ensure runtime compatibility.
- If you'd like, we can add an explicit `--use-docker` flag or a workflow input that performs Docker-based packaging on-demand.

---

If you'd like a short README badge or a small section showing how to download the artifact from a successful run, I can add that too.