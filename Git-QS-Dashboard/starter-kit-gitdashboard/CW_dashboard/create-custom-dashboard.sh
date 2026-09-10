#!/bin/bash

# Create custom dashboard for a specific repository

REPO_NAME="${1}"
REGION="${2:-us-east-1}"

if [ -z "$REPO_NAME" ]; then
    echo "Usage: $0 <repository-name> [region]"
    echo "Example: $0 example-org/sample-web-app us-east-1"
    exit 1
fi

DASHBOARD_NAME="Repo-$(echo $REPO_NAME | tr '/' '-')"

echo "Creating dashboard for repository: $REPO_NAME"
echo "Dashboard name: $DASHBOARD_NAME"

cat > /tmp/custom-dashboard.json << 'DASHBOARD'
{
  "widgets": [
    {
      "type": "metric",
      "properties": {
        "metrics": [
          [ "GitDashboard/Repositories", "Commits", { "dimensions": {"Repository": "REPO_PLACEHOLDER"} } ],
          [ ".", "PullRequests", { "." : "." } ],
          [ ".", "Issues", { "." : "." } ],
          [ ".", "Tags", { "." : "." } ],
          [ ".", "Contributors", { "." : "." } ]
        ],
        "view": "singleValue",
        "region": "REGION_PLACEHOLDER",
        "title": "REPO_PLACEHOLDER - All Metrics",
        "period": 300
      },
      "width": 24,
      "height": 4,
      "x": 0,
      "y": 0
    },
    {
      "type": "metric",
      "properties": {
        "metrics": [
          [ "GitDashboard/Repositories", "Commits", { "dimensions": {"Repository": "REPO_PLACEHOLDER"} } ]
        ],
        "view": "timeSeries",
        "stacked": false,
        "region": "REGION_PLACEHOLDER",
        "title": "Commits Over Time",
        "period": 300
      },
      "width": 12,
      "height": 6,
      "x": 0,
      "y": 4
    },
    {
      "type": "metric",
      "properties": {
        "metrics": [
          [ "GitDashboard/Repositories", "PullRequests", { "dimensions": {"Repository": "REPO_PLACEHOLDER"} } ]
        ],
        "view": "timeSeries",
        "stacked": false,
        "region": "REGION_PLACEHOLDER",
        "title": "Pull Requests Over Time",
        "period": 300
      },
      "width": 12,
      "height": 6,
      "x": 12,
      "y": 4
    },
    {
      "type": "metric",
      "properties": {
        "metrics": [
          [ "GitDashboard/Repositories", "Issues", { "dimensions": {"Repository": "REPO_PLACEHOLDER"} } ]
        ],
        "view": "timeSeries",
        "stacked": false,
        "region": "REGION_PLACEHOLDER",
        "title": "Issues Over Time",
        "period": 300
      },
      "width": 12,
      "height": 6,
      "x": 0,
      "y": 10
    },
    {
      "type": "metric",
      "properties": {
        "metrics": [
          [ "GitDashboard/Repositories", "Contributors", { "dimensions": {"Repository": "REPO_PLACEHOLDER"} } ]
        ],
        "view": "timeSeries",
        "stacked": false,
        "region": "REGION_PLACEHOLDER",
        "title": "Contributors Over Time",
        "period": 300
      },
      "width": 12,
      "height": 6,
      "x": 12,
      "y": 10
    }
  ]
}
DASHBOARD

# Replace placeholders
sed -i.bak "s/REPO_PLACEHOLDER/$REPO_NAME/g" /tmp/custom-dashboard.json
sed -i.bak "s/REGION_PLACEHOLDER/$REGION/g" /tmp/custom-dashboard.json

aws cloudwatch put-dashboard \
    --dashboard-name "$DASHBOARD_NAME" \
    --dashboard-body file:///tmp/custom-dashboard.json \
    --region "$REGION"

rm /tmp/custom-dashboard.json /tmp/custom-dashboard.json.bak

echo ""
echo "✅ Dashboard created successfully!"
echo ""
echo "View at: https://console.aws.amazon.com/cloudwatch/home?region=$REGION#dashboards:name=$DASHBOARD_NAME"
