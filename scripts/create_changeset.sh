#!/usr/bin/env bash
set -euo pipefail

usage() {
  cat <<EOF
Usage: $0 STACK_NAME TEMPLATE_FILE LAMBDA_S3_BUCKET LAMBDA_S3_KEY [CHANGESET_PREFIX] [PARAMETERS...]
Example:
  $0 langgraph-aws-q-poc cloudformation/q-rag-lambda.yml langgraph-poc-bucket langgraph_lambda.zip
  $0 my-stack template.yml my-bucket my-key update "ParameterKey=MyParam,ParameterValue=MyValue"
EOF
}

if [ "$#" -lt 4 ]; then
  usage
  exit 1
fi

STACK_NAME=$1
TEMPLATE_FILE=$2
LAMBDA_S3_BUCKET=$3
LAMBDA_S3_KEY=$4
PREFIX=${5:-update}
shift 5 2>/dev/null || true # shift away the first 5 args, ignore error if less than 5
PARAMETERS=("$@") # rest of the arguments are parameters

# build sanitized change-set name: starts with letter, only letters/digits/hyphens
TIMESTAMP=$(date +%Y%m%d%H%M%S)
CS_NAME="${STACK_NAME}-${PREFIX}-${TIMESTAMP}"
# ensure starts with letter
if ! [[ ${CS_NAME} =~ ^[A-Za-z] ]]; then
  CS_NAME="cs-${CS_NAME}"
fi
# replace any invalid characters
CS_NAME=$(echo "$CS_NAME" | sed -E 's/[^a-zA-Z0-9-]/-/g')

echo "Using change set name: $CS_NAME"

# Determine change set type
if aws cloudformation describe-stacks --stack-name "$STACK_NAME" >/dev/null 2>&1; then
  echo "Stack '$STACK_NAME' exists, creating UPDATE change set."
  CHANGE_SET_TYPE="UPDATE"
else
  echo "Stack '$STACK_NAME' does not exist, creating CREATE change set."
  CHANGE_SET_TYPE="CREATE"
fi

echo "Creating change set..."
aws cloudformation create-change-set \
  --stack-name "$STACK_NAME" \
  --change-set-name "$CS_NAME" \
  --change-set-type "$CHANGE_SET_TYPE" \
  --template-body file://"$TEMPLATE_FILE" \
  --capabilities CAPABILITY_NAMED_IAM \
  --parameters ParameterKey=LambdaS3Bucket,ParameterValue="$LAMBDA_S3_BUCKET" ParameterKey=LambdaS3Key,ParameterValue="$LAMBDA_S3_KEY" "${PARAMETERS[@]}"

echo "Waiting for change set create complete..."
aws cloudformation wait change-set-create-complete --stack-name "$STACK_NAME" --change-set-name "$CS_NAME"

CS_STATUS=$(aws cloudformation describe-change-set --stack-name "$STACK_NAME" --change-set-name "$CS_NAME" --query 'Status' --output text)
if [ "$CS_STATUS" = "FAILED" ]; then
  echo "Change set creation failed:" >&2
  aws cloudformation describe-change-set --stack-name "$STACK_NAME" --change-set-name "$CS_NAME" --query 'StatusReason' --output text >&2
  echo "Deleting failed change set..."
  aws cloudformation delete-change-set --stack-name "$STACK_NAME" --change-set-name "$CS_NAME"
  exit 1
fi

echo "Executing change set..."
aws cloudformation execute-change-set --stack-name "$STACK_NAME" --change-set-name "$CS_NAME"

echo "Change set executed. Monitor stack events with: aws cloudformation describe-stack-events --stack-name $STACK_NAME"
