# Packaging Lambda Deployment Package

This doc explains how to build a ZIP package for the Lambda that contains `main.py` and any dependencies.

## Scripts
- `scripts/package_lambda.ps1` — PowerShell helper for Windows.
- `scripts/package_lambda.sh` — Bash helper for macOS / Linux / WSL.

## Steps (simple)
1. Edit `requirements.txt` to include all Python packages your Lambda needs.
2. Run the script for your platform:
   - PowerShell:
     ```powershell
     ./scripts/package_lambda.ps1 -RequirementsFile requirements.txt -OutputZip langgraph_lambda.zip
     ```
   - Bash:
     ```bash
     ./scripts/package_lambda.sh requirements.txt . langgraph_lambda.zip
     ```
3. Upload the created ZIP to S3 for the CloudFormation template:
   ```bash
   aws s3 cp langgraph_lambda.zip s3://YOUR_BUCKET/YOUR_KEY
   ```

## Notes & Tips
- AWS Lambda Python runtime already includes `boto3` in many environments; you can still include it in `requirements.txt` if you want pinned versions.
- If you have compiled native dependencies, prefer building the package on an Amazon Linux environment or use a Docker image matching Lambda's runtime.
- For larger dependency sets, consider using a Lambda Layer to reduce package size and speed deployments.

## Troubleshooting
- If you see `ImportError` at runtime, ensure the package directories are at the root of the ZIP. You can inspect the contents of the zip file by running `tar -tf langgraph_lambda.zip`. Top-level modules should be present in the zip root.
- To test locally, run `python main.py --query "your test question"` (the file includes a small CLI harness).