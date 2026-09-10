#!/usr/bin/env python3
"""
Create custom CloudWatch dashboard for a specific repository
"""

import sys
import json
import boto3

def create_repo_dashboard(repo_name, region='us-east-1'):
    """Create dashboard for specific repository"""
    
    dashboard_name = f"Repo-{repo_name.replace('/', '-')}"
    
    dashboard_body = {
        "widgets": [
            {
                "type": "metric",
                "properties": {
                    "metrics": [
                        ["GitDashboard/Repositories", "Commits", {"stat": "Average"}],
                        [".", "PullRequests", {"stat": "Average"}],
                        [".", "Issues", {"stat": "Average"}],
                        [".", "Tags", {"stat": "Average"}],
                        [".", "Contributors", {"stat": "Average"}]
                    ],
                    "view": "singleValue",
                    "region": region,
                    "title": f"{repo_name} - All Metrics",
                    "period": 300,
                    "stat": "Average",
                    "dimensions": {"Repository": repo_name}
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
                        ["GitDashboard/Repositories", "Commits", {"stat": "Average"}]
                    ],
                    "view": "timeSeries",
                    "region": region,
                    "title": "Commits Over Time",
                    "period": 300,
                    "dimensions": {"Repository": repo_name}
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
                        ["GitDashboard/Repositories", "PullRequests", {"stat": "Average"}]
                    ],
                    "view": "timeSeries",
                    "region": region,
                    "title": "Pull Requests Over Time",
                    "period": 300,
                    "dimensions": {"Repository": repo_name}
                },
                "width": 12,
                "height": 6,
                "x": 12,
                "y": 4
            }
        ]
    }
    
    cloudwatch = boto3.client('cloudwatch', region_name=region)
    
    cloudwatch.put_dashboard(
        DashboardName=dashboard_name,
        DashboardBody=json.dumps(dashboard_body)
    )
    
    print(f"✅ Dashboard created: {dashboard_name}")
    print(f"View at: https://console.aws.amazon.com/cloudwatch/home?region={region}#dashboards:name={dashboard_name}")

if __name__ == '__main__':
    if len(sys.argv) < 2:
        print("Usage: python3 create_custom_dashboard.py <repository-name> [region]")
        print("Example: python3 create_custom_dashboard.py example-org/sample-web-app us-east-1")
        sys.exit(1)
    
    repo = sys.argv[1]
    region = sys.argv[2] if len(sys.argv) > 2 else 'us-east-1'
    
    create_repo_dashboard(repo, region)
