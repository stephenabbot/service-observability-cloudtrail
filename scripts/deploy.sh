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

echo -e "${BLUE}AWS CloudTrail Governance Foundation - Deployment${NC}"
echo

# Step 1: Source .env configuration
echo -e "${BLUE}Loading configuration...${NC}"
if [[ ! -f ".env" ]]; then
    echo -e "${RED}Error: .env file not found${NC}"
    echo "Please create .env file with required configuration"
    exit 1
fi

source .env

# Validate required variables
REQUIRED_VARS=(
    "AWS_REGION"
    "TAG_ENVIRONMENT"
    "TAG_OWNER"
    "TAG_COST_CENTER"
    "AUTO_DELETE_FAILED_STACK"
    "CLOUDTRAIL_IS_MULTI_REGION"
    "CLOUDTRAIL_INCLUDE_MANAGEMENT_EVENTS"
    "CLOUDTRAIL_INCLUDE_DATA_EVENTS"
    "CLOUDTRAIL_EVENT_SELECTORS"
    "ENABLE_CLOUDWATCH_LOGS"
    "CLOUDWATCH_LOGS_RETENTION_DAYS"
    "S3_INTELLIGENT_TIERING_DAYS"
    "S3_GLACIER_TRANSITION_DAYS"
    "S3_EXPIRATION_DAYS"
)

for var in "${REQUIRED_VARS[@]}"; do
    if [[ -z "${!var:-}" ]]; then
        echo -e "${RED}Error: Required variable $var not set in .env${NC}"
        exit 1
    fi
done

echo -e "${GREEN}Configuration loaded successfully${NC}"
echo

# Step 2: Verify prerequisites
echo -e "${BLUE}Verifying prerequisites...${NC}"
if ! ./scripts/verify-prerequisites.sh; then
    echo -e "${RED}Prerequisites verification failed${NC}"
    exit 1
fi
echo

# Step 3: Collect deployment metadata
echo -e "${BLUE}Collecting deployment metadata...${NC}"

ACCOUNT_ID=$(aws sts get-caller-identity --query Account --output text)
echo "Account ID: $ACCOUNT_ID"

ACCOUNT_ALIAS=$(aws iam list-account-aliases --query 'AccountAliases[0]' --output text 2>/dev/null || echo "")
if [[ "$ACCOUNT_ALIAS" == "None" || "$ACCOUNT_ALIAS" == "" ]]; then
    ACCOUNT_ALIAS=""
    echo "Account Alias: (none)"
else
    echo "Account Alias: $ACCOUNT_ALIAS"
fi

REPOSITORY_URL=$(git remote get-url origin)
echo "Repository: $REPOSITORY_URL"

PROJECT_NAME=$(basename "$REPOSITORY_URL" .git)
echo "Project: $PROJECT_NAME"

GIT_COMMIT=$(git rev-parse HEAD)
echo "Git Commit: $GIT_COMMIT"

DEPLOYMENT_ROLE=$(aws sts get-caller-identity --query Arn --output text)
echo "Deployment Role: $DEPLOYMENT_ROLE"

echo

# Step 4: Prepare CloudFormation parameters
echo -e "${BLUE}Preparing CloudFormation parameters...${NC}"

STACK_NAME="governance-cloudtrail"
TEMPLATE_PATH="cloudformation/bootstrap.yaml"

# Build parameters array
PARAMETERS=(
    "ParameterKey=AccountId,ParameterValue=$ACCOUNT_ID"
    "ParameterKey=AccountAlias,ParameterValue=$ACCOUNT_ALIAS"
    "ParameterKey=CostCenter,ParameterValue=$TAG_COST_CENTER"
    "ParameterKey=Environment,ParameterValue=$TAG_ENVIRONMENT"
    "ParameterKey=Owner,ParameterValue=$TAG_OWNER"
    "ParameterKey=Project,ParameterValue=$PROJECT_NAME"
    "ParameterKey=Repository,ParameterValue=$REPOSITORY_URL"
    "ParameterKey=Region,ParameterValue=$AWS_REGION"
    "ParameterKey=ManagedBy,ParameterValue=CloudFormation"
    "ParameterKey=DeploymentRole,ParameterValue=$DEPLOYMENT_ROLE"
    "ParameterKey=IsMultiRegion,ParameterValue=$CLOUDTRAIL_IS_MULTI_REGION"
    "ParameterKey=IncludeManagementEvents,ParameterValue=$CLOUDTRAIL_INCLUDE_MANAGEMENT_EVENTS"
    "ParameterKey=IncludeDataEvents,ParameterValue=$CLOUDTRAIL_INCLUDE_DATA_EVENTS"
    "ParameterKey=EventSelectors,ParameterValue=$CLOUDTRAIL_EVENT_SELECTORS"
    "ParameterKey=EnableCloudWatchLogs,ParameterValue=$ENABLE_CLOUDWATCH_LOGS"
    "ParameterKey=RetentionDays,ParameterValue=$CLOUDWATCH_LOGS_RETENTION_DAYS"
    "ParameterKey=IntelligentTieringDays,ParameterValue=$S3_INTELLIGENT_TIERING_DAYS"
    "ParameterKey=GlacierTransitionDays,ParameterValue=$S3_GLACIER_TRANSITION_DAYS"
    "ParameterKey=ExpirationDays,ParameterValue=$S3_EXPIRATION_DAYS"
)

echo "Parameters prepared for stack: $STACK_NAME"
echo

# Step 5: Deploy or update CloudFormation stack
echo -e "${BLUE}Deploying CloudFormation stack...${NC}"

# Check if stack exists and get its status
STACK_STATUS=""
if aws cloudformation describe-stacks --stack-name "$STACK_NAME" >/dev/null 2>&1; then
    STACK_STATUS=$(aws cloudformation describe-stacks --stack-name "$STACK_NAME" --query 'Stacks[0].StackStatus' --output text)
    echo "Existing stack status: $STACK_STATUS"
else
    echo "Stack does not exist, will create new stack"
fi

# Handle failed stack states
FAILED_STATES=("ROLLBACK_COMPLETE" "CREATE_FAILED" "UPDATE_ROLLBACK_COMPLETE" "UPDATE_FAILED" "DELETE_FAILED")
if [[ " ${FAILED_STATES[*]} " =~ " ${STACK_STATUS} " ]]; then
    echo -e "${YELLOW}Stack is in failed state: $STACK_STATUS${NC}"
    
    if [[ "$AUTO_DELETE_FAILED_STACK" == "true" ]]; then
        echo -e "${YELLOW}AUTO_DELETE_FAILED_STACK=true, deleting failed stack...${NC}"
        aws cloudformation delete-stack --stack-name "$STACK_NAME"
        echo "Waiting for stack deletion to complete..."
        aws cloudformation wait stack-delete-complete --stack-name "$STACK_NAME"
        echo -e "${GREEN}Failed stack deleted successfully${NC}"
        STACK_STATUS=""
    else
        echo -e "${RED}Error: Stack is in failed state and AUTO_DELETE_FAILED_STACK=false${NC}"
        echo
        echo "To resolve this issue:"
        echo "1. Inspect the CloudFormation events to understand why deployment failed:"
        echo "   aws cloudformation describe-stack-events --stack-name $STACK_NAME"
        echo "2. Either:"
        echo "   a) Set AUTO_DELETE_FAILED_STACK=true in .env to automatically delete failed stacks"
        echo "   b) Manually delete the failed stack: aws cloudformation delete-stack --stack-name $STACK_NAME"
        echo "3. Re-run this deployment script"
        exit 1
    fi
fi

# Deploy stack
if [[ -z "$STACK_STATUS" ]]; then
    echo "Creating new CloudFormation stack..."
    aws cloudformation create-stack \
        --stack-name "$STACK_NAME" \
        --template-body "file://$TEMPLATE_PATH" \
        --parameters "${PARAMETERS[@]}" \
        --capabilities CAPABILITY_NAMED_IAM \
        --region "$AWS_REGION"
    
    echo "Waiting for stack creation to complete..."
    if aws cloudformation wait stack-create-complete --stack-name "$STACK_NAME" --region "$AWS_REGION"; then
        echo -e "${GREEN}Stack created successfully${NC}"
    else
        echo -e "${RED}Stack creation failed${NC}"
        echo "Stack events:"
        aws cloudformation describe-stack-events --stack-name "$STACK_NAME" --region "$AWS_REGION" --query 'StackEvents[?ResourceStatus==`CREATE_FAILED`].[LogicalResourceId,ResourceStatusReason]' --output table
        exit 1
    fi
else
    echo "Updating existing CloudFormation stack..."
    UPDATE_OUTPUT=$(aws cloudformation update-stack \
        --stack-name "$STACK_NAME" \
        --template-body "file://$TEMPLATE_PATH" \
        --parameters "${PARAMETERS[@]}" \
        --capabilities CAPABILITY_NAMED_IAM \
        --region "$AWS_REGION" 2>&1) || UPDATE_RESULT=$?
    
    if [[ "${UPDATE_RESULT:-0}" -ne 0 ]]; then
        if echo "$UPDATE_OUTPUT" | grep -q "No updates are to be performed"; then
            echo -e "${GREEN}No updates required - stack is already up to date${NC}"
        else
            echo -e "${RED}Stack update failed${NC}"
            echo "$UPDATE_OUTPUT"
            exit 1
        fi
    else
        echo "Waiting for stack update to complete..."
        if aws cloudformation wait stack-update-complete --stack-name "$STACK_NAME" --region "$AWS_REGION"; then
            echo -e "${GREEN}Stack updated successfully${NC}"
        else
            echo -e "${RED}Stack update failed${NC}"
            echo "Stack events:"
            aws cloudformation describe-stack-events --stack-name "$STACK_NAME" --region "$AWS_REGION" --query 'StackEvents[?ResourceStatus==`UPDATE_FAILED`].[LogicalResourceId,ResourceStatusReason]' --output table
            exit 1
        fi
    fi
fi

echo

# Step 6: Display deployment summary
echo -e "${BLUE}Deployment Summary${NC}"
echo "=================="

FINAL_STATUS=$(aws cloudformation describe-stacks --stack-name "$STACK_NAME" --query 'Stacks[0].StackStatus' --output text)
echo "Stack Name: $STACK_NAME"
echo "Stack Status: $FINAL_STATUS"

RESOURCE_COUNT=$(aws cloudformation list-stack-resources --stack-name "$STACK_NAME" --query 'length(StackResourceSummaries)')
echo "Resources Deployed: $RESOURCE_COUNT"

SSM_PARAM_COUNT=$(aws ssm get-parameters-by-path --path "/governance/cloudtrail/" --query 'length(Parameters)')
echo "SSM Parameters Created: $SSM_PARAM_COUNT"

echo
echo -e "${GREEN}Deployment completed successfully!${NC}"
echo
echo "Next steps:"
echo "1. Run './scripts/list-deployed-resources.sh' to verify all resources"
echo "2. Check CloudTrail status: aws cloudtrail get-trail-status --name governance-cloudtrail-trail"
echo "3. View SSM parameters: aws ssm get-parameters-by-path --path /governance/cloudtrail/ --recursive"
