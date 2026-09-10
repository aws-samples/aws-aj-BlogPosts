#!/bin/bash

# GitHub Metrics Collection - Enhanced Deployment Script
set -e

# Change to script directory
cd "$(dirname "$0")"

# Colors for output
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
BLUE='\033[0;34m'
NC='\033[0m' # No Color

# Configuration
STACK_NAME="${STACK_NAME:-github-metrics-collection}"
REGION="${REGION:-us-east-1}"
BUCKET_PREFIX="git-dashboard-metrics"
SCHEDULE_EXPRESSION="${SCHEDULE_EXPRESSION:-rate(10 minutes)}"
CHUNKING_THRESHOLD="${CHUNKING_THRESHOLD:-20}"
ENABLED_PLATFORMS="${ENABLED_PLATFORMS:-github,gitlab}"
GITLAB_BASE_URL="${GITLAB_BASE_URL:-https://gitlab.com}"

# Parse command line arguments
show_usage() {
    echo "Usage: $0 [OPTIONS]"
    echo ""
    echo "Options:"
    echo "  --platform <github|gitlab|both>  Specify which platform(s) to enable (default: both)"
    echo "  --region <region>                AWS region (default: us-east-1)"
    echo "  --schedule <expression>          EventBridge schedule (default: rate(10 minutes))"
    echo "  --gitlab-url <url>               GitLab instance base URL (default: https://gitlab.com)"
    echo "  --help                           Show this help message"
    echo ""
    echo "Examples:"
    echo "  $0 --platform github                    # Deploy for GitHub only"
    echo "  $0 --platform gitlab                    # Deploy for GitLab only"
    echo "  $0 --platform both                      # Deploy for both platforms"
    echo "  $0 --platform github --region us-west-2 # Deploy GitHub in us-west-2"
    exit 0
}

while [[ $# -gt 0 ]]; do
    case $1 in
        --platform)
            case $2 in
                github)
                    ENABLED_PLATFORMS="github"
                    ;;
                gitlab)
                    ENABLED_PLATFORMS="gitlab"
                    ;;
                both)
                    ENABLED_PLATFORMS="github,gitlab"
                    ;;
                *)
                    log_error "Invalid platform: $2. Use 'github', 'gitlab', or 'both'"
                    exit 1
                    ;;
            esac
            shift 2
            ;;
        --region)
            REGION="$2"
            shift 2
            ;;
        --schedule)
            SCHEDULE_EXPRESSION="$2"
            shift 2
            ;;
        --gitlab-url)
            GITLAB_BASE_URL="$2"
            shift 2
            ;;
        --help)
            show_usage
            ;;
        *)
            log_error "Unknown option: $1"
            show_usage
            ;;
    esac
done

# Functions
log_info() { echo -e "${GREEN}[INFO]${NC} $1"; }
log_warn() { echo -e "${YELLOW}[WARN]${NC} $1"; }
log_error() { echo -e "${RED}[ERROR]${NC} $1"; }
log_debug() { echo -e "${BLUE}[DEBUG]${NC} $1"; }

check_prerequisites() {
    log_info "Checking prerequisites..."
    
    # Check AWS CLI
    if ! command -v aws &> /dev/null; then
        log_error "AWS CLI not found. Please install AWS CLI."
        exit 1
    fi
    
    # Check Python
    if ! command -v python3 &> /dev/null; then
        log_error "Python 3 not found. Please install Python 3."
        exit 1
    fi
    
    # Check pip
    if ! command -v pip &> /dev/null && ! command -v pip3 &> /dev/null; then
        log_error "pip not found. Please install pip."
        exit 1
    fi
    
    # Use pip3 if available, otherwise pip
    PIP_CMD="pip3"
    if ! command -v pip3 &> /dev/null; then
        PIP_CMD="pip"
    fi
    
    # Check AWS credentials
    if ! aws sts get-caller-identity &> /dev/null; then
        log_error "AWS credentials not configured. Run 'aws configure'."
        exit 1
    fi
    
    # Check required files
    for file in "template.yaml" "../lambda/detector.py" "../lambda/collector.py" "../lambda/requirements.txt"; do
        if [[ ! -f "$file" ]]; then
            log_error "Required file missing: $file"
            exit 1
        fi
    done
    
    log_info "Prerequisites check passed ✓"
}

setup_secrets() {
    log_info "🔐 Setting up secrets..."
    
    # Create GitHub secret if enabled and doesn't exist
    if [[ "$ENABLED_PLATFORMS" == *"github"* ]]; then
        if ! aws secretsmanager describe-secret --secret-id git-dashboard/github-token --region "$REGION" &>/dev/null; then
            log_info "Creating placeholder GitHub secret..."
            aws secretsmanager create-secret \
                --name git-dashboard/github-token \
                --description "GitHub Personal Access Token" \
                --secret-string "PLACEHOLDER_UPDATE_ME" \
                --region "$REGION" \
                --tags Key=Project,Value=github-grafana &>/dev/null
        fi
        prompt_for_token_if_placeholder "git-dashboard/github-token" "GitHub" "ghp_... or github_pat_..."
        GITHUB_TOKEN_SECRET_ARN=$(aws secretsmanager describe-secret --secret-id git-dashboard/github-token --region "$REGION" --query 'ARN' --output text)
        log_info "GitHub secret ARN: $GITHUB_TOKEN_SECRET_ARN"
    fi
    
    # Create GitLab secret if enabled and doesn't exist
    if [[ "$ENABLED_PLATFORMS" == *"gitlab"* ]]; then
        if ! aws secretsmanager describe-secret --secret-id git-dashboard/gitlab-token --region "$REGION" &>/dev/null; then
            log_info "Creating placeholder GitLab secret..."
            aws secretsmanager create-secret \
                --name git-dashboard/gitlab-token \
                --description "GitLab Personal Access Token" \
                --secret-string "PLACEHOLDER_UPDATE_ME" \
                --region "$REGION" \
                --tags Key=Project,Value=github-grafana &>/dev/null
        fi
        prompt_for_token_if_placeholder "git-dashboard/gitlab-token" "GitLab" "glpat-..."
        GITLAB_TOKEN_SECRET_ARN=$(aws secretsmanager describe-secret --secret-id git-dashboard/gitlab-token --region "$REGION" --query 'ARN' --output text)
        log_info "GitLab secret ARN: $GITLAB_TOKEN_SECRET_ARN"
    fi
}

# If a secret still holds the placeholder, prompt the user for the real token
# (interactive terminals only). Tokens are optional: any platform left on the
# placeholder is skipped gracefully at runtime and can be enabled later.
prompt_for_token_if_placeholder() {
    local secret_id=$1
    local platform=$2
    local example=$3
    local current
    current=$(aws secretsmanager get-secret-value --secret-id "$secret_id" --region "$REGION" --query 'SecretString' --output text 2>/dev/null || echo "")
    
    if [[ -z "$current" || "$current" == "PLACEHOLDER_UPDATE_ME" ]]; then
        if [[ -t 0 ]]; then
            local token=""
            read -r -s -p "Enter your $platform token now (format: $example) or press Enter to skip: " token
            echo ""
            if [[ -n "$token" ]]; then
                aws secretsmanager update-secret \
                    --secret-id "$secret_id" \
                    --secret-string "$token" \
                    --region "$REGION" &>/dev/null
                log_info "✓ $platform token stored in Secrets Manager ($secret_id)"
                return
            fi
        fi
        log_warn "⚠️  No $platform token set — the $platform platform will be SKIPPED until you run:"
        log_warn "    aws secretsmanager update-secret --secret-id $secret_id --secret-string '<$example>' --region $REGION"
    fi
}

cleanup_on_error() {
    log_warn "Cleaning up temporary files..."
    rm -f lambda-package.zip
    [[ -n "$TEMP_DIR" ]] && rm -rf "$TEMP_DIR"
}

package_lambda_code() {
    log_info "📦 Creating Lambda deployment package..."
    
    # Create temporary directory for clean packaging
    TEMP_DIR=$(mktemp -d)
    log_debug "Using temporary directory: $TEMP_DIR"
    
    # Copy Lambda source files
    cp ../lambda/detector.py "$TEMP_DIR/"
    cp ../lambda/collector.py "$TEMP_DIR/"
    cp ../lambda/git_adapter.py "$TEMP_DIR/"
    cp ../lambda/requirements.txt "$TEMP_DIR/"
    
    cd "$TEMP_DIR"
    
    # Install dependencies with isolated environment to avoid conflicts
    log_info "Installing Python dependencies..."
    
    # Create a clean requirements installation
    $PIP_CMD install --upgrade pip --quiet 2>/dev/null || true
    
    # Install packages with --no-deps first, then install essential dependencies
    $PIP_CMD install -r requirements.txt -t . --no-deps --quiet 2>/dev/null || true
    
    # Install core AWS and HTTP libraries with minimal dependencies
    # (versions must match ../lambda/requirements.txt)
    $PIP_CMD install boto3==1.35.67 botocore==1.35.67 -t . --quiet 2>/dev/null || true
    $PIP_CMD install requests==2.33.0 urllib3==2.7.0 certifi==2025.6.15 -t . --quiet 2>/dev/null || true
    $PIP_CMD install python-dateutil==2.9.0 jmespath==1.0.1 six==1.16.0 -t . --quiet 2>/dev/null || true
    
    # Remove unnecessary files to reduce package size
    log_debug "Cleaning up unnecessary files..."
    find . -name "*.pyc" -delete
    find . -name "__pycache__" -type d -exec rm -rf {} + 2>/dev/null || true
    find . -name "*.dist-info" -type d -exec rm -rf {} + 2>/dev/null || true
    find . -name "*.egg-info" -type d -exec rm -rf {} + 2>/dev/null || true
    find . -name "tests" -type d -exec rm -rf {} + 2>/dev/null || true
    find . -name "test" -type d -exec rm -rf {} + 2>/dev/null || true
    
    # Test imports before packaging
    log_info "Testing module imports..."
    python3 -c "import detector; print('✓ detector module OK')" || {
        log_error "detector.py import test failed"
        exit 1
    }
    
    python3 -c "import collector; print('✓ collector module OK')" || {
        log_error "collector.py import test failed"
        exit 1
    }
    
    # Create deployment package
    log_info "Creating deployment package..."
    zip -r lambda-package.zip . -x "*.pyc" "__pycache__/*" > /dev/null
    
    # Move package back to original directory
    mv lambda-package.zip "$OLDPWD/"
    cd "$OLDPWD"
    
    # Show package info
    PACKAGE_SIZE=$(du -h lambda-package.zip | cut -f1)
    log_info "✓ Lambda package created (size: $PACKAGE_SIZE)"
    
    # Clean up temp directory
    rm -rf "$TEMP_DIR"
    unset TEMP_DIR
}

deploy_infrastructure() {
    log_info "☁️ Deploying CloudFormation infrastructure..."
    
    # Build parameter overrides as an array (no eval → no shell injection,
    # and values with spaces like "rate(10 minutes)" are passed safely)
    PARAMS=(
        "BucketName=$BUCKET_NAME"
        "ChunkingThreshold=$CHUNKING_THRESHOLD"
        "ScheduleExpression=$SCHEDULE_EXPRESSION"
        "EnabledPlatforms=$ENABLED_PLATFORMS"
        "GitLabBaseUrl=$GITLAB_BASE_URL"
    )

    # Add token ARNs only if set
    if [ -n "$GITHUB_TOKEN_SECRET_ARN" ]; then
        PARAMS+=("GitHubTokenSecretArn=$GITHUB_TOKEN_SECRET_ARN")
    fi
    if [ -n "$GITLAB_TOKEN_SECRET_ARN" ]; then
        PARAMS+=("GitLabTokenSecretArn=$GITLAB_TOKEN_SECRET_ARN")
    fi

    log_debug "Parameters: ${PARAMS[*]}"

    aws cloudformation deploy \
        --template-file template.yaml \
        --stack-name "$STACK_NAME" \
        --parameter-overrides "${PARAMS[@]}" \
        --capabilities CAPABILITY_IAM CAPABILITY_NAMED_IAM \
        --region "$REGION" \
        --no-fail-on-empty-changeset
    
    # Wait for completion
    log_info "⏳ Waiting for stack deployment to complete..."
    aws cloudformation wait stack-create-complete \
        --stack-name "$STACK_NAME" \
        --region "$REGION" 2>/dev/null || \
    aws cloudformation wait stack-update-complete \
        --stack-name "$STACK_NAME" \
        --region "$REGION"
    
    log_info "✓ Infrastructure deployed successfully"
}

update_lambda_functions() {
    log_info "⬆️ Uploading Lambda package to S3..."
    aws s3 cp lambda-package.zip "s3://$BUCKET_NAME/lambda-code/lambda-package.zip" --region "$REGION"
    
    log_info "🔄 Updating Lambda functions..."
    
    # Wait for S3 upload to propagate
    sleep 5
    
    # Function to update Lambda with comprehensive error handling
    update_lambda_function() {
        local function_name=$1
        local max_attempts=5
        local attempt=1
        
        while [ $attempt -le $max_attempts ]; do
            log_info "Updating $function_name (attempt $attempt/$max_attempts)..."
            
            if aws lambda update-function-code \
                --function-name "$function_name" \
                --s3-bucket "$BUCKET_NAME" \
                --s3-key lambda-code/lambda-package.zip \
                --region "$REGION" \
                --output table > /dev/null 2>&1; then
                
                # Wait for function to be updated
                log_debug "Waiting for $function_name to be ready..."
                aws lambda wait function-updated \
                    --function-name "$function_name" \
                    --region "$REGION" 2>/dev/null || true
                
                log_info "✓ $function_name updated successfully"
                return 0
            else
                log_warn "Failed to update $function_name (attempt $attempt)"
                if [ $attempt -lt $max_attempts ]; then
                    sleep $((attempt * 5))  # Exponential backoff
                fi
            fi
            
            ((attempt++))
        done
        
        log_error "Failed to update $function_name after $max_attempts attempts"
        return 1
    }
    
    # Update both functions
    update_lambda_function "github-change-detector"
    update_lambda_function "github-metrics-collector"
    
    log_info "✓ Lambda functions updated successfully"
}

test_deployment() {
    log_info "🧪 Testing deployment..."
    
    # Test Lambda function configuration
    for func in "github-change-detector" "github-metrics-collector"; do
        if aws lambda get-function --function-name "$func" --region "$REGION" > /dev/null 2>&1; then
            log_info "✓ $func is accessible"
        else
            log_warn "⚠ $func may not be properly configured"
        fi
    done
    
    # Test Step Functions state machine
    if aws stepfunctions describe-state-machine \
        --state-machine-arn "arn:aws:states:$REGION:$ACCOUNT_ID:stateMachine:github-metrics-workflow" \
        --region "$REGION" > /dev/null 2>&1; then
        log_info "✓ Step Functions workflow is accessible"
    else
        log_warn "⚠ Step Functions workflow may not be properly configured"
    fi
    
    # Test EventBridge rule
    if aws events describe-rule \
        --name "github-metrics-collection-schedule" \
        --region "$REGION" > /dev/null 2>&1; then
        log_info "✓ EventBridge schedule rule is configured"
    else
        log_warn "⚠ EventBridge rule may not be properly configured"
    fi
}

main() {
    log_info "🚀 Starting GitHub Metrics Collection Deployment..."
    
    check_prerequisites
    
    # Get AWS Account ID
    ACCOUNT_ID=$(aws sts get-caller-identity --query Account --output text --region "$REGION")
    BUCKET_NAME="$BUCKET_PREFIX-$ACCOUNT_ID-$REGION"
    
    # Setup secrets
    setup_secrets
    
    log_info "📋 Deployment Configuration:"
    echo "   Stack Name: $STACK_NAME"
    echo "   Region: $REGION"
    echo "   Bucket: $BUCKET_NAME"
    echo "   Schedule: $SCHEDULE_EXPRESSION"
    echo "   Chunking Threshold: $CHUNKING_THRESHOLD"
    echo "   Enabled Platforms: $ENABLED_PLATFORMS"
    echo ""
    
    # Package Lambda code
    package_lambda_code
    
    # Deploy infrastructure
    deploy_infrastructure
    
    # Update Lambda functions
    update_lambda_functions
    
    # Test deployment
    test_deployment
    
    # Clean up
    rm -f lambda-package.zip
    
    log_info "✅ Deployment completed successfully!"
    echo ""
    log_info "🔑 Next Steps:"
    
    if [[ "$ENABLED_PLATFORMS" == *"github"* ]]; then
        echo "1. Set your GitHub token:"
        echo "   aws secretsmanager update-secret --secret-id git-dashboard/github-token --secret-string 'ghp_your_token_here' --region $REGION"
        echo ""
    fi
    
    if [[ "$ENABLED_PLATFORMS" == *"gitlab"* ]]; then
        echo "2. Set your GitLab token:"
        echo "   aws secretsmanager update-secret --secret-id git-dashboard/gitlab-token --secret-string 'glpat-your_token_here' --region $REGION"
        echo ""
    fi
    
    echo "3. Test the workflow:"
    echo "   aws stepfunctions start-execution --state-machine-arn arn:aws:states:$REGION:$ACCOUNT_ID:stateMachine:github-metrics-workflow --region $REGION"
    echo ""
    echo "4. Monitor execution:"
    echo "   aws logs tail /aws/lambda/github-change-detector --follow --region $REGION"
    echo ""
    echo "5. Check EventBridge schedule:"
    echo "   aws events describe-rule --name github-metrics-collection-schedule --region $REGION"
}

main "$@"
