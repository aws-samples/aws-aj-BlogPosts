# CloudWatch Dashboard - Final Setup

## ✅ What's Deployed

### 1. Main Dashboard (`GitDashboard-Metrics`)
- **Summary Widget**: All total* metrics in ONE widget
  - Total Users
  - Total Repositories
  - Total Commits
  - Total Pull Requests
  - Total Issues
  - Total Tags
  - Total Contributors

- **Repository-wise Widgets**: Separate widgets for each metric
  - Commits (by repository)
  - Pull Requests (by repository)
  - Issues (by repository)
  - Tags (by repository)
  - Contributors (by repository)

### 2. Metrics Structure

#### Summary Metrics
**Namespace**: `GitDashboard/Summary`
- All aggregated totals in one place
- No dimensions - just overall numbers

#### Repository Metrics
**Namespace**: `GitDashboard/Repositories`
- **Dimension**: `Repository` = `owner/repo-name`
- Allows filtering by specific repository
- Each repo has its own metrics

## 🎯 Create Custom Repository Dashboard

### Option 1: Using Python Script (Recommended)
```bash
cd CloudWatch
python3 create_custom_dashboard.py "example-org/sample-web-app"
```

### Option 2: List All Repositories
```bash
# See all repositories with metrics
aws cloudwatch list-metrics \
  --namespace GitDashboard/Repositories \
  --metric-name Commits \
  --region us-east-1 \
  --query 'Metrics[].Dimensions[?Name==`Repository`].Value[]' \
  --output table
```

### Option 3: Via Console
1. Go to CloudWatch → Dashboards
2. Create dashboard
3. Add widget → Number or Line
4. Select:
   - Namespace: `GitDashboard/Repositories`
   - Metric: `Commits`, `PullRequests`, etc.
   - Dimension: `Repository` = `Your/Repo/Name`

## 📊 View Dashboards

### Main Dashboard
```
https://console.aws.amazon.com/cloudwatch/home?region=us-east-1#dashboards:name=GitDashboard-Metrics
```

### Custom Repository Dashboards
```
https://console.aws.amazon.com/cloudwatch/home?region=us-east-1#dashboards:name=Repo-{owner}-{repo}
```

## 🔄 How It Works

```
Data Collection (Every 10 min)
    ↓
S3: response.json
    {
      "summary": {...},
      "repositories": [...]
    }
    ↓
Metrics Publisher (Every 15 min)
    ↓
CloudWatch Metrics
    ├─ GitDashboard/Summary (7 metrics)
    └─ GitDashboard/Repositories (5 metrics × 14 repos = 70 metrics)
    ↓
Dashboards
    ├─ Main Dashboard (all repos)
    └─ Custom Dashboards (specific repos)
```

## 📝 Examples

### Create Dashboard for Multiple Repos
```python
import boto3

repos = ["example-org/repo1", "example-org/repo2", "example-org/repo3"]

for repo in repos:
    import subprocess
    subprocess.run(["python3", "create_custom_dashboard.py", repo])
```

### Query Specific Repository Metrics
```bash
aws cloudwatch get-metric-statistics \
  --namespace GitDashboard/Repositories \
  --metric-name Commits \
  --dimensions Name=Repository,Value=example-org/sample-web-app \
  --start-time 2026-02-06T00:00:00Z \
  --end-time 2026-02-06T23:59:59Z \
  --period 3600 \
  --statistics Average \
  --region us-east-1
```

## 🛠️ Files

- `dashboard-v2.json` - Main dashboard with summary + repo-wise widgets
- `metrics_publisher.py` - Enhanced publisher with dimensions
- `create_custom_dashboard.py` - Script to create repo-specific dashboards
- `CUSTOM_DASHBOARD_GUIDE.md` - Detailed guide for custom dashboards

## ✨ Key Features

1. ✅ **All summary metrics in ONE widget**
2. ✅ **Repository-wise details in separate widgets**
3. ✅ **Filter by specific repository**
4. ✅ **Create custom dashboards per repository**
5. ✅ **Compare multiple repositories**
6. ✅ **Auto-updates every 15 minutes**
