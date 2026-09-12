#!/bin/bash
# create-quicksight-dashboard.sh - Recreates the Development Portfolio Health
# Dashboard in Amazon QuickSight, backed by the metrics this solution writes to S3.
#
# This script is self-contained: it derives the aggregate CSV and generates the
# QuickSight manifest itself, so neither needs to be pre-created.
#
# Prerequisites: an active QuickSight subscription in this account/region (with at
# least one user), and the metrics pipeline already run (so an aggregate
# response.json exists in S3).
#
# Configuration:
#   ACCOUNT_ID              - Auto-detected via `aws sts get-caller-identity`.
#                             It is NOT set manually.
#   DATA_SOURCE_S3_BUCKET   - REQUIRED. The metrics bucket, following the naming
#                             pattern git-dashboard-metrics-<account-id>-<region>.
#   DATA_SOURCE_MANIFEST_KEY- Optional, defaults to manifest.json (overridable).
#                             This script GENERATES and uploads the manifest
#                             itself; there is no need to pre-create it.
#   AGGREGATE_CSV_KEY        - Optional, defaults to output/quicksight/aggregate.csv.
#                             The script derives a single-row aggregate CSV from
#                             the pipeline's output/response.json and uploads it
#                             to this key (never touching the per-repo response.csv).
#
# Usage:
#   REGION=<region> DATA_SOURCE_S3_BUCKET=<your-metrics-bucket> ./create-quicksight-dashboard.sh
#
# ---------------------------------------------------------------------------
# Manual QuickSight console setup (ALTERNATIVE to running this script)
# ---------------------------------------------------------------------------
# This script already automates the data source, dataset, and dashboard via the
# AWS CLI. Only follow the manual console flow below if you prefer clicking
# through the QuickSight console INSTEAD of running this script - do not do both,
# or you will create duplicate resources.
#
# IMPORTANT: response.json is a nested document (it contains incrementalChanges
# and a repositories array), and the dataset is defined as flat CSV with the
# columns commit,tag,pullRequest,issues,repositoryCount,lastUpdated. Note that CSV only exists after this script has run at least once to
# generate and upload it.
#
# Corrected manifest.json (points at a CSV data file; the manifest itself is JSON):
#   {
#     "fileLocations": [
#       { "URIs": [ "s3://git-dashboard-metrics-<account-id>-<region>/output/quicksight/aggregate.csv" ] }
#     ],
#     "globalUploadSettings": {
#       "format": "CSV",
#       "delimiter": ",",
#       "textqualifier": "\"",
#       "containsHeader": "true"
#     }
#   }
#
# ---------------------------------------------------------------------------
set -e

# ============ CONFIGURATION ============
REGION="${REGION:-us-east-1}"
DATASET_ID="github-metrics-dataset"
DASHBOARD_ID="dev-portfolio-health-dashboard"
DASHBOARD_NAME="Development Portfolio Health Dashboard"
# S3 bucket holding the metrics + a QuickSight manifest.json (REQUIRED)
DATA_SOURCE_S3_BUCKET="${DATA_SOURCE_S3_BUCKET:?Set DATA_SOURCE_S3_BUCKET to your metrics bucket, following the naming pattern git-dashboard-metrics-<account-id>-<region>}"
DATA_SOURCE_MANIFEST_KEY="${DATA_SOURCE_MANIFEST_KEY:-manifest.json}"
# Dedicated key for the derived single-row aggregate CSV (must NOT collide with
# the pipeline's per-repository output/response.csv).
AGGREGATE_CSV_KEY="${AGGREGATE_CSV_KEY:-output/quicksight/aggregate.csv}"
# ========================================

# ============ PRE-FLIGHT VALIDATION ============
# Resolve the account ID (auto-detected, never supplied manually).
ACCOUNT_ID=$(aws sts get-caller-identity --query Account --output text 2>/dev/null || true)
if [ -z "$ACCOUNT_ID" ] || [ "$ACCOUNT_ID" = "None" ]; then
  echo "ERROR: Could not resolve an AWS account ID." >&2
  echo "       Configure your AWS credentials and region (e.g. run 'aws configure'" >&2
  echo "       or export AWS_ACCESS_KEY_ID/AWS_SECRET_ACCESS_KEY/AWS_REGION) and retry." >&2
  exit 1
fi

# Resolve the QuickSight user ARN.
QS_USER_ARN=$(aws quicksight list-users \
  --aws-account-id "$ACCOUNT_ID" \
  --namespace default \
  --region "$REGION" \
  --query 'UserList[0].Arn' \
  --output text 2>/dev/null || true)
if [ -z "$QS_USER_ARN" ] || [ "$QS_USER_ARN" = "None" ]; then
  echo "ERROR: No QuickSight user found in account $ACCOUNT_ID (region $REGION)." >&2
  echo "       Activate a QuickSight subscription with at least one user in this" >&2
  echo "       region, then retry." >&2
  exit 1
fi

# Verify the metrics bucket exists.
if ! aws s3api head-bucket --bucket "$DATA_SOURCE_S3_BUCKET" --region "$REGION" 2>/dev/null; then
  echo "ERROR: S3 bucket '$DATA_SOURCE_S3_BUCKET' was not found or is not accessible." >&2
  echo "       Expected the metrics bucket (naming pattern" >&2
  echo "       git-dashboard-metrics-<account-id>-<region>). Check DATA_SOURCE_S3_BUCKET." >&2
  exit 1
fi

# Verify an aggregate response.json exists (prefer output/response.json, fall
# back to root response.json). Disable exit-on-error around the probes so the
# fallback logic and clear message work under 'set -e'.
RESPONSE_JSON_KEY=""
set +e
aws s3api head-object --bucket "$DATA_SOURCE_S3_BUCKET" --key "output/response.json" --region "$REGION" >/dev/null 2>&1
if [ $? -eq 0 ]; then
  RESPONSE_JSON_KEY="output/response.json"
else
  aws s3api head-object --bucket "$DATA_SOURCE_S3_BUCKET" --key "response.json" --region "$REGION" >/dev/null 2>&1
  if [ $? -eq 0 ]; then
    RESPONSE_JSON_KEY="response.json"
  fi
fi
set -e
if [ -z "$RESPONSE_JSON_KEY" ]; then
  echo "ERROR: No aggregate response.json found in bucket '$DATA_SOURCE_S3_BUCKET'." >&2
  echo "       Looked for 'output/response.json' and 'response.json'." >&2
  echo "       Run the metrics pipeline first so it writes output/response.json, then retry." >&2
  exit 1
fi
# ================================================

# ============ CONFIG TRANSPARENCY ============
echo "Resolved configuration:"
echo "  Account (auto-detected): $ACCOUNT_ID"
echo "  Region:                  $REGION"
echo "  Bucket:                  $DATA_SOURCE_S3_BUCKET"
echo "  Manifest key:            $DATA_SOURCE_MANIFEST_KEY"
echo "  Aggregate CSV key:       $AGGREGATE_CSV_KEY"
echo "  QS User ARN:             $QS_USER_ARN"
echo "  Response JSON source:    $RESPONSE_JSON_KEY"
# ==============================================

# ============ DERIVE AGGREGATE CSV ============
echo "==> Deriving aggregate CSV from s3://$DATA_SOURCE_S3_BUCKET/$RESPONSE_JSON_KEY ..."
aws s3 cp "s3://$DATA_SOURCE_S3_BUCKET/$RESPONSE_JSON_KEY" /tmp/qs-response.json --region "$REGION"

python3 - <<'PYEOF'
import csv
import json

with open("/tmp/qs-response.json") as f:
    data = json.load(f)

# Normalized column order matching the dataset's declared InputColumns.
columns = ["commit", "tag", "pullRequest", "issues", "repositoryCount", "lastUpdated"]

row = []
for col in columns:
    if col == "lastUpdated":
        row.append(data.get(col, ""))
    else:
        row.append(data.get(col, 0))

with open("/tmp/qs-aggregate.csv", "w", newline="") as f:
    writer = csv.writer(f)
    writer.writerow(columns)
    writer.writerow(row)
PYEOF

echo "==> Uploading aggregate CSV to s3://$DATA_SOURCE_S3_BUCKET/$AGGREGATE_CSV_KEY ..."
aws s3 cp /tmp/qs-aggregate.csv "s3://$DATA_SOURCE_S3_BUCKET/$AGGREGATE_CSV_KEY" \
  --content-type text/csv --region "$REGION"
# ==============================================

# ============ GENERATE QUICKSIGHT MANIFEST ============
echo "==> Generating QuickSight manifest ..."
cat > /tmp/qs-manifest.json << MANIFESTEOF
{
  "fileLocations": [ { "URIs": [ "s3://$DATA_SOURCE_S3_BUCKET/$AGGREGATE_CSV_KEY" ] } ],
  "globalUploadSettings": { "format": "CSV", "delimiter": ",", "textqualifier": "\"", "containsHeader": "true" }
}
MANIFESTEOF

echo "==> Uploading manifest to s3://$DATA_SOURCE_S3_BUCKET/$DATA_SOURCE_MANIFEST_KEY ..."
aws s3 cp /tmp/qs-manifest.json "s3://$DATA_SOURCE_S3_BUCKET/$DATA_SOURCE_MANIFEST_KEY" \
  --content-type application/json --region "$REGION"
# ======================================================

# Step 1: Create DataSource
echo "==> Creating S3 data source..."
aws quicksight create-data-source \
  --aws-account-id "$ACCOUNT_ID" \
  --data-source-id "github-s3-source" \
  --name "GitHub S3 Source" \
  --type S3 \
  --data-source-parameters "{
    \"S3Parameters\": {
      \"ManifestFileLocation\": {
        \"Bucket\": \"${DATA_SOURCE_S3_BUCKET}\",
        \"Key\": \"${DATA_SOURCE_MANIFEST_KEY}\"
      }
    }
  }" \
  --permissions "[{
    \"Principal\": \"${QS_USER_ARN}\",
    \"Actions\": [
      \"quicksight:DescribeDataSource\",
      \"quicksight:DescribeDataSourcePermissions\",
      \"quicksight:PassDataSource\",
      \"quicksight:UpdateDataSource\",
      \"quicksight:DeleteDataSource\",
      \"quicksight:UpdateDataSourcePermissions\"
    ]
  }]" \
  --region "$REGION" 2>/dev/null || echo "    Data source may already exist, continuing..."

sleep 5

# Step 2: Create Dataset
echo "==> Creating dataset..."
DS_ARN="arn:aws:quicksight:${REGION}:${ACCOUNT_ID}:datasource/github-s3-source"

aws quicksight create-data-set \
  --aws-account-id "$ACCOUNT_ID" \
  --data-set-id "$DATASET_ID" \
  --name "GitHub Metrics Dataset" \
  --import-mode SPICE \
  --physical-table-map "{
    \"github-table\": {
      \"S3Source\": {
        \"DataSourceArn\": \"${DS_ARN}\",
        \"InputColumns\": [
          {\"Name\": \"commit\", \"Type\": \"INTEGER\"},
          {\"Name\": \"tag\", \"Type\": \"INTEGER\"},
          {\"Name\": \"pullRequest\", \"Type\": \"INTEGER\"},
          {\"Name\": \"issues\", \"Type\": \"INTEGER\"},
          {\"Name\": \"repositoryCount\", \"Type\": \"INTEGER\"},
          {\"Name\": \"lastUpdated\", \"Type\": \"STRING\"}
        ],
        \"UploadSettings\": {
          \"Format\": \"CSV\",
          \"StartFromRow\": 1,
          \"ContainsHeader\": true,
          \"Delimiter\": \",\"
        }
      }
    }
  }" \
  --permissions "[{
    \"Principal\": \"${QS_USER_ARN}\",
    \"Actions\": [
      \"quicksight:DescribeDataSet\",
      \"quicksight:DescribeDataSetPermissions\",
      \"quicksight:PassDataSet\",
      \"quicksight:DescribeIngestion\",
      \"quicksight:ListIngestions\",
      \"quicksight:UpdateDataSet\",
      \"quicksight:DeleteDataSet\",
      \"quicksight:CreateIngestion\",
      \"quicksight:CancelIngestion\",
      \"quicksight:UpdateDataSetPermissions\"
    ]
  }]" \
  --region "$REGION" 2>/dev/null || echo "    Dataset may already exist, continuing..."

sleep 5

DATASET_ARN="arn:aws:quicksight:${REGION}:${ACCOUNT_ID}:dataset/${DATASET_ID}"

# Step 3: Create Dashboard with definition
echo "==> Creating dashboard..."

cat > /tmp/dashboard-definition.json << 'DEFEOF'
{
  "DataSetIdentifierDeclarations": [
    {
      "Identifier": "github-metrics",
      "DataSetArn": "DATASET_ARN_PLACEHOLDER"
    }
  ],
  "Sheets": [
    {
      "SheetId": "sheet-1",
      "Name": "Development Activity",
      "Visuals": [
        {
          "KPIVisual": {
            "VisualId": "kpi-commits",
            "Title": {"Visibility": "VISIBLE", "FormatText": {"PlainText": "Total Commits Across All Repositories"}},
            "Subtitle": {"Visibility": "VISIBLE", "FormatText": {"PlainText": "Cumulative development activity measured by commit count"}},
            "ChartConfiguration": {
              "FieldWells": {
                "Values": [{"NumericalMeasureField": {"FieldId": "commit-val", "Column": {"DataSetIdentifier": "github-metrics", "ColumnName": "commit"}, "AggregationFunction": {"SimpleNumericalAggregation": "SUM"}}}]
              }
            }
          }
        },
        {
          "KPIVisual": {
            "VisualId": "kpi-prs",
            "Title": {"Visibility": "VISIBLE", "FormatText": {"PlainText": "Total Pull Requests Submitted"}},
            "Subtitle": {"Visibility": "VISIBLE", "FormatText": {"PlainText": "Aggregate count of code review requests"}},
            "ChartConfiguration": {
              "FieldWells": {
                "Values": [{"NumericalMeasureField": {"FieldId": "pr-val", "Column": {"DataSetIdentifier": "github-metrics", "ColumnName": "pullRequest"}, "AggregationFunction": {"SimpleNumericalAggregation": "SUM"}}}]
              }
            }
          }
        },
        {
          "KPIVisual": {
            "VisualId": "kpi-issues",
            "Title": {"Visibility": "VISIBLE", "FormatText": {"PlainText": "Total Issues Tracked"}},
            "Subtitle": {"Visibility": "VISIBLE", "FormatText": {"PlainText": "Complete count of reported issues and bugs"}},
            "ChartConfiguration": {
              "FieldWells": {
                "Values": [{"NumericalMeasureField": {"FieldId": "issues-val", "Column": {"DataSetIdentifier": "github-metrics", "ColumnName": "issues"}, "AggregationFunction": {"SimpleNumericalAggregation": "SUM"}}}]
              }
            }
          }
        },
        {
          "KPIVisual": {
            "VisualId": "kpi-tags",
            "Title": {"Visibility": "VISIBLE", "FormatText": {"PlainText": "Total Tags Created"}},
            "Subtitle": {"Visibility": "VISIBLE", "FormatText": {"PlainText": "Cumulative version tags and release markers"}},
            "ChartConfiguration": {
              "FieldWells": {
                "Values": [{"NumericalMeasureField": {"FieldId": "tag-val", "Column": {"DataSetIdentifier": "github-metrics", "ColumnName": "tag"}, "AggregationFunction": {"SimpleNumericalAggregation": "SUM"}}}]
              }
            }
          }
        },
        {
          "KPIVisual": {
            "VisualId": "kpi-repos",
            "Title": {"Visibility": "VISIBLE", "FormatText": {"PlainText": "Number of Active Repositories"}},
            "Subtitle": {"Visibility": "VISIBLE", "FormatText": {"PlainText": "Count of repositories in the development portfolio"}},
            "ChartConfiguration": {
              "FieldWells": {
                "Values": [{"NumericalMeasureField": {"FieldId": "repo-val", "Column": {"DataSetIdentifier": "github-metrics", "ColumnName": "repositoryCount"}, "AggregationFunction": {"SimpleNumericalAggregation": "SUM"}}}]
              }
            }
          }
        },
        {
          "PieChartVisual": {
            "VisualId": "donut-prs",
            "Title": {"Visibility": "VISIBLE", "FormatText": {"PlainText": "Pull Request Distribution by Update Period"}},
            "Subtitle": {"Visibility": "VISIBLE", "FormatText": {"PlainText": "Proportional breakdown of code review requests"}},
            "ChartConfiguration": {
              "FieldWells": {
                "PieChartAggregatedFieldWells": {
                  "Category": [{"CategoricalDimensionField": {"FieldId": "pr-cat", "Column": {"DataSetIdentifier": "github-metrics", "ColumnName": "lastUpdated"}}}],
                  "Values": [{"NumericalMeasureField": {"FieldId": "pr-size", "Column": {"DataSetIdentifier": "github-metrics", "ColumnName": "pullRequest"}, "AggregationFunction": {"SimpleNumericalAggregation": "SUM"}}}]
                }
              },
              "DonutOptions": {"ArcOptions": {"ArcThickness": "WHOLE"}}
            }
          }
        },
        {
          "PieChartVisual": {
            "VisualId": "donut-issues",
            "Title": {"Visibility": "VISIBLE", "FormatText": {"PlainText": "Issue Distribution by Update Period"}},
            "Subtitle": {"Visibility": "VISIBLE", "FormatText": {"PlainText": "Proportional breakdown of tracked issues over time"}},
            "ChartConfiguration": {
              "FieldWells": {
                "PieChartAggregatedFieldWells": {
                  "Category": [{"CategoricalDimensionField": {"FieldId": "iss-cat", "Column": {"DataSetIdentifier": "github-metrics", "ColumnName": "lastUpdated"}}}],
                  "Values": [{"NumericalMeasureField": {"FieldId": "iss-size", "Column": {"DataSetIdentifier": "github-metrics", "ColumnName": "issues"}, "AggregationFunction": {"SimpleNumericalAggregation": "SUM"}}}]
                }
              },
              "DonutOptions": {"ArcOptions": {"ArcThickness": "MEDIUM"}}
            }
          }
        },
        {
          "FunnelChartVisual": {
            "VisualId": "funnel-tags",
            "Title": {"Visibility": "VISIBLE", "FormatText": {"PlainText": "Tag Creation Progression"}},
            "Subtitle": {"Visibility": "VISIBLE", "FormatText": {"PlainText": "Funnel view of version tags across update periods"}},
            "ChartConfiguration": {
              "FieldWells": {
                "FunnelChartAggregatedFieldWells": {
                  "Category": [{"CategoricalDimensionField": {"FieldId": "tag-cat", "Column": {"DataSetIdentifier": "github-metrics", "ColumnName": "lastUpdated"}}}],
                  "Values": [{"NumericalMeasureField": {"FieldId": "tag-size", "Column": {"DataSetIdentifier": "github-metrics", "ColumnName": "tag"}, "AggregationFunction": {"SimpleNumericalAggregation": "SUM"}}}]
                }
              }
            }
          }
        }
      ],
      "Layouts": [
        {
          "Configuration": {
            "GridLayout": {
              "Elements": [
                {"ElementId": "kpi-commits", "ElementType": "VISUAL", "ColumnIndex": 0, "RowIndex": 0, "ColumnSpan": 9, "RowSpan": 6},
                {"ElementId": "kpi-prs", "ElementType": "VISUAL", "ColumnIndex": 9, "RowIndex": 0, "ColumnSpan": 9, "RowSpan": 6},
                {"ElementId": "kpi-issues", "ElementType": "VISUAL", "ColumnIndex": 18, "RowIndex": 0, "ColumnSpan": 9, "RowSpan": 6},
                {"ElementId": "kpi-tags", "ElementType": "VISUAL", "ColumnIndex": 27, "RowIndex": 0, "ColumnSpan": 9, "RowSpan": 6},
                {"ElementId": "kpi-repos", "ElementType": "VISUAL", "ColumnIndex": 0, "RowIndex": 6, "ColumnSpan": 18, "RowSpan": 8},
                {"ElementId": "donut-prs", "ElementType": "VISUAL", "ColumnIndex": 18, "RowIndex": 6, "ColumnSpan": 18, "RowSpan": 8},
                {"ElementId": "donut-issues", "ElementType": "VISUAL", "ColumnIndex": 0, "RowIndex": 14, "ColumnSpan": 18, "RowSpan": 8},
                {"ElementId": "funnel-tags", "ElementType": "VISUAL", "ColumnIndex": 18, "RowIndex": 14, "ColumnSpan": 18, "RowSpan": 8}
              ]
            }
          }
        }
      ]
    }
  ]
}
DEFEOF

# Replace placeholder with actual dataset ARN
sed -i '' "s|DATASET_ARN_PLACEHOLDER|${DATASET_ARN}|g" /tmp/dashboard-definition.json

aws quicksight create-dashboard \
  --aws-account-id "$ACCOUNT_ID" \
  --dashboard-id "$DASHBOARD_ID" \
  --name "$DASHBOARD_NAME" \
  --definition file:///tmp/dashboard-definition.json \
  --permissions "[{
    \"Principal\": \"${QS_USER_ARN}\",
    \"Actions\": [
      \"quicksight:DescribeDashboard\",
      \"quicksight:ListDashboardVersions\",
      \"quicksight:UpdateDashboardPermissions\",
      \"quicksight:QueryDashboard\",
      \"quicksight:UpdateDashboard\",
      \"quicksight:DeleteDashboard\",
      \"quicksight:UpdateDashboardPublishedVersion\",
      \"quicksight:DescribeDashboardPermissions\"
    ]
  }]" \
  --region "$REGION"

echo ""
echo "==> Waiting for dashboard creation..."
sleep 10

# Check status
STATUS=$(aws quicksight describe-dashboard \
  --aws-account-id "$ACCOUNT_ID" \
  --dashboard-id "$DASHBOARD_ID" \
  --region "$REGION" \
  --query 'Dashboard.Version.Status' \
  --output text)

echo "========================================="
echo "  Dashboard Status: $STATUS"
echo "  Dashboard ID: $DASHBOARD_ID"
echo "  URL: https://${REGION}.quicksight.aws.amazon.com/sn/dashboards/${DASHBOARD_ID}"
echo "========================================="
