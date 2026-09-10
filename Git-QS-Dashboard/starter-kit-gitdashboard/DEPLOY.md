# Quick Deployment Guide

This solution supports **GitHub and GitLab** and can be deployed in **any AWS region**
(default: us-east-1; override with `--region`).

## 📋 Prerequisites

- **AWS CLI** configured with permissions to deploy CloudFormation, Lambda,
  Step Functions, S3, EventBridge, IAM, KMS, SQS, and Secrets Manager
- **GitHub Personal Access Token (PAT)** — required if enabling GitHub.
  Create at GitHub → Settings → Developer settings → Personal access tokens.
  Scope needed: `repo` (read) for classic PATs, or Repository read access for
  fine-grained PATs. Format: `ghp_...` or `github_pat_...`
- **GitLab Personal Access Token (PAT)** — required if enabling GitLab.
  Create at GitLab → User settings → Access tokens.
  Scope needed: `read_api`. Format: `glpat-...`

You only need the token(s) for the platform(s) you enable — a missing token
does not break the solution, that platform is simply skipped. Have the
token(s) ready before deploying: deploy.sh will prompt for them (see
[Git Token Setup](#-git-token-setup)).

## Deploy for GitHub Only

```bash
cd infrastructure
./deploy.sh --platform github
```

## Deploy for GitLab Only

```bash
cd infrastructure
./deploy.sh --platform gitlab
```

## Deploy for Both Platforms

```bash
cd infrastructure
./deploy.sh --platform both
```

## Additional Options

### Custom Region
```bash
./deploy.sh --platform github --region us-west-2
```

### Custom Schedule
```bash
./deploy.sh --platform github --schedule "rate(30 minutes)"
```

### Self-Managed GitLab Instance
By default the solution talks to `https://gitlab.com`. If your organization
runs its own GitLab, point the solution at it:
```bash
./deploy.sh --platform gitlab --gitlab-url https://gitlab.example.com
```
The URL is passed to the Lambdas as the `GITLAB_BASE_URL` environment
variable, so you can also change it later without redeploying the stack:
```bash
aws lambda update-function-configuration --function-name github-metrics-collector \
  --environment 'Variables={GITLAB_BASE_URL=https://gitlab.example.com,...}' --region <region>
```
> **Note**: The Lambdas must be able to reach your GitLab instance over the
> internet with PAT authentication. Instances behind corporate SSO/VPN (that
> intercept API calls before GitLab sees the PAT) are not reachable from
> Lambda without additional network setup (e.g., VPC attachment with routes
> to your network).

## 🔑 Git Token Setup

The pipeline needs a token for each platform you enable. Tokens are stored in
AWS Secrets Manager under these secret names (keys):

| Platform | Secret name (key)            | Token format              |
|----------|------------------------------|---------------------------|
| GitHub   | `git-dashboard/github-token` | `ghp_...` or `github_pat_...` |
| GitLab   | `git-dashboard/gitlab-token` | `glpat-...`               |

### Option A: Provide tokens during deployment (recommended)

When you run `./deploy.sh` in an interactive terminal, it prompts you for each
enabled platform's token and stores it in Secrets Manager automatically:

```
Enter your GitHub token now (format: ghp_... or github_pat_...) or press Enter to skip:
Enter your GitLab token now (format: glpat-...) or press Enter to skip:
```

You can press Enter to skip either prompt — the skipped platform is simply
ignored at runtime (it does not break the solution) until you add its token.

### Option B: Add tokens manually after deployment

If you skipped the prompt (or deploy non-interactively), add the token to
Secrets Manager yourself. **Use the same region you deployed to.**

```bash
# GitHub
aws secretsmanager update-secret \
  --secret-id git-dashboard/github-token \
  --secret-string 'ghp_your_token_here' \
  --region <your-deploy-region>

# GitLab
aws secretsmanager update-secret \
  --secret-id git-dashboard/gitlab-token \
  --secret-string 'glpat-your_token_here' \
  --region <your-deploy-region>
```

Or via the AWS Console: **Secrets Manager → select the secret
(`git-dashboard/github-token` or `git-dashboard/gitlab-token`) → Retrieve
secret value → Edit → paste your token → Save.**

No redeploy is needed — the next scheduled run (every 10 minutes by default)
picks up the new token automatically.

> **Notes**
> - Secrets left on the `PLACEHOLDER_UPDATE_ME` value are skipped gracefully;
>   the Lambda logs print the exact command to fix them.
> - `deploy.sh` prompts for tokens interactively during deployment; you can
>   also add them any time with `aws secretsmanager update-secret` (above).
> - Grant tokens read-only scopes and rotate them regularly.

## Test the Deployment

```bash
# Start a manual execution (use your deploy region)
aws stepfunctions start-execution \
  --state-machine-arn arn:aws:states:<region>:<account-id>:stateMachine:github-metrics-workflow \
  --region <region>

# Monitor logs
aws logs tail /aws/lambda/github-change-detector --follow --region <region>
```

## Environment Variables (Alternative)

You can also set environment variables before running deploy.sh:

```bash
export ENABLED_PLATFORMS="github"
export REGION="us-east-1"
export SCHEDULE_EXPRESSION="rate(15 minutes)"
./deploy.sh
```

## 🧹 Cleanup

To remove all deployed resources and stop incurring charges:

```bash
cd infrastructure
./cleanup.sh
```

This permanently deletes the CloudFormation stack, Lambda functions, Step
Functions workflow, EventBridge rule, and S3 buckets (including collected
data). Also cancel any Amazon QuickSight subscription created for this
project and delete/rotate the Git tokens stored in Secrets Manager.

> **Note**: This is non-production sample code provided "as-is" without
> warranty. See the [Disclaimers](../README.md#️-disclaimers) and
> [Security Considerations](../README.md#-security-considerations--hardening)
> sections before use.
