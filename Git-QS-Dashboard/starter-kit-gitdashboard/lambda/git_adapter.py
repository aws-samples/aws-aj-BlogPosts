"""Git platform adapter - supports GitHub and GitLab APIs"""
import os
import requests
from abc import ABC, abstractmethod
from datetime import datetime
from urllib.parse import quote

# Default timeout (in seconds) applied to every outbound HTTP request.
# NOTE: requests.Session does NOT honor a `.timeout` attribute, so the
# timeout must be passed explicitly on each call.
REQUEST_TIMEOUT = 30

class GitAdapter(ABC):
    """Base adapter interface for Git platforms"""
    
    def __init__(self, token):
        self.token = token
        self.session = requests.Session()
    
    @abstractmethod
    def get_headers(self):
        pass
    
    @abstractmethod
    def get_repositories(self):
        pass
    
    @abstractmethod
    def get_commits(self, repo_id, since=None):
        pass
    
    @abstractmethod
    def get_pull_requests(self, repo_id):
        pass
    
    @abstractmethod
    def get_issues(self, repo_id):
        pass
    
    @abstractmethod
    def get_tags(self, repo_id):
        pass
    
    @abstractmethod
    def get_contributors(self, repo_id):
        pass

class GitHubAdapter(GitAdapter):
    """GitHub API adapter"""
    
    BASE_URL = 'https://api.github.com'
    
    def get_headers(self):
        return {
            'Authorization': f'token {self.token}',
            'Accept': 'application/vnd.github.v3+json',
            'User-Agent': 'Git-Metrics-Collector'
        }
    
    def get_repositories(self):
        repos = []
        page = 1
        while page <= 50:
            url = f'{self.BASE_URL}/user/repos'
            params = {'per_page': 100, 'page': page, 'sort': 'updated'}
            
            try:
                response = self.session.get(url, headers=self.get_headers(), params=params, timeout=REQUEST_TIMEOUT)
                if response.status_code != 200:
                    break
                
                page_repos = response.json()
                if not page_repos:
                    break
                
                repos.extend([{
                    'id': r['id'],
                    'name': r['full_name'],
                    'url': r.get('html_url', f"https://github.com/{r['full_name']}"),
                    'description': r.get('description', ''),
                    'language': r.get('language', ''),
                    'stars': r.get('stargazers_count', 0),
                    'forks': r.get('forks_count', 0),
                    'created_at': r.get('created_at', ''),
                    'updated_at': r.get('updated_at', ''),
                    'private': r.get('private', False),
                    'default_branch': r.get('default_branch', 'main')
                } for r in page_repos])
                
                if len(page_repos) < 100:
                    break
                page += 1
            except Exception as e:
                print(f"GitHub repos error: {e}")
                break
        
        return repos
    
    def get_commits(self, repo_id, since=None):
        """Get total commit count with pagination"""
        url = f'{self.BASE_URL}/repos/{repo_id}/commits'
        params = {'per_page': 100, 'page': 1}
        if since:
            params['since'] = since
        
        total_commits = 0
        try:
            while True:
                response = self.session.get(url, headers=self.get_headers(), params=params, timeout=REQUEST_TIMEOUT)
                if response.status_code == 200:
                    commits = response.json()
                    if not commits:
                        break
                    total_commits += len(commits)
                    
                    # Check if there are more pages
                    if len(commits) < 100:
                        break
                    params['page'] += 1
                    
                    # Limit to prevent excessive API calls
                    if params['page'] > 100:
                        break
                else:
                    print(f"GitHub: {repo_id} commits error: {response.status_code}")
                    break
            
            print(f"GitHub: {repo_id} - Found {total_commits} commits")
            return total_commits
        except Exception as e:
            print(f"GitHub: {repo_id} commits exception: {e}")
            return total_commits
    
    def get_pull_requests(self, repo_id):
        """Get total PR count with pagination"""
        url = f'{self.BASE_URL}/repos/{repo_id}/pulls'
        params = {'state': 'all', 'per_page': 100, 'page': 1}
        
        total_prs = 0
        try:
            while True:
                response = self.session.get(url, headers=self.get_headers(), params=params, timeout=REQUEST_TIMEOUT)
                if response.status_code == 200:
                    prs = response.json()
                    if not prs:
                        break
                    total_prs += len(prs)
                    
                    if len(prs) < 100:
                        break
                    params['page'] += 1
                    
                    if params['page'] > 50:
                        break
                else:
                    print(f"GitHub: {repo_id} PRs error: {response.status_code}")
                    break
            
            print(f"GitHub: {repo_id} - Found {total_prs} PRs")
            return total_prs
        except Exception as e:
            print(f"GitHub: {repo_id} PRs exception: {e}")
            return total_prs
    
    def get_issues(self, repo_id):
        """Get total issue count with pagination"""
        url = f'{self.BASE_URL}/repos/{repo_id}/issues'
        params = {'state': 'all', 'per_page': 100, 'page': 1}
        
        total_issues = 0
        try:
            while True:
                response = self.session.get(url, headers=self.get_headers(), params=params, timeout=REQUEST_TIMEOUT)
                if response.status_code == 200:
                    issues = response.json()
                    if not issues:
                        break
                    # Filter out PRs (issues API includes PRs)
                    issue_count = len([i for i in issues if 'pull_request' not in i])
                    total_issues += issue_count
                    
                    if len(issues) < 100:
                        break
                    params['page'] += 1
                    
                    if params['page'] > 50:
                        break
                else:
                    print(f"GitHub: {repo_id} issues error: {response.status_code}")
                    break
            
            print(f"GitHub: {repo_id} - Found {total_issues} issues")
            return total_issues
        except Exception as e:
            print(f"GitHub: {repo_id} issues exception: {e}")
            return total_issues
    
    def get_tags(self, repo_id):
        url = f'{self.BASE_URL}/repos/{repo_id}/tags'
        params = {'per_page': 100}
        
        try:
            response = self.session.get(url, headers=self.get_headers(), params=params, timeout=REQUEST_TIMEOUT)
            if response.status_code == 200:
                tags = response.json()
                print(f"GitHub: {repo_id} - Found {len(tags)} tags")
                return len(tags)
            else:
                print(f"GitHub: {repo_id} tags error: {response.status_code}")
                return 0
        except Exception as e:
            print(f"GitHub: {repo_id} tags exception: {e}")
            return 0
    
    def get_contributors(self, repo_id):
        url = f'{self.BASE_URL}/repos/{repo_id}/contributors'
        params = {'per_page': 100}
        
        try:
            response = self.session.get(url, headers=self.get_headers(), params=params, timeout=REQUEST_TIMEOUT)
            if response.status_code == 200:
                contributors = response.json()
                print(f"GitHub: {repo_id} - Found {len(contributors)} contributors")
                return len(contributors)
            else:
                print(f"GitHub: {repo_id} contributors error: {response.status_code}")
                return 0
        except Exception as e:
            print(f"GitHub: {repo_id} contributors exception: {e}")
            return 0

class GitLabAdapter(GitAdapter):
    """GitLab API adapter.
    Works with gitlab.com (default) or any self-managed GitLab instance.
    Set the GITLAB_BASE_URL environment variable (or pass base_url) to point
    at your org's instance, e.g. https://gitlab.example.com"""
    
    def __init__(self, token, base_url=None):
        super().__init__(token)
        base = (base_url or os.environ.get('GITLAB_BASE_URL') or 'https://gitlab.com').rstrip('/')
        self.web_url = base
        self.BASE_URL = f'{base}/api/v4'
        print(f"GitLab: using instance {base}")
    
    def get_headers(self):
        return {
            'PRIVATE-TOKEN': self.token,
            'User-Agent': 'Git-Metrics-Collector'
        }
    
    def get_repositories(self):
        repos = []
        page = 1
        while page <= 50:
            url = f'{self.BASE_URL}/projects'
            params = {'per_page': 100, 'page': page, 'membership': True, 'order_by': 'updated_at'}
            
            try:
                print(f"GitLab: Fetching page {page} from {url}")
                response = self.session.get(url, headers=self.get_headers(), params=params, timeout=REQUEST_TIMEOUT)
                print(f"GitLab: Response status {response.status_code}")
                
                if response.status_code != 200:
                    print(f"GitLab repos error: {response.status_code} - {response.text[:200]}")
                    break
                
                page_repos = response.json()
                if not page_repos:
                    break
                
                print(f"GitLab: Found {len(page_repos)} repos on page {page}")
                repos.extend([{
                    'id': r['id'],
                    'name': r['path_with_namespace'],
                    'url': r.get('web_url', f"{self.web_url}/{r['path_with_namespace']}"),
                    'description': r.get('description', ''),
                    'language': r.get('language', ''),
                    'stars': r.get('star_count', 0),
                    'forks': r.get('forks_count', 0),
                    'created_at': r.get('created_at', ''),
                    'updated_at': r.get('last_activity_at', ''),
                    'private': r.get('visibility', 'private') != 'public',
                    'default_branch': r.get('default_branch', 'main')
                } for r in page_repos])
                
                if len(page_repos) < 100:
                    break
                page += 1
            except Exception as e:
                print(f"GitLab repos error: {e}")
                break
        
        print(f"GitLab: Total repos found: {len(repos)}")
        return repos
    
    def _project(self, repo_id):
        """GitLab's /projects/{id} accepts a numeric ID or a URL-encoded
        'namespace/project' path. Encode the '/' so path-based IDs work."""
        return quote(str(repo_id), safe='')
    
    def _count_total(self, url, extra_params=None, label='items'):
        """Count items accurately using GitLab's X-Total header (single cheap
        request), falling back to page-by-page counting when the header is
        absent (GitLab omits it beyond 10k items)."""
        params = {'per_page': 1}
        if extra_params:
            params.update(extra_params)
        try:
            response = self.session.get(url, headers=self.get_headers(), params=params, timeout=REQUEST_TIMEOUT)
            if response.status_code != 200:
                print(f"GitLab {label} error: {response.status_code}")
                return 0
            total = response.headers.get('x-total')
            if total is not None and total.isdigit():
                return int(total)
            # Fallback: paginate and count
            count, page = 0, 1
            while page <= 100:
                page_params = dict(params, per_page=100, page=page)
                r = self.session.get(url, headers=self.get_headers(), params=page_params, timeout=REQUEST_TIMEOUT)
                if r.status_code != 200:
                    break
                items = r.json()
                count += len(items)
                if len(items) < 100:
                    break
                page += 1
            return count
        except Exception as e:
            print(f"GitLab {label} exception: {e}")
            return 0
    
    def get_commits(self, repo_id, since=None):
        url = f'{self.BASE_URL}/projects/{self._project(repo_id)}/repository/commits'
        extra = {'since': since} if since else None
        return self._count_total(url, extra, label=f'{repo_id} commits')
    
    def get_pull_requests(self, repo_id):
        url = f'{self.BASE_URL}/projects/{self._project(repo_id)}/merge_requests'
        return self._count_total(url, {'state': 'all'}, label=f'{repo_id} MRs')
    
    def get_issues(self, repo_id):
        url = f'{self.BASE_URL}/projects/{self._project(repo_id)}/issues'
        return self._count_total(url, label=f'{repo_id} issues')
    
    def get_tags(self, repo_id):
        url = f'{self.BASE_URL}/projects/{self._project(repo_id)}/repository/tags'
        return self._count_total(url, label=f'{repo_id} tags')
    
    def get_contributors(self, repo_id):
        url = f'{self.BASE_URL}/projects/{self._project(repo_id)}/repository/contributors'
        return self._count_total(url, label=f'{repo_id} contributors')

def get_adapter(token):
    """Factory function to detect and return appropriate adapter"""
    if token.startswith('ghp_') or token.startswith('github_pat_'):
        print("Detected GitHub token")
        return GitHubAdapter(token)
    elif token.startswith('glpat-'):
        print("Detected GitLab token")
        return GitLabAdapter(token)
    else:
        # Try GitHub first, fallback to GitLab
        print("Unknown token format, trying GitHub first")
        return GitHubAdapter(token)
