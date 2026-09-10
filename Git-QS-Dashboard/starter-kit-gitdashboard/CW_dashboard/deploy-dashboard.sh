#!/bin/bash

# Deploy CloudWatch Dashboard for Git Metrics Collection

set -e

REGION="${REGION:-us-east-1}"
DASHBOARD_NAME="${DASHBOARD_NAME:-GitDashboard-Metrics}"
DASHBOARD_FILE="${DASHBOARD_FILE:-dashboard-final.json}"

echo "=== Deploying CloudWatch Dashboard ==="
echo "Dashboard Name: $DASHBOARD_NAME"
echo "Region: $REGION"
echo "Using: $DASHBOARD_FILE"
echo ""

# Read dashboard JSON
DASHBOARD_BODY=$(cat $DASHBOARD_FILE)

# Create or update dashboard
aws cloudwatch put-dashboard \
    --dashboard-name "$DASHBOARD_NAME" \
    --dashboard-body "$DASHBOARD_BODY" \
    --region "$REGION"

echo ""
echo "✅ Dashboard deployed successfully!"
echo ""
echo "View dashboard at:"
echo "https://console.aws.amazon.com/cloudwatch/home?region=$REGION#dashboards:name=$DASHBOARD_NAME"
