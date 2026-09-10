#!/usr/bin/env python3
"""
Enhanced Metrics Publisher - Publishes per-repository metrics to CloudWatch
Allows filtering and custom dashboards for specific repositories
"""

import json
import os
import boto3
from datetime import datetime

def lambda_handler(event, context):
    """Lambda to convert S3 data to CloudWatch metrics"""
    
    s3 = boto3.client('s3')
    cloudwatch = boto3.client('cloudwatch')
    
    # Bucket name must be supplied via the event payload or BUCKET_NAME env var
    bucket_name = event.get('bucket_name') or os.environ.get('BUCKET_NAME')
    if not bucket_name:
        return {'statusCode': 400, 'body': 'bucket_name is required (event.bucket_name or BUCKET_NAME env var)'}
    
    try:
        # Read metrics from S3
        response = s3.get_object(Bucket=bucket_name, Key='output/response.json')
        data = json.loads(response['Body'].read())
        
        # Extract summary and repositories
        summary = data.get('summary', {})
        repos = data.get('repositories', [])
        
        timestamp = datetime.utcnow()
        
        # Publish summary metrics (all in one namespace)
        summary_metrics = [
            {'MetricName': 'TotalUsers', 'Value': len(set(r.get('name', '').split('/')[0] for r in repos if '/' in r.get('name', ''))), 'Unit': 'Count'},
            {'MetricName': 'TotalRepositories', 'Value': summary.get('totalRepositories', 0), 'Unit': 'Count'},
            {'MetricName': 'TotalCommits', 'Value': summary.get('totalCommits', 0), 'Unit': 'Count'},
            {'MetricName': 'TotalPullRequests', 'Value': summary.get('totalPullRequests', 0), 'Unit': 'Count'},
            {'MetricName': 'TotalIssues', 'Value': summary.get('totalIssues', 0), 'Unit': 'Count'},
            {'MetricName': 'TotalTags', 'Value': summary.get('totalTags', 0), 'Unit': 'Count'},
            {'MetricName': 'TotalContributors', 'Value': summary.get('totalContributors', 0), 'Unit': 'Count'},
        ]
        
        # Publish summary metrics
        cloudwatch.put_metric_data(
            Namespace='GitDashboard/Summary',
            MetricData=[
                {
                    'MetricName': m['MetricName'],
                    'Value': m['Value'],
                    'Unit': m['Unit'],
                    'Timestamp': timestamp
                }
                for m in summary_metrics
            ]
        )
        
        # Publish per-repository metrics with dimensions
        repo_metrics = []
        for repo in repos:
            repo_name = repo.get('name', 'Unknown')
            
            # Create metrics for each repository
            metrics = [
                {
                    'MetricName': 'Commits',
                    'Value': repo.get('commits', 0),
                    'Unit': 'Count',
                    'Dimensions': [{'Name': 'Repository', 'Value': repo_name}],
                    'Timestamp': timestamp
                },
                {
                    'MetricName': 'PullRequests',
                    'Value': repo.get('pullRequests', 0),
                    'Unit': 'Count',
                    'Dimensions': [{'Name': 'Repository', 'Value': repo_name}],
                    'Timestamp': timestamp
                },
                {
                    'MetricName': 'Issues',
                    'Value': repo.get('issues', 0),
                    'Unit': 'Count',
                    'Dimensions': [{'Name': 'Repository', 'Value': repo_name}],
                    'Timestamp': timestamp
                },
                {
                    'MetricName': 'Tags',
                    'Value': repo.get('tags', 0),
                    'Unit': 'Count',
                    'Dimensions': [{'Name': 'Repository', 'Value': repo_name}],
                    'Timestamp': timestamp
                },
                {
                    'MetricName': 'Contributors',
                    'Value': repo.get('contributors', 0),
                    'Unit': 'Count',
                    'Dimensions': [{'Name': 'Repository', 'Value': repo_name}],
                    'Timestamp': timestamp
                }
            ]
            
            repo_metrics.extend(metrics)
        
        # Publish repository metrics in batches (CloudWatch limit: 20 metrics per call)
        for i in range(0, len(repo_metrics), 20):
            batch = repo_metrics[i:i+20]
            cloudwatch.put_metric_data(
                Namespace='GitDashboard/Repositories',
                MetricData=batch
            )
        
        print(f"Published {len(summary_metrics)} summary metrics and {len(repo_metrics)} repository metrics")
        
        return {
            'statusCode': 200,
            'body': json.dumps({
                'message': 'Metrics published successfully',
                'summaryMetrics': len(summary_metrics),
                'repositoryMetrics': len(repo_metrics)
            })
        }
        
    except Exception as e:
        print(f"Error: {str(e)}")
        return {
            'statusCode': 500,
            'body': json.dumps({'error': str(e)})
        }


if __name__ == '__main__':
    # Test locally
    result = lambda_handler({'bucket_name': os.environ.get('BUCKET_NAME', '')}, None)
    print(json.dumps(result, indent=2))
