#!/bin/bash
# Builds lambda-package.zip for MANUAL (console) deployments.
# Script deployments don't need this - deploy.sh packages automatically.
#
# Usage: ./build-lambda-package.sh [output-path]
# Output: lambda-package.zip (default: repo starter-kit root)

set -e
cd "$(dirname "$0")"

OUTPUT="${1:-../lambda-package.zip}"
TEMP_DIR=$(mktemp -d)
trap 'rm -rf "$TEMP_DIR"' EXIT

PIP_CMD="pip3"
command -v pip3 >/dev/null || PIP_CMD="pip"

echo "📦 Building Lambda deployment package..."

# Lambda source files
cp ../lambda/detector.py ../lambda/collector.py ../lambda/git_adapter.py "$TEMP_DIR/"

# Pinned dependencies (must match ../lambda/requirements.txt)
$PIP_CMD install -r ../lambda/requirements.txt -t "$TEMP_DIR" --quiet

# Package
( cd "$TEMP_DIR" && zip -qr9 package.zip . -x '*.pyc' -x '__pycache__/*' )
mv "$TEMP_DIR/package.zip" "$OUTPUT"

echo "✓ Created $(cd "$(dirname "$OUTPUT")" && pwd)/$(basename "$OUTPUT") ($(du -h "$OUTPUT" | cut -f1))"
echo ""
echo "Next (console deployment):"
echo "  1. Upload it to s3://<your-bucket>/lambda-code/lambda-package.zip"
echo "  2. Point both Lambda functions at that S3 object (see docs/deployment-guide-console.md)"
