#!/bin/bash

# Deploy Metrics Publisher Lambda and Dashboard

set -e

REGION="${REGION:-us-east-1}"
BUCKET_NAME="${BUCKET_NAME:?Set BUCKET_NAME to your metrics S3 bucket, e.g. export BUCKET_NAME=git-dashboard-metrics-<account-id>-<region>}"
ACCOUNT_ID=$(aws sts get-caller-identity --query Account --output text)

echo "=== Deploying Metrics Publisher Lambda ==="
echo "Region: $REGION"
echo "Bucket: $BUCKET_NAME"
echo ""

# Package Lambda
echo "Packaging Lambda..."
zip -q metrics_publisher.zip metrics_publisher.py

# Check if Lambda exists
if aws lambda get-function --function-name git-metrics-publisher --region $REGION &>/dev/null; then
    echo "Updating existing Lambda function..."
    aws lambda update-function-code \
        --function-name git-metrics-publisher \
        --zip-file fileb://metrics_publisher.zip \
        --region $REGION > /dev/null
else
    echo "Creating new Lambda function..."
    
    # Create IAM role if it doesn't exist
    ROLE_NAME="git-metrics-publisher-role"
    ROLE_ARN="arn:aws:iam::$ACCOUNT_ID:role/$ROLE_NAME"
    
    if ! aws iam get-role --role-name $ROLE_NAME &>/dev/null; then
        echo "Creating IAM role..."
        aws iam create-role \
            --role-name $ROLE_NAME \
            --assume-role-policy-document '{
                "Version": "2012-10-17",
                "Statement": [{
                    "Effect": "Allow",
                    "Principal": {"Service": "lambda.amazonaws.com"},
                    "Action": "sts:AssumeRole"
                }]
            }' > /dev/null
        
        aws iam attach-role-policy \
            --role-name $ROLE_NAME \
            --policy-arn arn:aws:iam::aws:policy/service-role/AWSLambdaBasicExecutionRole
        
        aws iam put-role-policy \
            --role-name $ROLE_NAME \
            --policy-name S3CloudWatchAccess \
            --policy-document '{
                "Version": "2012-10-17",
                "Statement": [
                    {
                        "Effect": "Allow",
                        "Action": ["s3:GetObject", "s3:ListBucket"],
                        "Resource": ["arn:aws:s3:::'$BUCKET_NAME'/*", "arn:aws:s3:::'$BUCKET_NAME'"]
                    },
                    {
                        "Effect": "Allow",
                        "Action": ["cloudwatch:PutMetricData"],
                        "Resource": "*"
                    }
                ]
            }'
        
        echo "Waiting for IAM role to propagate..."
        sleep 10
    fi
    
    aws lambda create-function \
        --function-name git-metrics-publisher \
        --runtime python3.14 \
        --role $ROLE_ARN \
        --handler metrics_publisher.lambda_handler \
        --zip-file fileb://metrics_publisher.zip \
        --environment Variables="{BUCKET_NAME=$BUCKET_NAME}" \
        --timeout 60 \
        --region $REGION > /dev/null
fi

echo "✅ Lambda function deployed"

# Add EventBridge rule to trigger after collector
echo ""
echo "Creating EventBridge rule..."
RULE_NAME="git-metrics-publisher-trigger"

aws events put-rule \
    --name $RULE_NAME \
    --schedule-expression "rate(15 minutes)" \
    --state ENABLED \
    --region $REGION > /dev/null

# Add Lambda permission for EventBridge
aws lambda add-permission \
    --function-name git-metrics-publisher \
    --statement-id EventBridgeInvoke \
    --action lambda:InvokeFunction \
    --principal events.amazonaws.com \
    --source-arn arn:aws:events:$REGION:$ACCOUNT_ID:rule/$RULE_NAME \
    --region $REGION &>/dev/null || true

# Add target
aws events put-targets \
    --rule $RULE_NAME \
    --targets "Id"="1","Arn"="arn:aws:lambda:$REGION:$ACCOUNT_ID:function:git-metrics-publisher" \
    --region $REGION > /dev/null

echo "✅ EventBridge rule created"

# Test invoke
echo ""
echo "Testing Lambda function..."
aws lambda invoke \
    --function-name git-metrics-publisher \
    --payload '{"bucket_name":"'$BUCKET_NAME'"}' \
    --region $REGION \
    response.json > /dev/null

if grep -q "statusCode.*200" response.json; then
    echo "✅ Lambda test successful"
else
    echo "⚠️  Lambda test failed. Check response.json"
fi

rm -f response.json metrics_publisher.zip

# Deploy dashboard
echo ""
echo "=== Deploying CloudWatch Dashboard ==="
./deploy-dashboard.sh

echo ""
echo "✅ All components deployed successfully!"
echo ""
echo "Wait 1-2 minutes for metrics to appear, then view dashboard at:"
echo "https://console.aws.amazon.com/cloudwatch/home?region=$REGION#dashboards:name=GitDashboard-Metrics"
