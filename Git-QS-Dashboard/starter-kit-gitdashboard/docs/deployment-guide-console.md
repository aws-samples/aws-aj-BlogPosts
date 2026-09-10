# Manual Console Deployment Guide

Deploy the Git Metrics Collection solution (GitHub & GitLab) using only the
AWS Console. Any AWS region works.

## Prerequisites

- **This repository** cloned/downloaded to your local machine
- **AWS account** with permissions for CloudFormation, Lambda, S3, Step
  Functions, EventBridge, IAM, KMS, SQS, SNS, and Secrets Manager
- **Lambda concurrency quota**: the template reserves 8 concurrent executions;
  accounts with the default limit of 10 need a quota increase first
- **Git tokens** (either or both — a missing token is skipped gracefully):
  - GitHub PAT (`ghp_...`/`github_pat_...`) with repo read access
  - GitLab PAT (`glpat-...`) with `read_api` scope
- **Lambda package**: build it once on your machine:
  ```bash
  cd starter-kit-gitdashboard/infrastructure
  ./build-lambda-package.sh        # creates ../lambda-package.zip
  ```
  (Requires Python 3 + pip. Script deployments via deploy.sh do this automatically.)

## Step 1: Deploy the CloudFormation Stack

1. Open https://console.aws.amazon.com/cloudformation/ and pick your region
2. **Create stack** → **With new resources (standard)**
3. **Upload a template file** → choose `infrastructure/template.yaml` → **Next**
4. **Stack name**: `github-metrics-collection`
5. **Parameters**:

   | Parameter | Required? | Value |
   |---|---|---|
   | `BucketName` | **REQUIRED (no default)** | e.g. `git-dashboard-metrics-<your-account-id>-<region>` (globally unique, lowercase) |
   | `EnabledPlatforms` | optional | `github,gitlab` (default), or `github` / `gitlab` |
   | `GitLabBaseUrl` | optional | `https://gitlab.com` (default) or your self-managed URL |
   | `ScheduleExpression` | optional | `rate(10 minutes)` — note deploy.sh default; template default is `rate(5 minutes)` |
   | `ChunkingThreshold` | optional | `20` (default) |
   | `GitHubTokenSecretArn` | optional | **Leave empty** — the template then creates the secret `git-dashboard/github-token` for you. Only fill this if the secret already exists in your account (pass its ARN). |
   | `GitLabTokenSecretArn` | optional | Same as above for `git-dashboard/gitlab-token` |

6. **Next** → **Next** → check **I acknowledge that AWS CloudFormation might
   create IAM resources with custom names** → **Submit**
7. Wait for **CREATE_COMPLETE** (~3–5 minutes)

> If stack creation fails with "secret already exists", your account already
> has `git-dashboard/github-token` or `git-dashboard/gitlab-token` — pass
> their ARNs in the two secret parameters instead of leaving them empty.

## Step 2: Upload the Lambda Package to S3

1. Open https://s3.console.aws.amazon.com/ and open the bucket you named in
   `BucketName` (e.g. `git-dashboard-metrics-<account-id>-<region>`)
2. **Create folder** named `lambda-code`
3. Open the folder → **Upload** → select `lambda-package.zip` (built in
   Prerequisites) → **Upload**

## Step 3: Update Both Lambda Functions

For **each** of `github-change-detector` and `github-metrics-collector`:

1. Open https://console.aws.amazon.com/lambda/ → click the function
2. **Code** tab → **Upload from** → **Amazon S3 location**
3. S3 URL: `s3://<your-bucket>/lambda-code/lambda-package.zip`
4. **Save**

## Step 4: Set Your Git Tokens

The stack created the secrets with placeholder values. Replace them:

1. Open https://console.aws.amazon.com/secretsmanager/
2. Click `git-dashboard/github-token` → **Retrieve secret value** → **Edit**
   → paste your GitHub PAT → **Save**
3. Repeat for `git-dashboard/gitlab-token` with your GitLab PAT

> You can skip either platform — it will be skipped gracefully at runtime and
> can be enabled later by updating the secret. No redeploy needed.

## Step 5: Test the Deployment

1. Open https://console.aws.amazon.com/states/ → `github-metrics-workflow`
2. **Start execution** → leave input as `{}` → **Start execution**
3. Wait for **Succeeded** (~1–5 minutes depending on repo count)

## Step 6: Verify Results

1. In your S3 bucket check `output/response.json` and `output/response.csv`
   (plus dated snapshots under `output/history/dt=YYYY-MM-DD/`)
2. EventBridge → **Rules** → `github-metrics-collection-schedule` should be
   **Enabled**

> **No files in S3?** If both secrets still hold placeholders the run ends
> with "No changes detected, skipping collection" and writes nothing — set a
> real token (Step 4) and re-run.

## Monitoring & Alerts

CloudWatch alarms (`github-metrics-dlq-messages`,
`github-metrics-workflow-failed`) publish to the SNS topic
`github-metrics-alerts` — subscribe your email in the SNS console to get
notified of failures.

## Troubleshooting

- **Lambda errors**: check CloudWatch Logs for each function; the most common
  issue is an invalid/placeholder Git token (the log states exactly which
  secret to fix)
- **Step Functions failures**: click the failed execution → the failed state
  shows the error; also check the DLQ (`github-metrics-lambda-dlq`)

## Cleanup (Console)

1. **Empty BOTH S3 buckets** first — `<BucketName>` **and**
   `<BucketName>-access-logs` (use "Empty" in the S3 console; versioned
   objects included). Stack deletion fails if either bucket has objects.
2. CloudFormation → select `github-metrics-collection` → **Delete**
3. Secrets Manager → delete `git-dashboard/github-token` and
   `git-dashboard/gitlab-token` if the stack created them and you no longer
   need them; **revoke the tokens** in GitHub/GitLab as well
4. (Alternatively run `infrastructure/cleanup.sh`, which empties both buckets
   automatically.)

---

**✅ Deployment complete!** Metrics are collected automatically on the
configured schedule.
