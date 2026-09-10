import json
import boto3
import os
import csv
import io
from datetime import datetime
from git_adapter import get_adapter

def lambda_handler(event, context):
    """Enhanced metrics collector with chunking support"""
    
    bucket_name = os.environ['BUCKET_NAME']
    
    try:
        action = event.get('action', 'collect_all')
        
        if action == 'collect_all':
            return collect_all_metrics(event, bucket_name)
        elif action == 'process_chunk':
            return process_chunk(event, bucket_name)
        elif action == 'aggregate_results':
            return aggregate_chunk_results(event, bucket_name)
        else:
            return {'statusCode': 400, 'error': f'Unknown action: {action}'}
            
    except Exception as e:
        print(f"Error in collector: {str(e)}")
        return {'statusCode': 500, 'error': str(e)}

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

def load_previous_metrics(bucket_name):
    """Load the previous aggregated metrics document (None on first run)."""
    s3 = boto3.client('s3')
    try:
        response = s3.get_object(Bucket=bucket_name, Key='output/response.json')
        return json.loads(response['Body'].read())
    except Exception:
        return None

def merge_incremental_totals(all_repos, previous):
    """On incremental loads only commit counts are deltas (fetched with
    `since=`); other metrics are full totals. Merge the commit deltas into
    the previous running totals so the output document always represents
    lifetime totals, and report what changed in incrementalChanges."""
    changes = {'commits_added': 0, 'tags_added': 0, 'prs_added': 0,
               'issues_added': 0, 'repos_added': 0}
    prev_repos = {}
    if previous:
        prev_repos = {r.get('name'): r for r in previous.get('repositories', [])}
    
    for repo in all_repos:
        delta = repo.get('commits', 0)
        prev_total = prev_repos.get(repo.get('name'), {}).get('commits', 0)
        changes['commits_added'] += delta
        repo['commits'] = prev_total + delta
        if repo.get('name') not in prev_repos:
            changes['repos_added'] += 1
    
    if previous:
        changes['prs_added'] = max(0, sum(r.get('pullRequests', 0) for r in all_repos) - previous.get('pullRequest', 0))
        changes['issues_added'] = max(0, sum(r.get('issues', 0) for r in all_repos) - previous.get('issues', 0))
        changes['tags_added'] = max(0, sum(r.get('tags', 0) for r in all_repos) - previous.get('tag', 0))
    return changes

def build_final_output(all_repos, load_type, incremental_changes=None):
    """Build the output document (single schema for all load paths)."""
    return {
        'commit': sum(r.get('commits', 0) for r in all_repos),
        'tag': sum(r.get('tags', 0) for r in all_repos),
        'pullRequest': sum(r.get('pullRequests', 0) for r in all_repos),
        'repositoryCount': len(all_repos),
        'issues': sum(r.get('issues', 0) for r in all_repos),
        'lastUpdated': datetime.utcnow().isoformat(),
        'loadType': load_type,
        'incrementalChanges': incremental_changes or {
            'commits_added': 0, 'tags_added': 0, 'prs_added': 0,
            'issues_added': 0, 'repos_added': 0
        },
        'repositories': all_repos
    }

def collect_all_metrics(event, bucket_name):
    """Collect metrics for all repositories (non-chunked)"""
    tokens = get_all_tokens()
    load_type = event.get('loadType', 'full')
    
    print(f"Collecting metrics - Load type: {load_type}")
    
    all_repos = []
    
    # Collect metrics from all platforms
    for platform, token in tokens.items():
        adapter = get_adapter(token)
        metrics = collect_git_metrics(adapter, load_type, bucket_name, platform)
        all_repos.extend(metrics)
    
    # On incremental loads, merge commit deltas into previous totals so the
    # output always holds lifetime totals (never raw deltas)
    incremental_changes = None
    if load_type == 'incremental':
        incremental_changes = merge_incremental_totals(all_repos, load_previous_metrics(bucket_name))
    
    final_output = build_final_output(all_repos, load_type, incremental_changes)
    
    # Store metrics
    store_metrics(bucket_name, final_output)
    
    # Update last check timestamp after successful processing
    update_last_check_timestamp(bucket_name, load_type)
    
    return {
        'statusCode': 200,
        'body': json.dumps({'total_repos': len(all_repos)}),
        'message': f'Metrics collected successfully - {load_type} load'
    }

def load_repo_snapshot(bucket_name):
    """Load the combined repo list snapshot written by the detector.
    Returns None if absent (fallback: chunk fetches the list itself)."""
    s3 = boto3.client('s3')
    try:
        response = s3.get_object(Bucket=bucket_name, Key='chunks/repos_snapshot.json')
        return json.loads(response['Body'].read())
    except Exception:
        return None

def process_chunk(event, bucket_name):
    """Process a chunk of repositories from the shared snapshot.
    Handles ALL configured platforms (GitHub and GitLab) and produces the
    same per-repository detail as the non-chunked path."""
    tokens = get_all_tokens()
    if not tokens:
        return {'statusCode': 400, 'error': 'No tokens configured'}
    
    chunk = event.get('chunk', {})
    load_type = event.get('loadType') or chunk.get('loadType', 'full')
    chunk_id = chunk.get('chunk_id', 1)
    start_index = chunk.get('start_index', 0)
    end_index = chunk.get('end_index', 100)
    
    # One adapter per configured platform
    adapters = {platform: get_adapter(token) for platform, token in tokens.items()}
    
    # Use the snapshot the detector saved (one repo-list fetch per run instead
    # of one per chunk); fall back to fetching if it's missing
    repos = load_repo_snapshot(bucket_name)
    if repos is None:
        repos = []
        for platform, adapter in adapters.items():
            for r in adapter.get_repositories():
                r['platform'] = platform
                repos.append(r)
    
    chunk_repos = repos[start_index:end_index]
    print(f"Processing chunk {chunk_id}: repos {start_index}-{end_index} ({len(chunk_repos)} repos)")
    
    detailed = []
    for repo in chunk_repos:
        platform = repo.get('platform', 'github')
        adapter = adapters.get(platform)
        if not adapter:
            print(f"No adapter/token for platform '{platform}', skipping {repo.get('name')}")
            continue
        
        repo_data = {
            'platform': platform,
            'name': repo.get('name'),
            'url': repo.get('url', ''),
            'description': repo.get('description', ''),
            'language': repo.get('language', ''),
            'stars': repo.get('stars', 0),
            'forks': repo.get('forks', 0),
            'created_at': repo.get('created_at', ''),
            'updated_at': repo.get('updated_at', ''),
            'private': repo.get('private', False)
        }
        repo_metrics = collect_repo_metrics_adapter(adapter, repo, load_type, bucket_name)
        repo_data.update({
            'commits': repo_metrics.get('commit', 0),
            'pullRequests': repo_metrics.get('pullRequest', 0),
            'issues': repo_metrics.get('issues', 0),
            'tags': repo_metrics.get('tag', 0),
            'contributors': repo_metrics.get('contributors', 0)
        })
        detailed.append(repo_data)
    
    # Persist details to S3 (keeps Step Functions payloads small)
    store_chunk_results(bucket_name, chunk_id, {'repositories': detailed})
    
    return {
        'statusCode': 200,
        'chunk_id': chunk_id,
        'loadType': load_type,
        'repository_count': len(detailed),
        'message': f'Chunk {chunk_id} processed successfully'
    }

def aggregate_chunk_results(event, bucket_name):
    """Aggregate results from all chunks into the SAME output schema as the
    non-chunked path (summary totals + per-repository details)."""
    chunk_results = event.get('chunkResults', [])
    print(f"Aggregating {len(chunk_results)} chunk results")
    
    load_type = 'full'
    for cr in chunk_results:
        if isinstance(cr, dict) and cr.get('loadType'):
            load_type = cr['loadType']
            break
    
    # Repo details were persisted to S3 by each chunk
    s3 = boto3.client('s3')
    all_repos = []
    response = s3.list_objects_v2(Bucket=bucket_name, Prefix='chunks/chunk_')
    for obj in response.get('Contents', []):
        data = json.loads(s3.get_object(Bucket=bucket_name, Key=obj['Key'])['Body'].read())
        all_repos.extend(data.get('repositories', []))
    
    incremental_changes = None
    if load_type == 'incremental':
        incremental_changes = merge_incremental_totals(all_repos, load_previous_metrics(bucket_name))
    
    final_output = build_final_output(all_repos, load_type, incremental_changes)
    
    store_metrics(bucket_name, final_output)
    cleanup_chunk_files(bucket_name)
    update_last_check_timestamp(bucket_name, load_type)
    
    return {
        'statusCode': 200,
        'body': json.dumps({'total_repos': len(all_repos)}),
        'message': f'Chunk results aggregated successfully - {load_type} load'
    }

def collect_git_metrics(adapter, load_type, bucket_name, platform='unknown'):
    """Collect comprehensive Git metrics with detailed data"""
    
    # Initialize detailed metrics structure
    metrics = []
    
    # Get repositories
    repos = adapter.get_repositories()
    
    print(f"Processing {len(repos)} repositories from {platform}")
    
    # Process repositories with detailed data collection
    for i, repo in enumerate(repos):
        if i % 10 == 0:
            print(f"Processed {i}/{len(repos)} repositories")
        
        repo_data = {
            'platform': platform,
            'name': repo['name'],
            'url': repo.get('url', ''),
            'description': repo.get('description', ''),
            'language': repo.get('language', ''),
            'stars': repo.get('stars', 0),
            'forks': repo.get('forks', 0),
            'created_at': repo.get('created_at', ''),
            'updated_at': repo.get('updated_at', ''),
            'private': repo.get('private', False)
        }
        
        repo_metrics = collect_repo_metrics_adapter(adapter, repo, load_type, bucket_name)
        
        repo_data.update({
            'commits': repo_metrics.get('commit', 0),
            'pullRequests': repo_metrics.get('pullRequest', 0),
            'issues': repo_metrics.get('issues', 0),
            'tags': repo_metrics.get('tag', 0),
            'contributors': repo_metrics.get('contributors', 0)
        })
        
        metrics.append(repo_data)
    
    return metrics



def collect_metrics_for_repos_adapter(adapter, repos, load_type, bucket_name):
    """Collect metrics for a specific set of repositories using adapter"""
    metrics = {
        'repositories': len(repos),
        'commit': 0,
        'pullRequest': 0,
        'issues': 0,
        'tag': 0,
        'contributors': 0
    }
    
    for repo in repos:
        repo_metrics = collect_repo_metrics_adapter(adapter, repo, load_type, bucket_name)
        
        for key in ['commit', 'pullRequest', 'issues', 'tag', 'contributors']:
            metrics[key] += repo_metrics.get(key, 0)
    
    return metrics


def get_last_check_timestamp(bucket_name):
    """Get the last check timestamp from S3"""
    s3 = boto3.client('s3')
    try:
        response = s3.get_object(Bucket=bucket_name, Key='last_check.json')
        data = json.loads(response['Body'].read())
        return data.get('timestamp')
    except:
        return None

def collect_repo_metrics_adapter(adapter, repo, load_type, bucket_name):
    """Collect metrics for a single repository using adapter"""
    repo_name = repo.get('name')  # Use name (full_name) instead of id
    
    since = None
    if load_type == 'incremental':
        since = get_last_check_timestamp(bucket_name)
    
    metrics = {
        'commit': adapter.get_commits(repo_name, since),
        'pullRequest': adapter.get_pull_requests(repo_name),
        'issues': adapter.get_issues(repo_name),
        'tag': adapter.get_tags(repo_name),
        'contributors': adapter.get_contributors(repo_name)
    }
    
    return metrics








def store_metrics(bucket_name, metrics):
    """Store metrics in S3 as JSON and CSV"""
    s3 = boto3.client('s3')
    
    # Store as JSON in output folder
    s3.put_object(
        Bucket=bucket_name,
        Key='output/response.json',
        Body=json.dumps(metrics, indent=2),
        ContentType='application/json'
    )
    
    # Store as CSV in output folder
    csv_content = convert_to_csv(metrics)
    s3.put_object(
        Bucket=bucket_name,
        Key='output/response.csv',
        Body=csv_content,
        ContentType='text/csv'
    )
    
    # Also store in root for backward compatibility
    s3.put_object(
        Bucket=bucket_name,
        Key='response.json',
        Body=json.dumps(metrics, indent=2),
        ContentType='application/json'
    )
    
    s3.put_object(
        Bucket=bucket_name,
        Key='response.csv',
        Body=csv_content,
        ContentType='text/csv'
    )
    
    # Date-partitioned history snapshot so trends can be analyzed over time
    # (e.g. with Athena: s3://bucket/output/history/dt=YYYY-MM-DD/)
    now = datetime.utcnow()
    s3.put_object(
        Bucket=bucket_name,
        Key=f"output/history/dt={now.strftime('%Y-%m-%d')}/response-{now.strftime('%H%M%S')}.json",
        Body=json.dumps(metrics, indent=2),
        ContentType='application/json'
    )
    
    print(f"Metrics stored in S3: {bucket_name}/output/ (+history snapshot) and root")

def store_chunk_results(bucket_name, chunk_id, metrics):
    """Store chunk results temporarily"""
    s3 = boto3.client('s3')
    
    s3.put_object(
        Bucket=bucket_name,
        Key=f'chunks/chunk_{chunk_id}_results.json',
        Body=json.dumps(metrics, indent=2),
        ContentType='application/json'
    )

def cleanup_chunk_files(bucket_name):
    """Clean up temporary chunk files"""
    s3 = boto3.client('s3')
    
    try:
        # List chunk files
        response = s3.list_objects_v2(Bucket=bucket_name, Prefix='chunks/')
        
        if 'Contents' in response:
            for obj in response['Contents']:
                s3.delete_object(Bucket=bucket_name, Key=obj['Key'])
        
        print("Chunk files cleaned up")
    except Exception as e:
        print(f"Error cleaning up chunk files: {e}")

def update_last_check_timestamp(bucket_name, load_type):
    """Update the last check timestamp after successful processing"""
    s3 = boto3.client('s3')
    current_time = datetime.utcnow().isoformat()
    
    # Update last check time
    timestamp_data = {
        'timestamp': current_time,
        'load_type': load_type,
        'updated_by': 'metrics-collector'
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
    
    print(f"Updated last_check timestamp to: {current_time}")

def sanitize_csv_value(value):
    """Prevent CSV/spreadsheet formula injection (CSR-010).
    Values sourced from external Git APIs (repo names, URLs, descriptions)
    could start with = + - @ or tab/CR characters, which spreadsheet
    applications interpret as formulas. Prefix such values with a single
    quote to neutralize them."""
    if isinstance(value, str) and value and value[0] in ('=', '+', '-', '@', '\t', '\r'):
        return "'" + value
    return value

def convert_to_csv(metrics):
    """Convert metrics to CSV format"""
    output = io.StringIO()
    writer = csv.writer(output)
    
    # Handle new structure with summary and repositories
    if isinstance(metrics, dict) and 'repositories' in metrics:
        repos = metrics['repositories']
        if not repos:
            return ""
        
        # Write header
        headers = ['name', 'url', 'commits', 'pullRequests', 'issues', 'tags', 'contributors']
        writer.writerow(headers)
        
        # Write data rows
        for repo in repos:
            writer.writerow([sanitize_csv_value(repo.get(h, '')) for h in headers])
    elif isinstance(metrics, list):
        # Handle list format (legacy)
        if not metrics:
            return ""
        
        headers = list(metrics[0].keys())
        writer.writerow(headers)
        
        for repo in metrics:
            writer.writerow([sanitize_csv_value(repo.get(h, '')) for h in headers])
    else:
        # Handle dict format (legacy)
        writer.writerow(['metric', 'value'])
        for key, value in metrics.items():
            if key not in ['lastUpdated', 'loadType', 'totalChunks']:
                writer.writerow([sanitize_csv_value(key), sanitize_csv_value(value)])
    
    return output.getvalue()
