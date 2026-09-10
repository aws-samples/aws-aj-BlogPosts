# GitHub Metrics Collection - Deployment Guide

**Complete guide for deploying and managing the GitHub metrics collection solution**

## 📋 Prerequisites

### Required Tools
- **AWS CLI**: Version 2.0+ configured with appropriate permissions
- **GitHub Personal Access Token**: With `repo` scope access
- **Python 3.12+**: For local development (optional)
- **Bash Shell**: For running deployment scripts

### AWS Permissions Required
Your AWS credentials must have permissions for:
- CloudFormation (create/update/delete stacks)
- Lambda (create/update functions)
- S3 (create buckets, upload/download objects)
- IAM (create roles and policies)
- Secrets Manager (create/update secrets)
- Step Functions (create state machines)
- EventBridge (create/update rules)

### GitHub Token Setup
1. Go to GitHub Settings → Developer settings → Personal access tokens
2. Generate new token with `repo` scope
3. Copy the token (starts with `ghp_`)

## 🚀 Deployment Process

### Step 1: Clone and Navigate
```bash
git clone <repository-url>
cd starter-kit
```

### Step 2: Deploy Infrastructure
```bash
# Make deployment script executable
chmod +x infrastructure/deploy.sh

# Deploy with default settings
./infrastructure/deploy.sh

# Or deploy with custom configuration
SCHEDULE_EXPRESSION="rate(15 minutes)" \
CHUNKING_THRESHOLD=30 \
REGION="us-west-2" \
./infrastructure/deploy.sh
```

### Step 3: Configure GitHub Token
```bash
# Replace 'ghp_your_token_here' with your actual GitHub token
aws secretsmanager update-secret \
  --secret-id github-token \
  --secret-string 'ghp_your_token_here' \
  --region us-east-1
```

## 🏗️ What Gets Deployed

### AWS Resources Created
- **S3 Bucket**: `github-metrics-{account-id}-{region}` for storing results
- **Lambda Functions**:
  - `github-change-detector`: Detects changes and determines load type
  - `github-metrics-collector`: Collects GitHub metrics data
- **Step Functions**: `github-metrics-workflow` orchestrates the collection process
- **EventBridge Rule**: `github-metrics-collection-schedule` triggers workflow
- **IAM Role**: `github-metrics-lambda-execution-role` with required permissions
- **Secrets Manager**: `github-token` stores GitHub personal access token

### Deployment Configuration Options
```bash
# Schedule frequency (default: every 10 minutes)
SCHEDULE_EXPRESSION="rate(10 minutes)"    # Every 10 minutes
SCHEDULE_EXPRESSION="rate(1 hour)"        # Every hour
SCHEDULE_EXPRESSION="cron(0 9 * * ? *)"   # Daily at 9 AM UTC

# Chunking threshold (default: 20 repositories)
CHUNKING_THRESHOLD=20    # Enable chunking for 20+ repos
CHUNKING_THRESHOLD=50    # Enable chunking for 50+ repos

# AWS Region (default: us-east-1)
REGION="us-east-1"       # US East (N. Virginia)
REGION="us-west-2"       # US West (Oregon)
REGION="eu-west-1"       # Europe (Ireland)
```

## ⚡ How It Works

### Automated Execution Flow
1. **EventBridge Trigger**: Scheduled rule triggers Step Functions workflow
2. **Change Detection**: Lambda function checks for GitHub changes
3. **Load Decision**: Determines full vs incremental load based on changes
4. **Chunking Decision**: Automatically chunks large repository sets (20+ repos)
5. **Data Collection**: Collects metrics from GitHub API
6. **Data Storage**: Stores results in S3 as JSON and CSV

### Load Types
- **Full Load**: Complete data refresh (first run + every 24 hours)
- **Incremental Load**: Only when changes detected (90% cost reduction)
- **Chunked Processing**: Parallel processing for 20+ repositories

## ✅ Post-Deployment Verification

### 1. Verify Deployment Success
```bash
# Check CloudFormation stack status
aws cloudformation describe-stacks \
  --stack-name github-metrics-collection \
  --region us-east-1 \
  --query 'Stacks[0].StackStatus'

# Should return: "CREATE_COMPLETE"
```

### 2. Verify Lambda Functions
```bash
# Test change detector
aws lambda invoke \
  --function-name github-change-detector \
  --region us-east-1 \
  --payload '{}' \
  response.json

# Check response
cat response.json
```

### 3. Verify EventBridge Schedule
```bash
# Check schedule rule
aws events describe-rule \
  --name github-metrics-collection-schedule \
  --region us-east-1

# Check rule targets
aws events list-targets-by-rule \
  --rule github-metrics-collection-schedule \
  --region us-east-1
```

## 🔄 Manual Execution

### Trigger Step Functions Workflow
```bash
# Start execution manually
aws stepfunctions start-execution \
  --state-machine-arn arn:aws:states:us-east-1:ACCOUNT-ID:stateMachine:github-metrics-workflow \
  --region us-east-1

# Monitor execution
aws stepfunctions list-executions \
  --state-machine-arn arn:aws:states:us-east-1:ACCOUNT-ID:stateMachine:github-metrics-workflow \
  --region us-east-1
```

### Check Execution Status
```bash
# Get execution ARN from list-executions output
aws stepfunctions describe-execution \
  --execution-arn "EXECUTION-ARN" \
  --region us-east-1
```

## 📊 Accessing Results

### Download from S3 Bucket
```bash
# List bucket contents
aws s3 ls s3://github-metrics-ACCOUNT-ID-REGION/

# Download JSON results from output folder (recommended)
aws s3 cp s3://github-metrics-ACCOUNT-ID-REGION/output/response.json ./

# Download CSV results from output folder
aws s3 cp s3://github-metrics-ACCOUNT-ID-REGION/output/response.csv ./

# Alternative: Download from root folder (backward compatibility)
aws s3 cp s3://github-metrics-ACCOUNT-ID-REGION/response.json ./

# View JSON results
cat response.json | jq '.'
```

### Result File Structure
```json
{
  "summary": {
    "totalRepositories": 15,
    "totalCommits": 1250,
    "totalPullRequests": 89,
    "totalIssues": 45,
    "totalTags": 23,
    "totalContributors": 8
  },
  "repositories": [
    {
      "name": "user/repo-name",
      "description": "Repository description",
      "language": "Python",
      "stars": 12,
      "forks": 3,
      "commits": 156,
      "pullRequests": 12,
      "issues": 5,
      "tags": 2,
      "contributors": 3
    }
  ],
  "lastUpdated": "2025-11-17T10:30:00.000Z",
  "loadType": "incremental"
}
```

## 📈 Monitoring and Logs

### CloudWatch Logs
```bash
# View change detector logs
aws logs tail /aws/lambda/github-change-detector --follow --region us-east-1

# View collector logs
aws logs tail /aws/lambda/github-metrics-collector --follow --region us-east-1

# View Step Functions logs
aws logs tail /aws/stepfunctions/github-metrics-workflow --follow --region us-east-1
```

### Step Functions Console
1. Go to AWS Step Functions Console
2. Select `github-metrics-workflow`
3. View execution history and details
4. Monitor execution progress in real-time

### EventBridge Monitoring
```bash
# Check rule metrics
aws cloudwatch get-metric-statistics \
  --namespace AWS/Events \
  --metric-name SuccessfulInvocations \
  --dimensions Name=RuleName,Value=github-metrics-collection-schedule \
  --start-time 2025-11-17T00:00:00Z \
  --end-time 2025-11-17T23:59:59Z \
  --period 3600 \
  --statistics Sum \
  --region us-east-1
```

## ⚙️ Configuration Management

### Update Schedule
```bash
# Change to hourly execution
aws events put-rule \
  --name github-metrics-collection-schedule \
  --schedule-expression "rate(1 hour)" \
  --region us-east-1

# Change to daily at 9 AM UTC
aws events put-rule \
  --name github-metrics-collection-schedule \
  --schedule-expression "cron(0 9 * * ? *)" \
  --region us-east-1
```

### Update Chunking Threshold
```bash
# Update environment variable
aws lambda update-function-configuration \
  --function-name github-change-detector \
  --environment Variables='{CHUNKING_THRESHOLD=50,BUCKET_NAME=github-metrics-ACCOUNT-ID-REGION,SECRET_NAME=arn:aws:secretsmanager:us-east-1:ACCOUNT-ID:secret:github-token-XXXXX}' \
  --region us-east-1
```

### Update GitHub Token
```bash
# Update token in Secrets Manager
aws secretsmanager update-secret \
  --secret-id github-token \
  --secret-string 'ghp_new_token_here' \
  --region us-east-1
```

## 🔧 Troubleshooting

### Common Issues

#### 1. Lambda Import Error
**Error**: `Unable to import module 'detector': No module named 'detector'`
**Solution**: Dependencies not properly packaged
```bash
# Redeploy with fixed packaging
./deploy.sh
```

#### 2. Dependency Conflicts
**Error**: `pip's dependency resolver... dependency conflicts`
**Solution**: The deploy script uses isolated dependency installation to avoid conflicts with system packages. This is normal and doesn't affect Lambda functionality.

#### 3. GitHub API Rate Limits
**Error**: `403 Forbidden` responses
**Solution**: Wait for rate limit reset or use GitHub App token
```bash
# Check rate limit status
curl -H "Authorization: token YOUR_TOKEN" https://api.github.com/rate_limit
```

#### 3. EventBridge Not Triggering
**Error**: Step Functions not executing on schedule
**Solution**: Check rule configuration
```bash
# Verify rule is enabled
aws events describe-rule --name github-metrics-collection-schedule --region us-east-1

# Check rule targets
aws events list-targets-by-rule --rule github-metrics-collection-schedule --region us-east-1
```

#### 4. S3 Access Denied
**Error**: Cannot write to S3 bucket
**Solution**: Check IAM permissions
```bash
# Test S3 access
aws s3 ls s3://github-metrics-ACCOUNT-ID-REGION/
```

### Debug Commands
```bash
# Check Lambda function configuration
aws lambda get-function-configuration --function-name github-change-detector --region us-east-1

# Test Lambda function
aws lambda invoke --function-name github-change-detector --payload '{}' test-response.json --region us-east-1

# Check Step Functions definition
aws stepfunctions describe-state-machine --state-machine-arn arn:aws:states:us-east-1:ACCOUNT-ID:stateMachine:github-metrics-workflow --region us-east-1
```

## 🧹 Cleanup

### Remove All Resources
```bash
# Make cleanup script executable
chmod +x infrastructure/cleanup.sh

# Remove all deployed resources
./infrastructure/cleanup.sh

# Confirm deletion when prompted
# WARNING: This action cannot be undone
```

### Manual Cleanup (if script fails)
```bash
# Delete CloudFormation stack
aws cloudformation delete-stack --stack-name github-metrics-collection --region us-east-1

# Delete S3 bucket contents
aws s3 rm s3://github-metrics-ACCOUNT-ID-REGION --recursive

# Delete S3 bucket
aws s3 rb s3://github-metrics-ACCOUNT-ID-REGION

# Delete secret
aws secretsmanager delete-secret --secret-id github-token --force-delete-without-recovery --region us-east-1
```

## 📞 Support

### Getting Help
- Check CloudWatch logs for detailed error messages
- Review Step Functions execution history
- Verify GitHub token permissions and rate limits
- Ensure AWS credentials have required permissions

### Performance Optimization
- **Small portfolios (1-20 repos)**: Use default settings
- **Medium portfolios (20-100 repos)**: Enable chunking with threshold 20
- **Large portfolios (100+ repos)**: Set chunking threshold to 50, consider hourly schedule

### Cost Optimization
- Incremental loads reduce API calls by 90%
- Adjust schedule frequency based on update needs
- Monitor CloudWatch costs for Lambda execution time

---

**🚀 Deploy in under 5 minutes | 📈 Enterprise-grade analytics | 🔧 Zero maintenance required**
