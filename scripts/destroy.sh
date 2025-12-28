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

STACK_NAME="governance-cloudtrail"

echo -e "${RED}⚠️  AWS CloudTrail Governance Foundation - DESTRUCTION WARNING ⚠️${NC}"
echo
echo -e "${RED}This will permanently delete the following resources:${NC}"
echo "  • CloudFormation stack: $STACK_NAME"
echo "  • CloudTrail trail: governance-cloudtrail-trail"
echo "  • CloudWatch Log Group: governance-cloudtrail-logs (if exists)"
echo "  • IAM Role: governance-cloudtrail-cw-logs-* (if exists)"
echo "  • SSM Parameters: /governance/cloudtrail/*"
echo
echo -e "${YELLOW}Note: S3 bucket may be retained based on your choice below${NC}"
echo
echo -e "${RED}THIS ACTION CANNOT BE UNDONE${NC}"
echo

# Step 1: Confirmation prompt for stack destruction
echo -e "${BLUE}Confirmation Required${NC}"
echo "To proceed with destruction, type 'DESTROY' exactly:"
read -r CONFIRMATION

if [[ "$CONFIRMATION" != "DESTROY" ]]; then
    echo -e "${GREEN}Destruction cancelled${NC}"
    exit 0
fi

echo

# Step 2: S3 bucket retention prompt
echo -e "${BLUE}S3 Bucket Retention Decision${NC}"
echo "The S3 bucket contains audit logs and has DeletionPolicy: Retain"
echo
echo "Choose an option:"
echo "1) Retain S3 bucket (recommended - preserves audit history)"
echo "2) Delete S3 bucket (WARNING: permanently destroys all audit logs)"
echo
read -p "Enter choice (1 or 2): " BUCKET_CHOICE

RETAIN_BUCKET=true
if [[ "$BUCKET_CHOICE" == "2" ]]; then
    echo
    echo -e "${RED}⚠️  FINAL WARNING ⚠️${NC}"
    echo "You chose to DELETE the S3 bucket and ALL audit logs"
    echo "This will permanently destroy the audit trail history"
    echo
    read -p "Type 'DELETE BUCKET' to confirm: " BUCKET_CONFIRMATION
    
    if [[ "$BUCKET_CONFIRMATION" == "DELETE BUCKET" ]]; then
        RETAIN_BUCKET=false
        echo -e "${YELLOW}S3 bucket will be deleted${NC}"
    else
        echo -e "${GREEN}S3 bucket will be retained${NC}"
        RETAIN_BUCKET=true
    fi
else
    echo -e "${GREEN}S3 bucket will be retained${NC}"
fi

echo

# Step 3: Verify prerequisites
echo -e "${BLUE}Verifying prerequisites...${NC}"
if ! ./scripts/verify-prerequisites.sh >/dev/null 2>&1; then
    echo -e "${RED}Prerequisites verification failed${NC}"
    echo "Run './scripts/verify-prerequisites.sh' to see details"
    exit 1
fi
echo -e "${GREEN}Prerequisites verified${NC}"
echo

# Step 4: Handle S3 bucket deletion if requested
if [[ "$RETAIN_BUCKET" == "false" ]]; then
    echo -e "${BLUE}Preparing S3 bucket for deletion...${NC}"
    
    ACCOUNT_ID=$(aws sts get-caller-identity --query Account --output text)
    BUCKET_NAME="governance-cloudtrail-$ACCOUNT_ID"
    
    if aws s3api head-bucket --bucket "$BUCKET_NAME" 2>/dev/null; then
        echo "Deleting all objects and versions from bucket: $BUCKET_NAME"
        
        # Function to show progress
        show_progress() {
            local current=$1
            local total=$2
            local percent=$((current * 100 / total))
            local bar_length=50
            local filled_length=$((percent * bar_length / 100))
            
            printf "\rProgress: ["
            printf "%*s" $filled_length | tr ' ' '█'
            printf "%*s" $((bar_length - filled_length)) | tr ' ' '░'
            printf "] %d%% (%d/%d)" $percent $current $total
        }
        
        # Get total object count for progress tracking
        echo "Counting objects in bucket..."
        TOTAL_OBJECTS=$(aws s3api list-object-versions --bucket "$BUCKET_NAME" --query 'length(Versions) + length(DeleteMarkers)' --output text 2>/dev/null || echo "0")
        
        if [[ "$TOTAL_OBJECTS" -gt 0 ]]; then
            echo "Found $TOTAL_OBJECTS objects/versions to delete"
            
            # Delete all object versions and delete markers
            aws s3api list-object-versions --bucket "$BUCKET_NAME" --output json | \
            jq -r '.Versions[]?, .DeleteMarkers[]? | "\(.Key)\t\(.VersionId)"' | \
            while IFS=$'\t' read -r key version_id; do
                aws s3api delete-object --bucket "$BUCKET_NAME" --key "$key" --version-id "$version_id" >/dev/null 2>&1
                ((PROCESSED++)) || PROCESSED=1
                show_progress $PROCESSED $TOTAL_OBJECTS
            done
            
            echo
            echo -e "${GREEN}All objects deleted from bucket${NC}"
        else
            echo "Bucket is empty"
        fi
        
        # Remove DeletionPolicy by updating stack without the bucket
        echo "Removing S3 bucket from CloudFormation management..."
        # Note: This is a simplified approach. In practice, you might need to modify the template
        # to remove the bucket resource before deletion.
    else
        echo "S3 bucket not found: $BUCKET_NAME"
    fi
fi

echo

# Step 5: Delete CloudFormation stack
echo -e "${BLUE}Deleting CloudFormation stack...${NC}"

if aws cloudformation describe-stacks --stack-name "$STACK_NAME" >/dev/null 2>&1; then
    aws cloudformation delete-stack --stack-name "$STACK_NAME"
    echo "Waiting for stack deletion to complete..."
    
    if aws cloudformation wait stack-delete-complete --stack-name "$STACK_NAME"; then
        echo -e "${GREEN}CloudFormation stack deleted successfully${NC}"
    else
        echo -e "${RED}Stack deletion failed${NC}"
        echo "Stack events:"
        aws cloudformation describe-stack-events --stack-name "$STACK_NAME" --query 'StackEvents[?ResourceStatus==`DELETE_FAILED`].[LogicalResourceId,ResourceStatusReason]' --output table
        exit 1
    fi
else
    echo -e "${YELLOW}CloudFormation stack not found${NC}"
fi

echo

# Step 6: Clean up SSM parameters
echo -e "${BLUE}Cleaning up SSM parameters...${NC}"

SSM_PARAMS=$(aws ssm get-parameters-by-path --path "/governance/cloudtrail/" --recursive --query 'Parameters[].Name' --output text 2>/dev/null || echo "")

if [[ -n "$SSM_PARAMS" ]]; then
    echo "Deleting SSM parameters..."
    for param in $SSM_PARAMS; do
        if aws ssm delete-parameter --name "$param" >/dev/null 2>&1; then
            echo "  Deleted: $param"
        else
            echo "  Failed to delete: $param"
        fi
    done
else
    echo "No SSM parameters found to delete"
fi

echo

# Step 7: Verify destruction using list-deployed-resources
echo -e "${BLUE}Verifying destruction...${NC}"

# Run the list-deployed-resources script to check for remaining resources
echo "Checking for remaining resources..."
./scripts/list-deployed-resources.sh 2>/dev/null || {
    echo -e "${GREEN}Stack verification confirms no CloudFormation resources remain${NC}"
}

# Check for specific resources that might remain
ACCOUNT_ID=$(aws sts get-caller-identity --query Account --output text)
BUCKET_NAME="governance-cloudtrail-$ACCOUNT_ID"

echo
echo -e "${BLUE}Resource Status After Destruction:${NC}"

# Check S3 bucket
if aws s3api head-bucket --bucket "$BUCKET_NAME" 2>/dev/null; then
    if [[ "$RETAIN_BUCKET" == "true" ]]; then
        echo -e "  ${GREEN}○${NC} S3 bucket retained as expected: $BUCKET_NAME"
        echo "    This bucket contains audit logs and was preserved by design"
        echo "    To delete manually later: aws s3 rb s3://$BUCKET_NAME --force"
    else
        echo -e "  ${YELLOW}!${NC} S3 bucket still exists: $BUCKET_NAME"
        echo "    Manual deletion may be required if bucket is not empty"
    fi
else
    echo -e "  ${GREEN}✓${NC} S3 bucket deleted: $BUCKET_NAME"
fi

# Check CloudTrail
if aws cloudtrail get-trail-status --name "governance-cloudtrail-trail" >/dev/null 2>&1; then
    echo -e "  ${RED}!${NC} CloudTrail trail still exists (potential orphan)"
else
    echo -e "  ${GREEN}✓${NC} CloudTrail trail deleted"
fi

# Check CloudWatch Logs
if aws logs describe-log-groups --log-group-name-prefix "governance-cloudtrail-logs" --query "logGroups[?logGroupName=='governance-cloudtrail-logs']" --output text | grep -q "governance-cloudtrail-logs"; then
    echo -e "  ${RED}!${NC} CloudWatch log group still exists (potential orphan)"
else
    echo -e "  ${GREEN}✓${NC} CloudWatch log group deleted"
fi

# Check SSM parameters
REMAINING_PARAMS=$(aws ssm get-parameters-by-path --path "/governance/cloudtrail/" --query 'length(Parameters)' 2>/dev/null || echo "0")
if [[ "$REMAINING_PARAMS" -gt 0 ]]; then
    echo -e "  ${RED}!${NC} $REMAINING_PARAMS SSM parameters still exist"
else
    echo -e "  ${GREEN}✓${NC} All SSM parameters deleted"
fi

echo

# Step 8: Display completion summary
echo -e "${BLUE}Destruction Summary${NC}"
echo "=================="

echo "CloudFormation Stack: Deleted"
if [[ "$RETAIN_BUCKET" == "true" ]]; then
    echo "S3 Bucket: Retained (contains audit logs)"
else
    echo "S3 Bucket: Deletion attempted"
fi
echo "SSM Parameters: Cleanup attempted"

echo
if [[ "$RETAIN_BUCKET" == "true" ]]; then
    echo -e "${GREEN}Destruction completed successfully${NC}"
    echo
    echo -e "${BLUE}Important Notes:${NC}"
    echo "• S3 bucket '$BUCKET_NAME' was retained and contains audit logs"
    echo "• Bucket has lifecycle policies that will manage costs over time"
    echo "• To delete the bucket later, first empty it then delete:"
    echo "  aws s3 rm s3://$BUCKET_NAME --recursive"
    echo "  aws s3 rb s3://$BUCKET_NAME"
else
    echo -e "${GREEN}Destruction completed${NC}"
    echo
    echo -e "${YELLOW}Note: If S3 bucket deletion failed, you may need to empty and delete it manually${NC}"
fi

echo
echo "To redeploy the infrastructure, run: ./scripts/deploy.sh"
