#!/bin/bash
# create-quicksight-dashboard.sh - Recreates the Development Portfolio Health
# Dashboard in Amazon QuickSight, backed by the metrics this solution writes to S3.
#
# Prerequisites: an active QuickSight subscription in this account/region, and
# the metrics pipeline already deployed (so response.json/csv exist in S3).
#
# Usage:
#   REGION=<region> DATA_SOURCE_S3_BUCKET=<your-metrics-bucket> ./create-quicksight-dashboard.sh
set -e

# ============ CONFIGURATION ============
REGION="${REGION:-us-east-1}"
DATASET_ID="github-metrics-dataset"
DASHBOARD_ID="dev-portfolio-health-dashboard"
DASHBOARD_NAME="Development Portfolio Health Dashboard"
# S3 bucket holding the metrics + a QuickSight manifest.json (REQUIRED)
DATA_SOURCE_S3_BUCKET="${DATA_SOURCE_S3_BUCKET:?Set DATA_SOURCE_S3_BUCKET to your metrics bucket, e.g. git-dashboard-metrics-<account-id>-<region>}"
DATA_SOURCE_MANIFEST_KEY="${DATA_SOURCE_MANIFEST_KEY:-manifest.json}"
# ========================================

ACCOUNT_ID=$(aws sts get-caller-identity --query Account --output text)

# Get QuickSight user ARN
QS_USER_ARN=$(aws quicksight list-users \
  --aws-account-id "$ACCOUNT_ID" \
  --namespace default \
  --region "$REGION" \
  --query 'UserList[0].Arn' \
  --output text)

echo "Account: $ACCOUNT_ID"
echo "QS User: $QS_USER_ARN"

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
