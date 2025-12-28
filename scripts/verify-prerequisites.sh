#!/bin/bash

set -euo pipefail

# Colors for output
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
BLUE='\033[0;34m'
NC='\033[0m' # No Color

# Disable AWS CLI pager
export AWS_PAGER=""

echo -e "${BLUE}AWS CloudTrail Governance Foundation - Prerequisites Verification${NC}"
echo

# Initialize results tracking
declare -a PASSED_CHECKS=()
declare -a FAILED_CHECKS=()

# Function to record check results
record_check() {
    local check_name="$1"
    local status="$2"
    local message="$3"
    
    if [[ "$status" == "PASS" ]]; then
        PASSED_CHECKS+=("$check_name")
        echo -e "${GREEN}✓${NC} $message"
    else
        FAILED_CHECKS+=("$check_name: $message")
        echo -e "${RED}✗${NC} $message"
    fi
}

# Check required tools
echo "Checking required tools..."

# AWS CLI
if command -v aws >/dev/null 2>&1; then
    AWS_VERSION=$(aws --version 2>&1 | cut -d/ -f2 | cut -d' ' -f1)
    if [[ "$AWS_VERSION" =~ ^2\. ]]; then
        record_check "aws_cli" "PASS" "AWS CLI version $AWS_VERSION installed"
    else
        record_check "aws_cli" "FAIL" "AWS CLI version $AWS_VERSION found, but version 2.x required"
    fi
else
    record_check "aws_cli" "FAIL" "AWS CLI not found in PATH"
fi

# jq
if command -v jq >/dev/null 2>&1; then
    JQ_VERSION=$(jq --version)
    record_check "jq" "PASS" "jq $JQ_VERSION installed"
else
    record_check "jq" "FAIL" "jq not found in PATH"
fi

# Git
if command -v git >/dev/null 2>&1; then
    GIT_VERSION=$(git --version)
    record_check "git" "PASS" "$GIT_VERSION installed"
else
    record_check "git" "FAIL" "git not found in PATH"
fi

echo

# Check git repository state
echo "Checking git repository state..."

# Is git repository
if git rev-parse --git-dir >/dev/null 2>&1; then
    record_check "git_repo" "PASS" "Current directory is a git repository"
    
    # Remote origin configured
    if git remote get-url origin >/dev/null 2>&1; then
        ORIGIN_URL=$(git remote get-url origin)
        record_check "git_origin" "PASS" "Remote origin configured: $ORIGIN_URL"
    else
        record_check "git_origin" "FAIL" "Remote origin not configured"
    fi
    
    # No uncommitted changes
    if git diff-index --quiet HEAD --; then
        record_check "git_clean" "PASS" "No uncommitted changes"
    else
        record_check "git_clean" "FAIL" "Uncommitted changes detected"
    fi
    
    # No untracked files
    if [[ -z $(git ls-files --others --exclude-standard) ]]; then
        record_check "git_untracked" "PASS" "No untracked files"
    else
        record_check "git_untracked" "FAIL" "Untracked files detected"
    fi
    
    # Local branch up to date (if remote tracking branch exists)
    CURRENT_BRANCH=$(git branch --show-current)
    if git rev-parse --verify "@{upstream}" >/dev/null 2>&1; then
        if git diff --quiet HEAD "@{upstream}"; then
            record_check "git_sync" "PASS" "Local branch '$CURRENT_BRANCH' up to date with remote"
        else
            record_check "git_sync" "FAIL" "Local branch '$CURRENT_BRANCH' differs from remote"
        fi
    else
        record_check "git_sync" "PASS" "No upstream branch configured (acceptable for new repositories)"
    fi
else
    record_check "git_repo" "FAIL" "Current directory is not a git repository"
fi

echo

# Check AWS credentials
echo "Checking AWS credentials..."

if aws sts get-caller-identity >/dev/null 2>&1; then
    ACCOUNT_ID=$(aws sts get-caller-identity --query Account --output text)
    USER_ARN=$(aws sts get-caller-identity --query Arn --output text)
    record_check "aws_credentials" "PASS" "AWS credentials valid - Account: $ACCOUNT_ID, Principal: $USER_ARN"
else
    record_check "aws_credentials" "FAIL" "AWS credentials not configured or invalid"
fi

echo

# Check AWS permissions
echo "Checking AWS permissions..."

# CloudFormation permissions
if aws cloudformation describe-stacks --stack-name non-existent-stack 2>&1 | grep -q "does not exist"; then
    record_check "cfn_permissions" "PASS" "CloudFormation describe-stacks permission verified"
elif aws cloudformation describe-stacks --stack-name non-existent-stack 2>&1 | grep -q "AccessDenied\|UnauthorizedOperation"; then
    record_check "cfn_permissions" "FAIL" "CloudFormation permissions denied"
else
    record_check "cfn_permissions" "PASS" "CloudFormation permissions appear available"
fi

# S3 permissions
if aws s3api list-buckets >/dev/null 2>&1; then
    record_check "s3_permissions" "PASS" "S3 list-buckets permission verified"
else
    record_check "s3_permissions" "FAIL" "S3 permissions denied or unavailable"
fi

# CloudTrail permissions
if aws cloudtrail describe-trails >/dev/null 2>&1; then
    record_check "cloudtrail_permissions" "PASS" "CloudTrail describe-trails permission verified"
else
    record_check "cloudtrail_permissions" "FAIL" "CloudTrail permissions denied or unavailable"
fi

# IAM permissions
if aws iam list-account-aliases >/dev/null 2>&1; then
    record_check "iam_permissions" "PASS" "IAM list-account-aliases permission verified"
else
    record_check "iam_permissions" "FAIL" "IAM permissions denied or unavailable"
fi

# CloudWatch Logs permissions
if aws logs describe-log-groups --limit 1 >/dev/null 2>&1; then
    record_check "logs_permissions" "PASS" "CloudWatch Logs describe-log-groups permission verified"
else
    record_check "logs_permissions" "FAIL" "CloudWatch Logs permissions denied or unavailable"
fi

# SSM permissions
if aws ssm describe-parameters --max-items 1 >/dev/null 2>&1; then
    record_check "ssm_permissions" "PASS" "SSM describe-parameters permission verified"
else
    record_check "ssm_permissions" "FAIL" "SSM permissions denied or unavailable"
fi

echo

# Check CloudFormation template validation
echo "Checking CloudFormation template..."

TEMPLATE_PATH="cloudformation/bootstrap.yaml"
if [[ -f "$TEMPLATE_PATH" ]]; then
    if aws cloudformation validate-template --template-body "file://$TEMPLATE_PATH" >/dev/null 2>&1; then
        record_check "cfn_template" "PASS" "CloudFormation template validation successful"
    else
        record_check "cfn_template" "FAIL" "CloudFormation template validation failed"
    fi
else
    record_check "cfn_template" "FAIL" "CloudFormation template not found at $TEMPLATE_PATH"
fi

echo

# Display summary
echo -e "${BLUE}Prerequisites Verification Summary${NC}"
echo "=================================="

if [[ ${#PASSED_CHECKS[@]} -gt 0 ]]; then
    echo -e "${GREEN}Passed checks (${#PASSED_CHECKS[@]}):${NC}"
    for check in "${PASSED_CHECKS[@]}"; do
        echo "  ✓ $check"
    done
    echo
fi

if [[ ${#FAILED_CHECKS[@]} -gt 0 ]]; then
    echo -e "${RED}Failed checks (${#FAILED_CHECKS[@]}):${NC}"
    for check in "${FAILED_CHECKS[@]}"; do
        echo "  ✗ $check"
    done
    echo
    
    echo -e "${RED}Prerequisites verification failed. Please resolve the above issues before proceeding.${NC}"
    exit 1
else
    echo -e "${GREEN}All prerequisites verified successfully!${NC}"
    exit 0
fi
