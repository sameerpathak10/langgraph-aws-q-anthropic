# Deploy / Change Set Helpers

Use the helper scripts to create, wait for, and execute a CloudFormation change set with a sanitized name.

## Windows (PowerShell)

Example:

```powershell
./scripts/create_changeset.ps1 -StackName langgraph-aws-q-poc -TemplateFile cloudformation/q-rag-lambda.yml -LambdaS3Bucket langgraph-poc-bucket -LambdaS3Key langgraph_lambda.zip
```

Options:
- `-AutoDeleteFailedChangeSet` — automatically delete a failed change set.

## Bash

Example:

```bash
./scripts/create_changeset.sh langgraph-aws-q-poc cloudformation/q-rag-lambda.yml langgraph-poc-bucket langgraph_lambda.zip
```

Notes:
- Both scripts construct a change-set name with the pattern: {StackName}-{prefix}-{YYYYmmddHHMMSS}
  which meets CloudFormation naming constraints (starts with a letter, only letters/digits/hyphens).
- The scripts will wait for the change set to complete creating and will abort and delete the change set if it fails to create.
- After execution, monitor stack events with:
  - `aws cloudformation describe-stack-events --stack-name STACK_NAME`
  - `aws cloudformation describe-stacks --stack-name STACK_NAME`

Security:
- These scripts call the AWS CLI and assume you have configured credentials and region.
- For CI usage, configure AWS credentials in the CI provider (e.g., GitHub Actions secrets, IAM role in runner, etc.).
