# CloudWatch Dashboard for Git Metrics

This folder contains CloudWatch dashboard configuration and metrics publisher for the Git Dashboard solution.

## Components

### 1. `dashboard.json`
CloudWatch dashboard configuration with the following widgets:
- **Lambda Invocations**: Detector and Collector invocation counts
- **Lambda Duration**: Average execution time
- **Lambda Errors**: Error counts
- **Step Functions Executions**: Workflow execution status
- **Repository Count**: Repositories detected by platform
- **Successful Collections**: Collection runs over time
- **Load Type Distribution**: Full vs incremental loads
- **Recent Errors**: Latest error messages
- **S3 Storage Metrics**: Bucket size and object count
- **EventBridge Triggers**: Schedule trigger counts

### 2. `metrics_publisher.py`
Lambda function that reads S3 data and publishes custom CloudWatch metrics:
- Total repositories, commits, PRs, issues
- Stars, forks, contributors
- Platform breakdown (GitHub/GitLab)
- Language distribution

### 3. `deploy-dashboard.sh`
Script to deploy the CloudWatch dashboard

## Quick Start

### Deploy Dashboard

```bash
cd CloudWatch
./deploy-dashboard.sh
```

### Deploy with Custom Settings

```bash
DASHBOARD_NAME="MyGitDashboard" REGION="us-west-2" ./deploy-dashboard.sh
```

### Deploy Metrics Publisher Lambda (Optional)

If you want custom metrics in CloudWatch:

```bash
# Create Lambda function
aws lambda create-function \
  --function-name git-metrics-publisher \
  --runtime python3.14 \
  --role arn:aws:iam::ACCOUNT_ID:role/lambda-execution-role \
  --handler metrics_publisher.lambda_handler \
  --zip-file fileb://metrics_publisher.zip \
  --environment Variables="{BUCKET_NAME=git-dashboard-metrics-ACCOUNT_ID-us-east-1}" \
  --region us-east-1

# Add S3 trigger to run after collector completes
aws lambda add-permission \
  --function-name git-metrics-publisher \
  --statement-id s3-trigger \
  --action lambda:InvokeFunction \
  --principal s3.amazonaws.com \
  --source-arn arn:aws:s3:::git-dashboard-metrics-ACCOUNT_ID-us-east-1 \
  --region us-east-1
```

## Dashboard Widgets

### Metrics Widgets
- Monitor Lambda performance and errors
- Track Step Functions execution status
- View EventBridge schedule triggers
- Monitor S3 storage usage

### Log Insights Widgets
- Repository count by platform
- Collection success rate
- Load type distribution (full/incremental)
- Recent error logs

## View Dashboard

After deployment, access at:
```
https://console.aws.amazon.com/cloudwatch/home?region=us-east-1#dashboards:name=GitDashboard-Metrics
```

## Custom Metrics (Optional)

If you deploy the metrics publisher Lambda, you'll get additional custom metrics under:
- Namespace: `GitDashboard`
- Namespace: `GitDashboard/Languages`

These can be added to the dashboard for more detailed insights.

## Update Dashboard

To update the dashboard:
1. Edit `dashboard.json`
2. Run `./deploy-dashboard.sh`

## Delete Dashboard

```bash
aws cloudwatch delete-dashboards \
  --dashboard-names GitDashboard-Metrics \
  --region us-east-1
```
