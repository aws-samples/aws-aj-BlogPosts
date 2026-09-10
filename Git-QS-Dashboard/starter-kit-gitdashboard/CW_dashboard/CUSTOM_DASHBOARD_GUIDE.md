# Custom Repository Dashboard Guide

## Create Dashboard for Specific Repository

You can create custom dashboards to monitor specific repositories.

### Example: Dashboard for "example-org/sample-web-app"

```json
{
  "widgets": [
    {
      "type": "metric",
      "properties": {
        "metrics": [
          [ "GitDashboard/Repositories", "Commits", { "stat": "Average", "dimensions": {"Repository": "example-org/sample-web-app"} } ],
          [ ".", "PullRequests", { "stat": "Average", "dimensions": {"Repository": "example-org/sample-web-app"} } ],
          [ ".", "Issues", { "stat": "Average", "dimensions": {"Repository": "example-org/sample-web-app"} } ],
          [ ".", "Tags", { "stat": "Average", "dimensions": {"Repository": "example-org/sample-web-app"} } ],
          [ ".", "Contributors", { "stat": "Average", "dimensions": {"Repository": "example-org/sample-web-app"} } ]
        ],
        "view": "singleValue",
        "region": "us-east-1",
        "title": "example-org/sample-web-app - Metrics",
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
          [ "GitDashboard/Repositories", "Commits", { "stat": "Average", "dimensions": {"Repository": "example-org/sample-web-app"} } ]
        ],
        "view": "timeSeries",
        "stacked": false,
        "region": "us-east-1",
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
          [ "GitDashboard/Repositories", "PullRequests", { "stat": "Average", "dimensions": {"Repository": "example-org/sample-web-app"} } ]
        ],
        "view": "timeSeries",
        "stacked": false,
        "region": "us-east-1",
        "title": "Pull Requests Over Time",
        "period": 300
      },
      "width": 12,
      "height": 6,
      "x": 12,
      "y": 4
    }
  ]
}
```

## Create Custom Dashboard via CLI

```bash
# Save the JSON above to custom-repo-dashboard.json
# Replace "example-org/sample-web-app" with your repository name

aws cloudwatch put-dashboard \
  --dashboard-name "MyRepo-Dashboard" \
  --dashboard-body file://custom-repo-dashboard.json \
  --region us-east-1
```

## Create via Console

1. Go to CloudWatch Console
2. Click "Dashboards" → "Create dashboard"
3. Add widget → Select "Line" or "Number"
4. Choose metric:
   - Namespace: `GitDashboard/Repositories`
   - Metric: `Commits`, `PullRequests`, `Issues`, etc.
   - Dimension: `Repository` = `Your/Repo/Name`
5. Save widget and dashboard

## Available Metrics per Repository

All metrics are in namespace: `GitDashboard/Repositories`

With dimension: `Repository` = `owner/repo-name`

- **Commits** - Total commits
- **PullRequests** - Total pull requests
- **Issues** - Total issues
- **Tags** - Total tags
- **Contributors** - Total contributors

## List All Repositories

```bash
# Get all repository names with metrics
aws cloudwatch list-metrics \
  --namespace GitDashboard/Repositories \
  --metric-name Commits \
  --region us-east-1 \
  --query 'Metrics[].Dimensions[?Name==`Repository`].Value' \
  --output table
```

## Example: Compare Multiple Repositories

```json
{
  "type": "metric",
  "properties": {
    "metrics": [
      [ "GitDashboard/Repositories", "Commits", { "dimensions": {"Repository": "example-org/repo1"} } ],
      [ "...", { "dimensions": {"Repository": "example-org/repo2"} } ],
      [ "...", { "dimensions": {"Repository": "example-org/repo3"} } ]
    ],
    "view": "timeSeries",
    "title": "Commits Comparison",
    "period": 300
  }
}
```

## Quick Dashboard Templates

### Template 1: Single Repository Overview
- All metrics in one number widget
- Time series for each metric

### Template 2: Multi-Repository Comparison
- Compare same metric across repositories
- Stacked or separate lines

### Template 3: Team Dashboard
- Filter by repository prefix (e.g., "TeamA/*")
- Aggregate metrics for team repos

## Automation

Create dashboards programmatically:

```python
import boto3
import json

cloudwatch = boto3.client('cloudwatch')

def create_repo_dashboard(repo_name):
    dashboard_body = {
        "widgets": [
            {
                "type": "metric",
                "properties": {
                    "metrics": [
                        ["GitDashboard/Repositories", "Commits", 
                         {"dimensions": {"Repository": repo_name}}]
                    ],
                    "title": f"{repo_name} - Commits"
                }
            }
        ]
    }
    
    cloudwatch.put_dashboard(
        DashboardName=f"Repo-{repo_name.replace('/', '-')}",
        DashboardBody=json.dumps(dashboard_body)
    )

# Create dashboard for specific repo
create_repo_dashboard("example-org/sample-web-app")
```
