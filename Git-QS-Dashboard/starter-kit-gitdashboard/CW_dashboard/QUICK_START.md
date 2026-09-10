# Quick Start - CloudWatch Dashboard

## 🚀 Deploy Everything

```bash
cd CloudWatch
./deploy-all.sh
```

## 📊 View Dashboard

https://console.aws.amazon.com/cloudwatch/home?region=us-east-1#dashboards:name=GitDashboard-Metrics

## 🔄 Refresh Metrics Manually

```bash
aws lambda invoke \
  --function-name git-metrics-publisher \
  --cli-binary-format raw-in-base64-out \
  --payload '{}' \
  --region us-east-1 \
  response.json
```

## 📈 Dashboard Widgets

### Summary (Top Row)
- Total Users
- Total Repositories  
- Total Commits
- Total Pull Requests
- Total Issues
- Total Contributors

### Repository Details
- Highest Contributor
- Estimated Branches
- Total Tags

### Charts
- Repo Activity (time series)
- Development Activity (commits, PRs, issues)

## ⏰ Auto-Update Schedule

- **Data Collection**: Every 10 minutes (Step Functions)
- **Metrics Publishing**: Every 15 minutes (Lambda)

## 🛠️ Troubleshooting

**No data showing?**
1. Wait 2-3 minutes
2. Manually invoke Lambda (see above)
3. Check logs: `aws logs tail /aws/lambda/git-metrics-publisher --follow`

**Need to update dashboard?**
```bash
cd CloudWatch
DASHBOARD_FILE=dashboard-final.json ./deploy-dashboard.sh
```
