#!/bin/bash
set -e

echo "🚀 Deploying Complete CloudWatch Dashboard Solution"
echo ""

# 1. Update metrics publisher
echo "1️⃣ Deploying enhanced metrics publisher..."
zip -q metrics_publisher.zip metrics_publisher.py
aws lambda update-function-code \
  --function-name git-metrics-publisher \
  --zip-file fileb://metrics_publisher.zip \
  --region us-east-1 > /dev/null
rm metrics_publisher.zip
echo "   ✅ Metrics publisher updated"

# 2. Invoke to publish metrics
echo ""
echo "2️⃣ Publishing metrics to CloudWatch..."
aws lambda invoke \
  --function-name git-metrics-publisher \
  --cli-binary-format raw-in-base64-out \
  --payload '{}' \
  --region us-east-1 \
  /tmp/response.json > /dev/null
echo "   ✅ Metrics published"

# 3. Deploy main dashboard
echo ""
echo "3️⃣ Deploying main dashboard..."
DASHBOARD_FILE=dashboard-v2.json ./deploy-dashboard.sh > /dev/null
echo "   ✅ Main dashboard deployed"

echo ""
echo "✅ Deployment Complete!"
echo ""
echo "📊 View Main Dashboard:"
echo "   https://console.aws.amazon.com/cloudwatch/home?region=us-east-1#dashboards:name=GitDashboard-Metrics"
echo ""
echo "🎯 Create Custom Repository Dashboard:"
echo "   python3 create_custom_dashboard.py 'example-org/sample-web-app'"
