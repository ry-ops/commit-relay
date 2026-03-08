#!/usr/bin/env node
// lib/rag/connectors/github-connector.js
// GitHub repository connector using @octokit/rest
// Part of RAG Knowledge Ingestion System

const BaseConnector = require('./base-connector');

/**
 * GitHubConnector - Fetch data from GitHub repositories
 *
 * Features:
 * - README and documentation files
 * - Issues and pull requests
 * - Code files with pattern filtering
 * - Repository metadata
 * - Rate limiting handling
 */
class GitHubConnector extends BaseConnector {
  constructor(config = {}) {
    super(config);

    this.name = config.name || 'github';
    this.type = 'github';

    // GitHub-specific configuration
    this.token = config.token || process.env.GITHUB_TOKEN;
    this.owner = config.owner;
    this.repo = config.repo;
    this.branch = config.branch || 'main';

    // File filtering
    this.includePatterns = config.includePatterns || ['**/*.md', '**/*.txt', '**/*.js', '**/*.ts', '**/*.py'];
    this.excludePatterns = config.excludePatterns || ['**/node_modules/**', '**/dist/**', '**/build/**'];
    this.maxFileSize = config.maxFileSize || 100000; // 100KB default

    // Content types to fetch
    this.fetchOptions = {
      readme: config.fetchReadme !== false,
      issues: config.fetchIssues !== false,
      pullRequests: config.fetchPullRequests !== false,
      codeFiles: config.fetchCodeFiles !== false,
      discussions: config.fetchDiscussions || false
    };

    // Octokit instance (lazy loaded)
    this.octokit = null;
  }

  /**
   * Connect to GitHub API
   * @returns {Promise<boolean>}
   */
  async connect() {
    try {
      // Lazy load @octokit/rest
      const { Octokit } = await this.loadOctokit();

      this.octokit = new Octokit({
        auth: this.token,
        request: {
          timeout: this.timeout
        }
      });

      // Test connection with rate limit check
      const { data: rateLimit } = await this.octokit.rateLimit.get();

      this.connected = true;
      this.log('info', 'Connected to GitHub API', {
        rateLimit: rateLimit.rate.remaining,
        resetAt: new Date(rateLimit.rate.reset * 1000).toISOString()
      });

      return true;
    } catch (error) {
      this.log('error', 'Failed to connect to GitHub', { error: error.message });
      throw error;
    }
  }

  /**
   * Load Octokit dynamically
   * @returns {Promise<Object>}
   */
  async loadOctokit() {
    try {
      return require('@octokit/rest');
    } catch {
      throw new Error('@octokit/rest is not installed. Run: npm install @octokit/rest');
    }
  }

  /**
   * Fetch data from GitHub repository
   * @param {Object} options - Fetch options
   * @param {string} options.owner - Repository owner (optional, uses config)
   * @param {string} options.repo - Repository name (optional, uses config)
   * @param {string} options.branch - Branch name (optional, uses config)
   * @param {Object} options.filters - Content type filters
   * @returns {Promise<Object>} - Fetched data by type
   */
  async fetch(options = {}) {
    if (!this.connected) {
      await this.connect();
    }

    const owner = options.owner || this.owner;
    const repo = options.repo || this.repo;
    const branch = options.branch || this.branch;

    if (!owner || !repo) {
      throw new Error('Repository owner and name are required');
    }

    const results = {
      readme: null,
      issues: [],
      pullRequests: [],
      codeFiles: [],
      metadata: null
    };

    try {
      // Fetch repository metadata
      const { data: repoData } = await this.octokit.repos.get({ owner, repo });
      results.metadata = {
        name: repoData.name,
        fullName: repoData.full_name,
        description: repoData.description,
        url: repoData.html_url,
        defaultBranch: repoData.default_branch,
        stars: repoData.stargazers_count,
        language: repoData.language
      };

      // Fetch README
      if (this.fetchOptions.readme) {
        results.readme = await this.fetchReadme(owner, repo);
      }

      // Fetch issues
      if (this.fetchOptions.issues) {
        results.issues = await this.fetchIssues(owner, repo, options.issueState || 'all');
      }

      // Fetch pull requests
      if (this.fetchOptions.pullRequests) {
        results.pullRequests = await this.fetchPullRequests(owner, repo, options.prState || 'all');
      }

      // Fetch code files
      if (this.fetchOptions.codeFiles) {
        results.codeFiles = await this.fetchCodeFiles(owner, repo, branch, options.path || '');
      }

      this.updateStats(true);
      return results;
    } catch (error) {
      this.updateStats(false);
      this.log('error', 'Failed to fetch from GitHub', { error: error.message, owner, repo });
      throw error;
    }
  }

  /**
   * Fetch repository README
   * @param {string} owner - Repository owner
   * @param {string} repo - Repository name
   * @returns {Promise<Object|null>}
   */
  async fetchReadme(owner, repo) {
    try {
      const { data } = await this.octokit.repos.getReadme({
        owner,
        repo,
        mediaType: { format: 'raw' }
      });

      return {
        content: data,
        name: 'README.md',
        url: `https://github.com/${owner}/${repo}/blob/main/README.md`
      };
    } catch (error) {
      if (error.status === 404) {
        this.log('warn', 'README not found', { owner, repo });
        return null;
      }
      throw error;
    }
  }

  /**
   * Fetch repository issues
   * @param {string} owner - Repository owner
   * @param {string} repo - Repository name
   * @param {string} state - Issue state (open, closed, all)
   * @returns {Promise<Array>}
   */
  async fetchIssues(owner, repo, state = 'all') {
    const issues = [];

    try {
      const iterator = this.octokit.paginate.iterator(
        this.octokit.issues.listForRepo,
        {
          owner,
          repo,
          state,
          per_page: this.batchSize
        }
      );

      for await (const { data: pageIssues } of iterator) {
        for (const issue of pageIssues) {
          // Skip pull requests (they appear in issues API)
          if (issue.pull_request) continue;

          issues.push({
            number: issue.number,
            title: issue.title,
            body: issue.body || '',
            state: issue.state,
            url: issue.html_url,
            labels: issue.labels.map(l => l.name),
            createdAt: issue.created_at,
            updatedAt: issue.updated_at,
            author: issue.user?.login
          });

          // Rate limiting
          await this.sleep(this.rateLimitDelay / 10);
        }
      }

      return issues;
    } catch (error) {
      this.log('error', 'Failed to fetch issues', { error: error.message });
      return [];
    }
  }

  /**
   * Fetch pull requests
   * @param {string} owner - Repository owner
   * @param {string} repo - Repository name
   * @param {string} state - PR state (open, closed, all)
   * @returns {Promise<Array>}
   */
  async fetchPullRequests(owner, repo, state = 'all') {
    const pullRequests = [];

    try {
      const iterator = this.octokit.paginate.iterator(
        this.octokit.pulls.list,
        {
          owner,
          repo,
          state,
          per_page: this.batchSize
        }
      );

      for await (const { data: pagePRs } of iterator) {
        for (const pr of pagePRs) {
          pullRequests.push({
            number: pr.number,
            title: pr.title,
            body: pr.body || '',
            state: pr.state,
            url: pr.html_url,
            labels: pr.labels.map(l => l.name),
            createdAt: pr.created_at,
            updatedAt: pr.updated_at,
            mergedAt: pr.merged_at,
            author: pr.user?.login,
            base: pr.base?.ref,
            head: pr.head?.ref
          });

          await this.sleep(this.rateLimitDelay / 10);
        }
      }

      return pullRequests;
    } catch (error) {
      this.log('error', 'Failed to fetch pull requests', { error: error.message });
      return [];
    }
  }

  /**
   * Fetch code files from repository
   * @param {string} owner - Repository owner
   * @param {string} repo - Repository name
   * @param {string} branch - Branch name
   * @param {string} path - Path prefix
   * @returns {Promise<Array>}
   */
  async fetchCodeFiles(owner, repo, branch, path = '') {
    const files = [];

    try {
      // Get tree recursively
      const { data: tree } = await this.octokit.git.getTree({
        owner,
        repo,
        tree_sha: branch,
        recursive: 'true'
      });

      // Filter files by pattern
      const matchedFiles = tree.tree.filter(item => {
        if (item.type !== 'blob') return false;
        if (item.size > this.maxFileSize) return false;

        const filePath = item.path;

        // Check exclude patterns
        for (const pattern of this.excludePatterns) {
          if (this.matchPattern(filePath, pattern)) return false;
        }

        // Check include patterns
        for (const pattern of this.includePatterns) {
          if (this.matchPattern(filePath, pattern)) return true;
        }

        return false;
      });

      // Fetch file contents
      for (const file of matchedFiles) {
        try {
          const { data } = await this.octokit.repos.getContent({
            owner,
            repo,
            path: file.path,
            ref: branch
          });

          if (data.content) {
            const content = Buffer.from(data.content, 'base64').toString('utf-8');
            files.push({
              path: file.path,
              content: content,
              size: file.size,
              sha: file.sha,
              url: data.html_url
            });
          }

          await this.sleep(this.rateLimitDelay / 10);
        } catch (error) {
          this.log('warn', 'Failed to fetch file', { path: file.path, error: error.message });
        }
      }

      return files;
    } catch (error) {
      this.log('error', 'Failed to fetch code files', { error: error.message });
      return [];
    }
  }

  /**
   * Simple pattern matching (glob-like)
   * @param {string} path - File path
   * @param {string} pattern - Glob pattern
   * @returns {boolean}
   */
  matchPattern(path, pattern) {
    // Convert glob pattern to regex
    const regexPattern = pattern
      .replace(/\*\*/g, '.*')
      .replace(/\*/g, '[^/]*')
      .replace(/\?/g, '.')
      .replace(/\//g, '\\/');

    const regex = new RegExp(`^${regexPattern}$`);
    return regex.test(path);
  }

  /**
   * Transform GitHub data to standard documents
   * @param {Object} data - Raw GitHub data
   * @returns {Array<Object>}
   */
  transform(data) {
    const documents = [];
    const source = `${data.metadata?.fullName || this.owner + '/' + this.repo}`;

    // Transform README
    if (data.readme) {
      documents.push(this.createDocument({
        id: 'readme',
        content: data.readme.content,
        title: `README - ${source}`,
        url: data.readme.url,
        metadata: {
          type: 'readme',
          repository: source
        },
        source,
        type: 'markdown'
      }));
    }

    // Transform issues
    for (const issue of data.issues || []) {
      documents.push(this.createDocument({
        id: `issue-${issue.number}`,
        content: `# ${issue.title}\n\n${issue.body}`,
        title: issue.title,
        url: issue.url,
        metadata: {
          type: 'issue',
          number: issue.number,
          state: issue.state,
          labels: issue.labels,
          author: issue.author,
          createdAt: issue.createdAt,
          repository: source
        },
        source,
        type: 'issue'
      }));
    }

    // Transform pull requests
    for (const pr of data.pullRequests || []) {
      documents.push(this.createDocument({
        id: `pr-${pr.number}`,
        content: `# ${pr.title}\n\n${pr.body}`,
        title: pr.title,
        url: pr.url,
        metadata: {
          type: 'pull_request',
          number: pr.number,
          state: pr.state,
          labels: pr.labels,
          author: pr.author,
          base: pr.base,
          head: pr.head,
          createdAt: pr.createdAt,
          mergedAt: pr.mergedAt,
          repository: source
        },
        source,
        type: 'pull_request'
      }));
    }

    // Transform code files
    for (const file of data.codeFiles || []) {
      documents.push(this.createDocument({
        id: `file-${file.sha}`,
        content: this.truncate(file.content),
        title: file.path,
        url: file.url,
        metadata: {
          type: 'code',
          path: file.path,
          size: file.size,
          sha: file.sha,
          repository: source
        },
        source,
        type: 'code'
      }));
    }

    return documents;
  }

  /**
   * Check GitHub API health and rate limits
   * @returns {Promise<Object>}
   */
  async healthCheck() {
    try {
      if (!this.connected) {
        await this.connect();
      }

      const { data } = await this.octokit.rateLimit.get();
      const core = data.rate;

      return {
        healthy: core.remaining > 0,
        connector: this.name,
        type: this.type,
        rateLimit: {
          limit: core.limit,
          remaining: core.remaining,
          reset: new Date(core.reset * 1000).toISOString(),
          percentRemaining: ((core.remaining / core.limit) * 100).toFixed(2) + '%'
        },
        checkedAt: new Date().toISOString()
      };
    } catch (error) {
      return {
        healthy: false,
        connector: this.name,
        type: this.type,
        error: error.message,
        checkedAt: new Date().toISOString()
      };
    }
  }
}

module.exports = GitHubConnector;
