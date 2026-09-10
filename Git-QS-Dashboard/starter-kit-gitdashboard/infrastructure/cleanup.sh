#!/bin/bash

# GitHub Metrics Collection - Cleanup Script
# Removes all deployed AWS resources

set -e

echo "🧹 GitHub Metrics Collection Cleanup"
echo "===================================="

# Get AWS Account ID
ACCOUNT_ID=$(aws sts get-caller-identity --query Account --output text)
REGION="${REGION:-us-east-1}"

# Display all CloudFormation stacks
echo "📋 All CloudFormation stacks:"
aws cloudformation list-stacks --region ${REGION} --query 'StackSummaries[?StackStatus!=`DELETE_COMPLETE`].{Name:StackName,Status:StackStatus,Created:CreationTime}' --output table

echo ""

# Get stack names from parameters or prompt
if [ $# -gt 0 ]; then
    STACK_NAMES=("$@")
    echo "📋 Stack names provided: ${STACK_NAMES[*]}"
else
    echo "Enter stack names to delete (space-separated):"
    read -p "> " -a STACK_NAMES
fi

if [ ${#STACK_NAMES[@]} -eq 0 ]; then
    echo "❌ No stack names provided. Exiting."
    exit 1
fi

# Process each stack
for STACK_NAME in "${STACK_NAMES[@]}"; do
    echo ""
    echo "🗑️  Processing stack: ${STACK_NAME}"
    
    # Check if stack exists
    if ! aws cloudformation describe-stacks --stack-name ${STACK_NAME} --region ${REGION} >/dev/null 2>&1; then
        echo "❌ Stack '${STACK_NAME}' not found in region ${REGION}"
        continue
    fi

    # Get bucket name from stack outputs or construct it
    BUCKET_NAME=$(aws cloudformation describe-stacks --stack-name ${STACK_NAME} --region ${REGION} --query 'Stacks[0].Outputs[?OutputKey==`BucketName`].OutputValue' --output text 2>/dev/null || echo "github-metrics-${ACCOUNT_ID}-${REGION}")

    echo "📋 Stack Configuration:"
    echo "   Stack Name: ${STACK_NAME}"
    echo "   Region: ${REGION}"
    echo "   S3 Bucket: ${BUCKET_NAME}"
    echo ""

    # Confirmation prompt for each stack
    read -p "⚠️  Delete stack '${STACK_NAME}'? (y/N): " -n 1 -r
    echo
    if [[ ! $REPLY =~ ^[Yy]$ ]]; then
        echo "❌ Skipping ${STACK_NAME}"
        continue
    fi

    echo "🗑️  Starting cleanup for ${STACK_NAME}..."

    # Helper: fully empty a versioned bucket (all versions + delete markers)
    empty_bucket() {
        local bucket=$1
        if aws s3 ls "s3://${bucket}" >/dev/null 2>&1; then
            aws s3api list-object-versions --bucket "${bucket}" --query '{Objects: [Versions[].{Key:Key,VersionId:VersionId}, DeleteMarkers[].{Key:Key,VersionId:VersionId}][]}' --output json | \
            aws s3api delete-objects --bucket "${bucket}" --delete file:///dev/stdin >/dev/null 2>&1 || true
            aws s3 rm "s3://${bucket}" --recursive >/dev/null 2>&1 || true
            echo "   ✅ Emptied bucket: ${bucket}"
        else
            echo "   ℹ️  Bucket not found or already empty: ${bucket}"
        fi
    }

    # 1. Empty S3 buckets (metrics bucket + access-logs bucket, all versions)
    echo "1️⃣ Emptying S3 buckets..."
    empty_bucket "${BUCKET_NAME}"
    empty_bucket "${BUCKET_NAME}-access-logs"

    # 2. Delete CloudFormation stack (handle DELETE_FAILED state)
    echo "2️⃣ Deleting CloudFormation stack..."
    STACK_STATUS=$(aws cloudformation describe-stacks --stack-name ${STACK_NAME} --region ${REGION} --query 'Stacks[0].StackStatus' --output text 2>/dev/null || echo "NOT_FOUND")

    if [ "$STACK_STATUS" = "DELETE_FAILED" ]; then
        echo "   ⚠️  Stack in DELETE_FAILED state, forcing deletion..."
        aws cloudformation delete-stack --stack-name ${STACK_NAME} --region ${REGION}
        echo "   ⏳ Force deletion initiated..."
    else
        aws cloudformation delete-stack --stack-name ${STACK_NAME} --region ${REGION}
        echo "   ⏳ Stack deletion initiated..."
    fi

    # Wait for deletion to complete
    echo "   ⏳ Waiting for stack deletion to complete..."
    aws cloudformation wait stack-delete-complete --stack-name ${STACK_NAME} --region ${REGION} 2>/dev/null || true
    echo "   ✅ CloudFormation stack deleted"

    # 3. Clean up any remaining resources
    echo "3️⃣ Cleaning up remaining resources..."

    # Delete S3 buckets (ensure completely empty first)
    for bucket in "${BUCKET_NAME}" "${BUCKET_NAME}-access-logs"; do
        if aws s3 ls "s3://${bucket}" >/dev/null 2>&1; then
            aws s3api list-object-versions --bucket "${bucket}" --query '{Objects: [Versions[].{Key:Key,VersionId:VersionId}, DeleteMarkers[].{Key:Key,VersionId:VersionId}][]}' --output json | \
            aws s3api delete-objects --bucket "${bucket}" --delete file:///dev/stdin >/dev/null 2>&1 || true
            aws s3 rb "s3://${bucket}" --region ${REGION} 2>/dev/null && echo "   ✅ S3 bucket deleted: ${bucket}" || true
        fi
    done

    # Clean up CloudWatch log groups
    LOG_GROUPS=(
        "/aws/lambda/github-change-detector"
        "/aws/lambda/github-metrics-collector"
        "/aws/stepfunctions/github-metrics-workflow"
        "/aws/stepfunctions/github-metrics-chunked-processing"
    )

    for log_group in "${LOG_GROUPS[@]}"; do
        if aws logs describe-log-groups --log-group-name-prefix ${log_group} --region ${REGION} | grep -q logGroupName; then
            aws logs delete-log-group --log-group-name ${log_group} --region ${REGION} 2>/dev/null || true
            echo "   ✅ Deleted log group: ${log_group}"
        fi
    done

    echo "   🎉 Stack ${STACK_NAME} cleanup completed!"
done

echo ""
echo "🎉 All cleanup operations completed!"
echo ""
echo "📋 Processed stacks: ${STACK_NAMES[*]}"
echo ""
echo "💡 Note: This cleanup removes all data and cannot be undone."
echo "   To redeploy, run: ./deploy.sh"
