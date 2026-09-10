import json
import boto3
import os
from datetime import datetime, timedelta, timezone

def another_execution_running():
    """Guard against overlapping runs: returns True if another workflow
    execution is already RUNNING (besides this one). Prevents concurrent
    runs from racing on the shared S3 state when collection takes longer
    than the schedule interval."""
    state_machine_arn = os.environ.get('STATE_MACHINE_ARN', '')
    if not state_machine_arn:
        return False
    try:
        sfn = boto3.client('stepfunctions')
        response = sfn.list_executions(
            stateMachineArn=state_machine_arn,
            statusFilter='RUNNING',
            maxResults=2
        )
        return len(response.get('executions', [])) > 1
    except Exception as e:
        print(f"Could not check running executions ({e}) - continuing")
        return False

def lambda_handler(event, context):
    """Enhanced change detector with full/incremental load support"""
    
    bucket_name = os.environ['BUCKET_NAME']
    chunking_threshold = int(os.environ.get('CHUNKING_THRESHOLD', 20))
    
    try:
        # Skip this run entirely if a previous execution is still in flight
        if another_execution_running():
            print("Another workflow execution is still running - skipping this run")
            return {
                'statusCode': 200,
                'loadType': 'none',
                'hasChanges': False,
                'requiresChunking': False,
                'chunks': [],
                'repositoryCount': 0,
                'message': 'Skipped: previous execution still running'
            }
        
        # Get all configured tokens
        tokens = get_all_tokens()
        
        if not tokens:
            # Graceful no-op: include the fields the Step Functions Choice
            # state expects so the workflow ends at NoChangesDetected
            # instead of failing.
            print("No Git tokens configured yet. Add a token to "
                  "git-dashboard/github-token and/or git-dashboard/gitlab-token "
                  "in Secrets Manager, then the next scheduled run will collect data.")
            return {
                'statusCode': 200,
                'loadType': 'none',
                'hasChanges': False,
                'requiresChunking': False,
                'chunks': [],
                'repositoryCount': 0,
                'message': 'No Git tokens configured - skipping collection'
            }
        
        # Determine load type
        load_type = determine_load_type(bucket_name)
        
        # Get repository count and check for changes across all platforms
        repo_count, has_changes, all_repos = check_repositories(tokens, bucket_name, load_type)
        
        # Determine if chunking is required
        requires_chunking = repo_count >= chunking_threshold
        
        # Create chunks if needed (each chunk carries loadType for the Map state)
        chunks = []
        if requires_chunking:
            save_repo_snapshot(bucket_name, all_repos)
            chunks = create_chunks(repo_count, chunking_threshold)
            for chunk in chunks:
                chunk['loadType'] = load_type
        
        # Note: timestamp will be updated by collector after successful processing
        
        result = {
            'statusCode': 200,
            'loadType': load_type,
            'hasChanges': has_changes,
            'repositoryCount': repo_count,
            'requiresChunking': requires_chunking,
            'chunks': chunks,
            'timestamp': datetime.utcnow().isoformat(),
            'message': f"Load type: {load_type}, Changes: {has_changes}, Repos: {repo_count}"
        }
        
        print(f"Detection result: {json.dumps(result, indent=2)}")
        return result
        
    except Exception as e:
        print(f"Error in change detection: {str(e)}")
        return {
            'statusCode': 500,
            'loadType': 'full',
            'hasChanges': True,
            'requiresChunking': False,
            'error': str(e)
        }

def get_secret_token(secret_name):
    """Retrieve a Git platform token from Secrets Manager.
    Returns None (instead of raising) when the secret is missing, empty, or
    still holds the deployment placeholder, so the solution keeps working
    when only one platform (GitHub or GitLab) is configured."""
    if not secret_name:
        return None
    try:
        client = boto3.client('secretsmanager')
        response = client.get_secret_value(SecretId=secret_name)
        token = (response.get('SecretString') or '').strip()
        if not token or token == 'PLACEHOLDER_UPDATE_ME':  # nosec B105 - deployment sentinel, not a credential
            print(f"Secret '{secret_name}' still holds a placeholder - skipping this platform. "
                  f"Set a real token with: aws secretsmanager update-secret "
                  f"--secret-id {secret_name} --secret-string '<your-token>'")
            return None
        return token
    except Exception as e:
        print(f"Could not retrieve secret '{secret_name}' ({e}) - skipping this platform")
        return None

def get_all_tokens():
    """Retrieve all configured Git tokens based on enabled platforms"""
    tokens = {}
    enabled_platforms = os.environ.get('ENABLED_PLATFORMS', 'github,gitlab').lower().split(',')
    enabled_platforms = [p.strip() for p in enabled_platforms]
    
    github_secret = os.environ.get('GITHUB_TOKEN_SECRET_ARN', '')
    gitlab_secret = os.environ.get('GITLAB_TOKEN_SECRET_ARN', '')
    
    if 'github' in enabled_platforms and github_secret:
        token = get_secret_token(github_secret)
        if token:
            tokens['github'] = token
            print("GitHub platform enabled")
    
    if 'gitlab' in enabled_platforms and gitlab_secret:
        token = get_secret_token(gitlab_secret)
        if token:
            tokens['gitlab'] = token
            print("GitLab platform enabled")
    
    return tokens

def determine_load_type(bucket_name):
    """Determine if this should be a full or incremental load"""
    s3 = boto3.client('s3')
    
    try:
        # Check if we have previous data
        s3.head_object(Bucket=bucket_name, Key='response.json')
        
        # Check last full load time
        try:
            response = s3.get_object(Bucket=bucket_name, Key='load_metadata.json')
            metadata = json.loads(response['Body'].read())
            last_full_load = datetime.fromisoformat(metadata.get('last_full_load', '2000-01-01T00:00:00'))
            
            # Force full load every 24 hours
            if datetime.utcnow() - last_full_load > timedelta(hours=24):
                return 'full'
            else:
                return 'incremental'
        except:
            return 'incremental'
            
    except:
        # First run - full load
        return 'full'

def check_repositories(tokens, bucket_name, load_type):
    """Check repositories and detect changes across all platforms.
    Returns (total_count, has_changes, combined_repo_list)."""
    from git_adapter import get_adapter
    
    total_repo_count = 0
    has_any_changes = False
    all_repos = []
    
    for platform, token in tokens.items():
        adapter = get_adapter(token)
        repos = adapter.get_repositories()
        repo_count = len(repos)
        total_repo_count += repo_count
        for r in repos:
            r['platform'] = platform
        all_repos.extend(repos)
        
        print(f"{platform}: Found {repo_count} repositories")
        
        if load_type == 'full':
            has_any_changes = True
        else:
            # For incremental load, check for changes
            has_changes = detect_incremental_changes_for_platform(adapter, bucket_name, platform)
            if has_changes:
                has_any_changes = True
    
    return total_repo_count, has_any_changes, all_repos

def save_repo_snapshot(bucket_name, repos):
    """Persist the combined repo list so chunk workers share one snapshot
    instead of each re-fetching the entire repository list."""
    s3 = boto3.client('s3')
    s3.put_object(
        Bucket=bucket_name,
        Key='chunks/repos_snapshot.json',
        Body=json.dumps(repos),
        ContentType='application/json'
    )
    print(f"Saved repo snapshot ({len(repos)} repos) for chunk processing")



def detect_incremental_changes_for_platform(adapter, bucket_name, platform):
    """Detect changes for a specific platform during incremental load.
    Checks for: new repos (created_at), modified repos (updated_at), deleted repos (count change)."""
    try:
        last_check = get_last_check_time(bucket_name)
        if not last_check:
            print(f"{platform}: No previous check found, assuming changes")
            return True
        
        if last_check.endswith('Z'):
            last_check = last_check[:-1] + '+00:00'
        last_check_dt = datetime.fromisoformat(last_check)
        if last_check_dt.tzinfo is None:
            last_check_dt = last_check_dt.replace(tzinfo=timezone.utc)
        
        current_time = datetime.utcnow().replace(tzinfo=timezone.utc)
        print(f"{platform}: Checking changes between {last_check_dt} and {current_time}")
        
        repos = adapter.get_repositories()
        
        # Check for repo count changes (new or deleted repos)
        previous_count = get_previous_repo_count(bucket_name, platform)
        current_count = len(repos)
        if previous_count is not None and current_count != previous_count:
            print(f"{platform}: Repo count changed from {previous_count} to {current_count}")
            save_repo_count(bucket_name, platform, current_count)
            return True
        
        # Save current count for future comparisons
        save_repo_count(bucket_name, platform, current_count)
        
        for repo in repos:
            # Check created_at for new repos
            created_at = repo.get('created_at', '')
            if created_at:
                created_dt = datetime.fromisoformat(created_at.replace('Z', '+00:00'))
                if last_check_dt < created_dt <= current_time:
                    print(f"{platform}: New repo detected: {repo['name']} (created {created_at})")
                    return True
            
            # Check updated_at for modified repos
            updated_at = repo.get('updated_at', '')
            if updated_at:
                updated_dt = datetime.fromisoformat(updated_at.replace('Z', '+00:00'))
                if last_check_dt < updated_dt <= current_time:
                    print(f"{platform}: Change detected in {repo['name']} (updated {updated_at})")
                    return True
        
        print(f"{platform}: No changes detected")
        return False
    except Exception as e:
        print(f"{platform}: Error detecting changes: {e}")
        return True


def get_last_check_time(bucket_name):
    """Get the last check timestamp from S3"""
    s3 = boto3.client('s3')
    try:
        response = s3.get_object(Bucket=bucket_name, Key='last_check.json')
        data = json.loads(response['Body'].read())
        return data.get('timestamp')
    except:
        return None

def get_previous_repo_count(bucket_name, platform):
    """Get the previously stored repo count for a platform"""
    s3 = boto3.client('s3')
    try:
        response = s3.get_object(Bucket=bucket_name, Key=f'repo_count_{platform}.json')
        data = json.loads(response['Body'].read())
        return data.get('count')
    except:
        return None

def save_repo_count(bucket_name, platform, count):
    """Save current repo count for future comparison"""
    s3 = boto3.client('s3')
    s3.put_object(
        Bucket=bucket_name,
        Key=f'repo_count_{platform}.json',
        Body=json.dumps({'count': count, 'timestamp': datetime.utcnow().isoformat()}),
        ContentType='application/json'
    )

def update_last_check_time(bucket_name, load_type):
    """Update the last check timestamp in S3"""
    s3 = boto3.client('s3')
    current_time = datetime.utcnow().isoformat()
    
    # Update last check time
    timestamp_data = {
        'timestamp': current_time,
        'load_type': load_type,
        'updated_by': 'change-detector'
    }
    s3.put_object(
        Bucket=bucket_name,
        Key='last_check.json',
        Body=json.dumps(timestamp_data),
        ContentType='application/json'
    )
    
    # Update load metadata
    try:
        response = s3.get_object(Bucket=bucket_name, Key='load_metadata.json')
        metadata = json.loads(response['Body'].read())
    except:
        metadata = {}
    
    metadata['last_check'] = current_time
    if load_type == 'full':
        metadata['last_full_load'] = current_time
    
    s3.put_object(
        Bucket=bucket_name,
        Key='load_metadata.json',
        Body=json.dumps(metadata),
        ContentType='application/json'
    )



def create_chunks(repo_count, chunking_threshold):
    """Create chunks for parallel processing"""
    if repo_count < chunking_threshold:
        return []
    
    # Calculate optimal chunk size
    if repo_count <= 100:
        chunk_size = 25
    elif repo_count <= 500:
        chunk_size = 50
    else:
        chunk_size = 100
    
    chunks = []
    total_chunks = (repo_count + chunk_size - 1) // chunk_size
    
    for i in range(total_chunks):
        start_index = i * chunk_size
        end_index = min(start_index + chunk_size, repo_count)
        
        chunks.append({
            'chunk_id': i + 1,
            'start_index': start_index,
            'end_index': end_index,
            'chunk_size': end_index - start_index
        })
    
    return chunks
