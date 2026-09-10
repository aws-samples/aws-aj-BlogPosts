# Git Dashboard Architecture

```
┌─────────────────────────────────────────────────────────────────────────────┐
│                          EventBridge Schedule Rule                          │
│                         (Every 10 minutes / Custom)                         │
└────────────────────────────────┬────────────────────────────────────────────┘
                                 │ Triggers
                                 ▼
┌─────────────────────────────────────────────────────────────────────────────┐
│                      Step Functions State Machine                           │
│                      (github-metrics-workflow)                              │
│                                                                             │
│  ┌─────────────┐      ┌──────────────┐      ┌─────────────────┐          │
│  │   Detect    │─────▶│   Chunking   │─────▶│    Collect      │          │
│  │   Changes   │      │   Decision   │      │    Metrics      │          │
│  └─────────────┘      └──────────────┘      └─────────────────┘          │
└────────────────────────────────────────────────────────────────────────────┘
         │                      │                        │
         │                      │                        │
         ▼                      ▼                        ▼
┌──────────────────┐   ┌──────────────────┐   ┌──────────────────┐
│  Detector Lambda │   │  Detector Lambda │   │ Collector Lambda │
│                  │   │                  │   │                  │
│ • Check repos    │   │ • Count repos    │   │ • Fetch commits  │
│ • Detect changes │   │ • Create chunks  │   │ • Fetch PRs      │
│ • Load type      │   │ • If > threshold │   │ • Fetch issues   │
│   (full/incr)    │   │                  │   │ • Contributors   │
└────────┬─────────┘   └──────────────────┘   └────────┬─────────┘
         │                                               │
         │                                               │
         ▼                                               ▼
┌─────────────────────────────────────────────────────────────────────────────┐
│                        AWS Secrets Manager                                  │
│                                                                             │
│  ┌──────────────────────────┐      ┌──────────────────────────┐          │
│  │ git-dashboard/           │      │ git-dashboard/           │          │
│  │ github-token             │      │ gitlab-token             │          │
│  │ (if platform=github)     │      │ (if platform=gitlab)     │          │
│  └──────────────────────────┘      └──────────────────────────┘          │
└─────────────────────────────────────────────────────────────────────────────┘
                                 │
                                 │ Reads tokens
                                 ▼
┌─────────────────────────────────────────────────────────────────────────────┐
│                           Git Platforms                                     │
│                                                                             │
│  ┌──────────────────────────┐      ┌──────────────────────────┐          │
│  │      GitHub API          │      │      GitLab API          │          │
│  │  api.github.com          │      │  gitlab.com/api          │          │
│  │  (if enabled)            │      │  (if enabled)            │          │
│  └──────────────────────────┘      └──────────────────────────┘          │
└─────────────────────────────────────────────────────────────────────────────┘
                                 │
                                 │ Returns data
                                 ▼
┌─────────────────────────────────────────────────────────────────────────────┐
│                              S3 Bucket                                      │
│                  git-dashboard-metrics-{account}-{region}                   │
│                                                                             │
│  ┌──────────────────────────────────────────────────────────────┐         │
│  │  output/                                                      │         │
│  │    ├── response.json  (Detailed repo metrics)                │         │
│  │    └── response.csv   (CSV format)                           │         │
│  │                                                               │         │
│  │  last_check.json      (Timestamp for incremental loads)      │         │
│  │  load_metadata.json   (Load type tracking)                   │         │
│  │                                                               │         │
│  │  chunks/              (Temporary chunk results)              │         │
│  │    └── chunk_*_results.json                                  │         │
│  └──────────────────────────────────────────────────────────────┘         │
└─────────────────────────────────────────────────────────────────────────────┘
                                 │
                                 │ Consumed by
                                 ▼
┌─────────────────────────────────────────────────────────────────────────────┐
│                         Visualization Layer                                 │
│                                                                             │
│  ┌──────────────────────────┐      ┌──────────────────────────┐          │
│  │      Grafana             │      │   QuickSight             │          │
│  │   (via Athena)           │      │   (Direct S3)            │          │
│  └──────────────────────────┘      └──────────────────────────┘          │
└─────────────────────────────────────────────────────────────────────────────┘
```

## Component Details

### 1. **EventBridge Schedule**
- Triggers workflow at configured intervals (default: 10 minutes)
- Configurable via `--schedule` parameter

### 2. **Step Functions Workflow**
- Orchestrates the collection process
- Handles chunking for large repository counts
- Manages parallel processing

### 3. **Detector Lambda**
- Determines if data collection is needed
- Checks for repository changes
- Decides between full vs incremental load
- Creates chunks if repo count > threshold (default: 20)

### 4. **Collector Lambda**
- Fetches detailed metrics from Git APIs
- Processes repositories (single or chunked)
- Stores results in S3

### 5. **Git Adapter**
- Abstraction layer for GitHub/GitLab APIs
- Handles authentication
- Normalizes data format

### 6. **Platform Selection**
- Controlled via `ENABLED_PLATFORMS` parameter
- Options: `github`, `gitlab`, or `github,gitlab`
- Set during deployment with `--platform` flag

### 7. **Data Storage (S3)**
- JSON format: Detailed repository metrics
- CSV format: Tabular data for analysis
- Metadata: Timestamps and load tracking

## Data Flow

1. **Scheduled Trigger** → EventBridge fires at interval
2. **Detection Phase** → Check for changes, determine load type
3. **Collection Phase** → Fetch metrics from enabled platforms
4. **Storage Phase** → Write JSON/CSV to S3
5. **Visualization** → Grafana/QuickSight reads from S3

## Deployment Parameters

| Parameter | Default | Description |
|-----------|---------|-------------|
| `--platform` | `both` | `github`, `gitlab`, or `both` |
| `--region` | `us-east-1` | AWS region |
| `--schedule` | `rate(10 minutes)` | Collection frequency |
| `CHUNKING_THRESHOLD` | `20` | Repos before chunking |

## Current Deployment

- **Platform**: GitHub only
- **Region**: us-east-1
- **Schedule**: Every 10 minutes
- **Repositories**: 14 detected
- **Bucket**: `git-dashboard-metrics-<account-id>-<region>`
