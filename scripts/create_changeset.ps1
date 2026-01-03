<#
Creates and executes a CloudFormation change set with a sanitized name.
Usage:
  ./scripts/create_changeset.ps1 -StackName my-stack -TemplateFile cloudformation/q-rag-lambda.yml -LambdaS3Bucket my-bucket -LambdaS3Key langgraph_lambda.zip
#>

param(
    [Parameter(Mandatory=$true)][string]$StackName,
    [Parameter(Mandatory=$true)][string]$TemplateFile,
    [Parameter(Mandatory=$true)][string]$LambdaS3Bucket,
    [Parameter(Mandatory=$true)][string]$LambdaS3Key,
    [string]$ChangeSetPrefix = "update",
    [switch]$AutoDeleteFailedChangeSet,
    [string[]]$Parameters = @()
)

function Ensure-AwsCli {
    if (-not (Get-Command aws -ErrorAction SilentlyContinue)) {
        Write-Error "AWS CLI not found in PATH. Install and configure the AWS CLI first."
        exit 1
    }
}

Ensure-AwsCli

# Build a change set name that matches CloudFormation rules: start with a letter and only contain letters, digits and hyphens
$timestamp = Get-Date -UFormat %Y%m%d%H%M%S
$cs = "${StackName}-${ChangeSetPrefix}-${timestamp}"
if (-not ($cs -match '^[A-Za-z]')) { $cs = "cs-$cs" }
$cs = $cs -replace '[^a-zA-Z0-9-]', '-'  # replace any safe-but-unexpected char with hyphen

Write-Host "Using change set name: $cs"

# Resolve template path: try a few likely locations if the user passed a relative or short filename
$resolvedTemplate = $TemplateFile
$scriptDir = Split-Path -Parent $MyInvocation.MyCommand.Definition
$candidates = @(
    $resolvedTemplate,
    (Join-Path (Get-Location) $resolvedTemplate),
    (Join-Path $scriptDir $resolvedTemplate),
    (Join-Path $scriptDir "..\cloudformation\$resolvedTemplate"),
    (Join-Path (Get-Location) "cloudformation\$resolvedTemplate")
)
$candidates = $candidates | Select-Object -Unique
$found = $false
foreach ($c in $candidates) {
    if (Test-Path $c) {
        $resolvedTemplate = (Resolve-Path $c).Path
        $found = $true
        break
    }
}
if (-not $found) {
    Write-Error "Template file not found. Tried: $([string]::Join(', ', $candidates))"
    exit 1
}
Write-Host "Using template file: $resolvedTemplate"

# Detect whether the stack already exists; if not, we will create a change set of type CREATE
$stackExists = $false
try {
    aws cloudformation describe-stacks --stack-name $StackName | Out-Null
    $stackExists = $true
    Write-Host "Stack '$StackName' exists; creating an UPDATE change set."
} catch {
    $stackExists = $false
    Write-Host "Stack '$StackName' does not exist; creating a CREATE change set."
}

try {
    Write-Host "Creating change set..."
    $createArgs = @(
        'cloudformation', 'create-change-set',
        '--stack-name', $StackName,
        '--change-set-name', $cs,
        '--change-set-type', (if ($stackExists) { 'UPDATE' } else { 'CREATE' }),
        '--template-body', "file://$resolvedTemplate",
        '--capabilities', 'CAPABILITY_NAMED_IAM',
        '--parameters', "ParameterKey=LambdaS3Bucket,ParameterValue=$LambdaS3Bucket", "ParameterKey=LambdaS3Key,ParameterValue=$LambdaS3Key"
    )
    $createArgs += $Parameters

    $createResult = aws @createArgs 2>&1
    if ($LASTEXITCODE -ne 0) {
        Write-Error "Create-change-set failed: $createResult"
        exit 1
    }

    Write-Host "Waiting for change set to finish creating..."
    aws cloudformation wait change-set-create-complete --stack-name $StackName --change-set-name $cs

    $csDesc = aws cloudformation describe-change-set --stack-name $StackName --change-set-name $cs | ConvertFrom-Json
    if ($csDesc.Status -eq 'FAILED') {
        Write-Host "Change set creation failed: $($csDesc.StatusReason)"
        if ($AutoDeleteFailedChangeSet) {
            Write-Host "Deleting failed change set..."
            aws cloudformation delete-change-set --stack-name $StackName --change-set-name $cs
        }
        exit 1
    }

    Write-Host "Executing change set..."
    aws cloudformation execute-change-set --stack-name $StackName --change-set-name $cs
    Write-Host "Change set executed. Monitor stack events with: aws cloudformation describe-stack-events --stack-name $StackName"

} catch {
    Write-Error "Error during change set operation: $_"
    if ($AutoDeleteFailedChangeSet -and $cs) {
        Try { aws cloudformation delete-change-set --stack-name $StackName --change-set-name $cs } catch {}
    }
    exit 1
}

Write-Host "Done."