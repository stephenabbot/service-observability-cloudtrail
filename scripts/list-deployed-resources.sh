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

echo -e "${BLUE}AWS CloudTrail Governance Foundation - Resource Inventory${NC}"
echo

# Step 1: Verify stack exists
echo -e "${BLUE}Checking CloudFormation stack...${NC}"

if ! aws cloudformation describe-stacks --stack-name "$STACK_NAME" >/dev/null 2>&1; then
    echo -e "${YELLOW}CloudFormation stack '$STACK_NAME' not found${NC}"
    echo "Stack may not be deployed or may have been deleted"
    echo
    echo "To deploy the stack, run: ./scripts/deploy.sh"
    exit 0
fi

# Step 2: Display CloudFormation stack information
STACK_INFO=$(aws cloudformation describe-stacks --stack-name "$STACK_NAME" --query 'Stacks[0]')
STACK_STATUS=$(echo "$STACK_INFO" | jq -r '.StackStatus')
CREATION_TIME=$(echo "$STACK_INFO" | jq -r '.CreationTime')
LAST_UPDATE_TIME=$(echo "$STACK_INFO" | jq -r '.LastUpdatedTime // "Never"')

echo "Stack Name: $STACK_NAME"
echo "Stack Status: $STACK_STATUS"
echo "Creation Time: $CREATION_TIME"
echo "Last Update Time: $LAST_UPDATE_TIME"

# Display stack outputs
echo
echo "Stack Outputs:"
OUTPUTS=$(aws cloudformation describe-stacks --stack-name "$STACK_NAME" --query 'Stacks[0].Outputs')
if [[ "$OUTPUTS" != "null" ]]; then
    echo "$OUTPUTS" | jq -r '.[] | "  \(.OutputKey): \(.OutputValue)"'
else
    echo "  No outputs available"
fi

echo

# Step 3: Display deployed resources from stack
echo -e "${BLUE}CloudFormation Stack Resources${NC}"
echo "=============================="

STACK_RESOURCES=$(aws cloudformation list-stack-resources --stack-name "$STACK_NAME" --query 'StackResourceSummaries')
echo "$STACK_RESOURCES" | jq -r '.[] | "  \(.ResourceType) | \(.LogicalResourceId) | \(.PhysicalResourceId) | \(.ResourceStatus)"' | column -t -s '|'

echo

# Step 4: Verify AWS resource status using dual verification
echo -e "${BLUE}Resource Verification (Tags + API Calls)${NC}"
echo "========================================"

# Get account ID for resource naming
ACCOUNT_ID=$(aws sts get-caller-identity --query Account --output text)

# Function to check resource via tags
check_resource_by_tags() {
    local resource_type="$1"
    local project_name="governance-cloudtrail"
    
    echo "Searching for $resource_type resources via tags..."
    
    case "$resource_type" in
        "s3")
            # S3 buckets don't support resource groups tagging API, use S3 API directly
            aws s3api list-buckets --query "Buckets[?starts_with(Name, 'governance-cloudtrail-')]" --output table 2>/dev/null || echo "  No S3 buckets found with governance-cloudtrail prefix"
            ;;
        "cloudtrail")
            aws cloudtrail describe-trails --query "trailList[?contains(Name, 'governance-cloudtrail')]" --output table 2>/dev/null || echo "  No CloudTrail trails found with governance-cloudtrail name"
            ;;
        "logs")
            aws logs describe-log-groups --log-group-name-prefix "governance-cloudtrail" --query "logGroups" --output table 2>/dev/null || echo "  No CloudWatch log groups found with governance-cloudtrail prefix"
            ;;
        "ssm")
            aws ssm get-parameters-by-path --path "/governance/cloudtrail/" --query "Parameters[].Name" --output table 2>/dev/null || echo "  No SSM parameters found at /governance/cloudtrail/ path"
            ;;
    esac
}

# Function to verify specific resources via API
verify_resource_status() {
    local resource_type="$1"
    
    case "$resource_type" in
        "s3")
            echo -e "${BLUE}S3 Bucket Verification:${NC}"
            BUCKET_NAME="governance-cloudtrail-$ACCOUNT_ID"
            if aws s3api head-bucket --bucket "$BUCKET_NAME" 2>/dev/null; then
                echo -e "  ${GREEN}✓${NC} Bucket exists: $BUCKET_NAME"
                
                # Check versioning
                VERSIONING=$(aws s3api get-bucket-versioning --bucket "$BUCKET_NAME" --query 'Status' --output text 2>/dev/null || echo "Disabled")
                echo "    Versioning: $VERSIONING"
                
                # Check encryption
                ENCRYPTION=$(aws s3api get-bucket-encryption --bucket "$BUCKET_NAME" --query 'ServerSideEncryptionConfiguration.Rules[0].ApplyServerSideEncryptionByDefault.SSEAlgorithm' --output text 2>/dev/null || echo "Not configured")
                echo "    Encryption: $ENCRYPTION"
                
                # Check lifecycle rules
                LIFECYCLE_COUNT=$(aws s3api get-bucket-lifecycle-configuration --bucket "$BUCKET_NAME" --query 'length(Rules)' --output text 2>/dev/null || echo "0")
                echo "    Lifecycle Rules: $LIFECYCLE_COUNT"
            else
                echo -e "  ${RED}✗${NC} Bucket not found: $BUCKET_NAME"
            fi
            ;;
            
        "cloudtrail")
            echo -e "${BLUE}CloudTrail Verification:${NC}"
            TRAIL_NAME="governance-cloudtrail-trail"
            if aws cloudtrail get-trail-status --name "$TRAIL_NAME" >/dev/null 2>&1; then
                echo -e "  ${GREEN}✓${NC} Trail exists: $TRAIL_NAME"
                
                # Check logging status
                IS_LOGGING=$(aws cloudtrail get-trail-status --name "$TRAIL_NAME" --query 'IsLogging' --output text)
                echo "    Is Logging: $IS_LOGGING"
                
                # Check latest delivery time
                LATEST_DELIVERY=$(aws cloudtrail get-trail-status --name "$TRAIL_NAME" --query 'LatestDeliveryTime' --output text 2>/dev/null || echo "Not available")
                echo "    Latest Delivery: $LATEST_DELIVERY"
            else
                echo -e "  ${RED}✗${NC} Trail not found: $TRAIL_NAME"
            fi
            ;;
            
        "logs")
            echo -e "${BLUE}CloudWatch Logs Verification:${NC}"
            LOG_GROUP_NAME="governance-cloudtrail-logs"
            if aws logs describe-log-groups --log-group-name-prefix "$LOG_GROUP_NAME" --query "logGroups[?logGroupName=='$LOG_GROUP_NAME']" --output text | grep -q "$LOG_GROUP_NAME"; then
                echo -e "  ${GREEN}✓${NC} Log group exists: $LOG_GROUP_NAME"
                
                # Check retention
                RETENTION=$(aws logs describe-log-groups --log-group-name-prefix "$LOG_GROUP_NAME" --query "logGroups[?logGroupName=='$LOG_GROUP_NAME'].retentionInDays" --output text)
                echo "    Retention: ${RETENTION:-Never expires} days"
                
                # Check stored bytes
                STORED_BYTES=$(aws logs describe-log-groups --log-group-name-prefix "$LOG_GROUP_NAME" --query "logGroups[?logGroupName=='$LOG_GROUP_NAME'].storedBytes" --output text)
                echo "    Stored Bytes: ${STORED_BYTES:-0}"
            else
                echo -e "  ${YELLOW}○${NC} Log group not found: $LOG_GROUP_NAME (may be disabled in configuration)"
            fi
            ;;
            
        "ssm")
            echo -e "${BLUE}SSM Parameters Verification:${NC}"
            SSM_PARAMS=$(aws ssm get-parameters-by-path --path "/governance/cloudtrail/" --recursive --query 'Parameters')
            PARAM_COUNT=$(echo "$SSM_PARAMS" | jq length)
            
            if [[ "$PARAM_COUNT" -gt 0 ]]; then
                echo -e "  ${GREEN}✓${NC} Found $PARAM_COUNT SSM parameters"
                echo "$SSM_PARAMS" | jq -r '.[] | "    \(.Name): \(.Value)"'
            else
                echo -e "  ${RED}✗${NC} No SSM parameters found at /governance/cloudtrail/"
            fi
            ;;
    esac
    echo
}

# Perform dual verification for each resource type
for resource_type in "s3" "cloudtrail" "logs" "ssm"; do
    verify_resource_status "$resource_type"
done

# Step 5: Discrepancy reporting
echo -e "${BLUE}Discrepancy Analysis${NC}"
echo "==================="

# Compare CloudFormation resources with actual AWS resources
CF_RESOURCES=$(aws cloudformation list-stack-resources --stack-name "$STACK_NAME" --query 'StackResourceSummaries[].PhysicalResourceId' --output text)
CF_RESOURCE_COUNT=$(echo "$CF_RESOURCES" | wc -w)
echo "CloudFormation reports $CF_RESOURCE_COUNT resources"

# Check for resources that exist but aren't in CloudFormation (potential orphans)
echo
echo -e "${BLUE}Resource Categorization:${NC}"

# S3 Bucket
BUCKET_NAME="governance-cloudtrail-$ACCOUNT_ID"
if aws s3api head-bucket --bucket "$BUCKET_NAME" 2>/dev/null; then
    if echo "$CF_RESOURCES" | grep -q "$BUCKET_NAME"; then
        echo -e "  ${GREEN}✓${NC} S3 Bucket: Managed by CloudFormation"
    else
        echo -e "  ${YELLOW}○${NC} S3 Bucket: Retained by design (DeletionPolicy: Retain)"
    fi
fi

# CloudTrail
TRAIL_NAME="governance-cloudtrail-trail"
if aws cloudtrail get-trail-status --name "$TRAIL_NAME" >/dev/null 2>&1; then
    if echo "$CF_RESOURCES" | grep -q "$TRAIL_NAME"; then
        echo -e "  ${GREEN}✓${NC} CloudTrail: Managed by CloudFormation"
    else
        echo -e "  ${RED}!${NC} CloudTrail: Potential orphan (should be managed by CloudFormation)"
    fi
fi

# CloudWatch Logs
LOG_GROUP_NAME="governance-cloudtrail-logs"
if aws logs describe-log-groups --log-group-name-prefix "$LOG_GROUP_NAME" --query "logGroups[?logGroupName=='$LOG_GROUP_NAME']" --output text | grep -q "$LOG_GROUP_NAME"; then
    if echo "$CF_RESOURCES" | grep -q "$LOG_GROUP_NAME"; then
        echo -e "  ${GREEN}✓${NC} CloudWatch Logs: Managed by CloudFormation"
    else
        echo -e "  ${RED}!${NC} CloudWatch Logs: Potential orphan (should be managed by CloudFormation)"
    fi
fi

echo

# Step 6: Display resource summary
echo -e "${BLUE}Resource Summary${NC}"
echo "==============="

TOTAL_CF_RESOURCES=$(aws cloudformation list-stack-resources --stack-name "$STACK_NAME" --query 'length(StackResourceSummaries)')
echo "CloudFormation Resources: $TOTAL_CF_RESOURCES"

# Count actual resources
ACTUAL_RESOURCES=0
aws s3api head-bucket --bucket "$BUCKET_NAME" 2>/dev/null && ((ACTUAL_RESOURCES++)) || true
aws cloudtrail get-trail-status --name "$TRAIL_NAME" >/dev/null 2>&1 && ((ACTUAL_RESOURCES++)) || true
aws logs describe-log-groups --log-group-name-prefix "$LOG_GROUP_NAME" --query "logGroups[?logGroupName=='$LOG_GROUP_NAME']" --output text | grep -q "$LOG_GROUP_NAME" && ((ACTUAL_RESOURCES++)) || true
SSM_COUNT=$(aws ssm get-parameters-by-path --path "/governance/cloudtrail/" --query 'length(Parameters)')
ACTUAL_RESOURCES=$((ACTUAL_RESOURCES + SSM_COUNT))

echo "Actual AWS Resources: $ACTUAL_RESOURCES"

if [[ "$STACK_STATUS" == "CREATE_COMPLETE" || "$STACK_STATUS" == "UPDATE_COMPLETE" ]]; then
    echo -e "Overall Status: ${GREEN}Healthy${NC}"
else
    echo -e "Overall Status: ${YELLOW}$STACK_STATUS${NC}"
fi

echo
echo -e "${GREEN}Resource inventory completed${NC}"
