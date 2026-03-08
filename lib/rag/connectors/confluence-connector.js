#!/usr/bin/env node
// lib/rag/connectors/confluence-connector.js
// Confluence REST API connector
// Part of RAG Knowledge Ingestion System

const BaseConnector = require('./base-connector');

/**
 * ConfluenceConnector - Fetch data from Confluence spaces
 *
 * Features:
 * - Fetch pages by space key
 * - HTML to text conversion
 * - Attachment support
 * - Page hierarchy traversal
 * - Label filtering
 */
class ConfluenceConnector extends BaseConnector {
  constructor(config = {}) {
    super(config);

    this.name = config.name || 'confluence';
    this.type = 'confluence';

    // Confluence-specific configuration
    this.baseUrl = config.baseUrl || process.env.CONFLUENCE_BASE_URL;
    this.username = config.username || process.env.CONFLUENCE_USERNAME;
    this.apiToken = config.apiToken || process.env.CONFLUENCE_API_TOKEN;

    // Ensure baseUrl ends properly
    if (this.baseUrl && !this.baseUrl.endsWith('/')) {
      this.baseUrl += '/';
    }

    // Space and content configuration
    this.spaceKeys = config.spaceKeys || [];
    this.includeLabels = config.includeLabels || [];
    this.excludeLabels = config.excludeLabels || [];
    this.maxPages = config.maxPages || 1000;

    // Content options
    this.fetchOptions = {
      attachments: config.fetchAttachments || false,
      comments: config.fetchComments || false,
      children: config.fetchChildren !== false
    };

    // Content expansion
    this.expand = 'body.storage,metadata.labels,ancestors,children.page,version';
  }

  /**
   * Connect to Confluence API
   * @returns {Promise<boolean>}
   */
  async connect() {
    this.validateConfig(['baseUrl', 'username', 'apiToken']);

    try {
      // Test connection by fetching space list
      const response = await this.makeRequest('/rest/api/space', { limit: 1 });

      if (response.results) {
        this.connected = true;
        this.log('info', 'Connected to Confluence API', {
          baseUrl: this.baseUrl,
          spaces: response.size
        });
        return true;
      }

      throw new Error('Invalid response from Confluence API');
    } catch (error) {
      this.log('error', 'Failed to connect to Confluence', { error: error.message });
      throw error;
    }
  }

  /**
   * Make authenticated request to Confluence API
   * @param {string} endpoint - API endpoint
   * @param {Object} params - Query parameters
   * @returns {Promise<Object>}
   */
  async makeRequest(endpoint, params = {}) {
    const url = new URL(endpoint, this.baseUrl);

    // Add query parameters
    Object.entries(params).forEach(([key, value]) => {
      if (value !== undefined && value !== null) {
        url.searchParams.append(key, value);
      }
    });

    const auth = Buffer.from(`${this.username}:${this.apiToken}`).toString('base64');

    const response = await fetch(url.toString(), {
      method: 'GET',
      headers: {
        'Authorization': `Basic ${auth}`,
        'Accept': 'application/json',
        'Content-Type': 'application/json'
      },
      signal: AbortSignal.timeout(this.timeout)
    });

    if (!response.ok) {
      const error = await response.text();
      throw new Error(`Confluence API error: ${response.status} - ${error}`);
    }

    return response.json();
  }

  /**
   * Fetch data from Confluence spaces
   * @param {Object} options - Fetch options
   * @param {Array<string>} options.spaceKeys - Space keys to fetch
   * @param {Array<string>} options.labels - Filter by labels
   * @param {number} options.limit - Maximum pages to fetch
   * @returns {Promise<Object>}
   */
  async fetch(options = {}) {
    if (!this.connected) {
      await this.connect();
    }

    const spaceKeys = options.spaceKeys || this.spaceKeys;
    const labels = options.labels || this.includeLabels;
    const limit = options.limit || this.maxPages;

    const results = {
      pages: [],
      attachments: [],
      spaces: []
    };

    try {
      // If no specific spaces, fetch all available
      if (spaceKeys.length === 0) {
        const spacesResponse = await this.fetchSpaces();
        spaceKeys.push(...spacesResponse.map(s => s.key));
        results.spaces = spacesResponse;
      }

      // Fetch pages from each space
      for (const spaceKey of spaceKeys) {
        const pages = await this.fetchSpacePages(spaceKey, labels, limit);
        results.pages.push(...pages);

        // Rate limiting
        await this.sleep(this.rateLimitDelay);
      }

      // Fetch attachments if enabled
      if (this.fetchOptions.attachments && results.pages.length > 0) {
        for (const page of results.pages) {
          const attachments = await this.fetchPageAttachments(page.id);
          results.attachments.push(...attachments);
          await this.sleep(this.rateLimitDelay / 2);
        }
      }

      this.updateStats(true);
      return results;
    } catch (error) {
      this.updateStats(false);
      this.log('error', 'Failed to fetch from Confluence', { error: error.message });
      throw error;
    }
  }

  /**
   * Fetch available spaces
   * @returns {Promise<Array>}
   */
  async fetchSpaces() {
    const spaces = [];
    let start = 0;
    const limit = 25;

    while (true) {
      const response = await this.makeRequest('/rest/api/space', {
        start,
        limit,
        type: 'global'
      });

      for (const space of response.results) {
        spaces.push({
          key: space.key,
          name: space.name,
          type: space.type,
          url: space._links?.webui
        });
      }

      if (response.results.length < limit || spaces.length >= this.maxPages) {
        break;
      }

      start += limit;
      await this.sleep(this.rateLimitDelay / 2);
    }

    return spaces;
  }

  /**
   * Fetch pages from a space
   * @param {string} spaceKey - Space key
   * @param {Array<string>} labels - Filter by labels
   * @param {number} limit - Maximum pages
   * @returns {Promise<Array>}
   */
  async fetchSpacePages(spaceKey, labels = [], limit = 1000) {
    const pages = [];
    let start = 0;
    const pageLimit = 25;

    // Build CQL query
    let cql = `space = "${spaceKey}" AND type = page`;
    if (labels.length > 0) {
      cql += ` AND label IN (${labels.map(l => `"${l}"`).join(',')})`;
    }

    while (pages.length < limit) {
      const response = await this.makeRequest('/rest/api/content/search', {
        cql,
        start,
        limit: pageLimit,
        expand: this.expand
      });

      for (const page of response.results) {
        // Check exclude labels
        const pageLabels = page.metadata?.labels?.results?.map(l => l.name) || [];
        const shouldExclude = this.excludeLabels.some(l => pageLabels.includes(l));

        if (!shouldExclude) {
          pages.push(this.extractPageData(page, spaceKey));
        }
      }

      if (response.results.length < pageLimit || pages.length >= limit) {
        break;
      }

      start += pageLimit;
      await this.sleep(this.rateLimitDelay / 2);
    }

    return pages;
  }

  /**
   * Extract relevant page data
   * @param {Object} page - Raw page data
   * @param {string} spaceKey - Space key
   * @returns {Object}
   */
  extractPageData(page, spaceKey) {
    const body = page.body?.storage?.value || '';
    const labels = page.metadata?.labels?.results?.map(l => l.name) || [];
    const ancestors = page.ancestors?.map(a => ({ id: a.id, title: a.title })) || [];

    return {
      id: page.id,
      title: page.title,
      body: body,
      bodyText: this.stripHtml(body),
      spaceKey: spaceKey,
      url: this.baseUrl + page._links?.webui?.replace(/^\//, ''),
      labels: labels,
      ancestors: ancestors,
      version: page.version?.number,
      createdAt: page.history?.createdDate,
      updatedAt: page.version?.when,
      author: page.version?.by?.displayName
    };
  }

  /**
   * Fetch page attachments
   * @param {string} pageId - Page ID
   * @returns {Promise<Array>}
   */
  async fetchPageAttachments(pageId) {
    try {
      const response = await this.makeRequest(
        `/rest/api/content/${pageId}/child/attachment`,
        { limit: 100 }
      );

      return response.results.map(att => ({
        id: att.id,
        pageId: pageId,
        title: att.title,
        filename: att.title,
        mediaType: att.metadata?.mediaType,
        size: att.extensions?.fileSize,
        url: this.baseUrl + att._links?.download?.replace(/^\//, ''),
        createdAt: att.history?.createdDate
      }));
    } catch (error) {
      this.log('warn', 'Failed to fetch attachments', { pageId, error: error.message });
      return [];
    }
  }

  /**
   * Transform Confluence data to standard documents
   * @param {Object} data - Raw Confluence data
   * @returns {Array<Object>}
   */
  transform(data) {
    const documents = [];

    // Transform pages
    for (const page of data.pages || []) {
      const content = `# ${page.title}\n\n${page.bodyText}`;

      documents.push(this.createDocument({
        id: page.id,
        content: this.truncate(content),
        title: page.title,
        url: page.url,
        metadata: {
          type: 'page',
          spaceKey: page.spaceKey,
          labels: page.labels,
          ancestors: page.ancestors,
          version: page.version,
          author: page.author,
          createdAt: page.createdAt,
          updatedAt: page.updatedAt
        },
        source: `confluence:${page.spaceKey}`,
        type: 'wiki'
      }));
    }

    // Transform attachments metadata
    for (const attachment of data.attachments || []) {
      documents.push(this.createDocument({
        id: `attachment-${attachment.id}`,
        content: `Attachment: ${attachment.title}\nType: ${attachment.mediaType}\nSize: ${attachment.size}`,
        title: attachment.title,
        url: attachment.url,
        metadata: {
          type: 'attachment',
          pageId: attachment.pageId,
          mediaType: attachment.mediaType,
          size: attachment.size,
          createdAt: attachment.createdAt
        },
        source: 'confluence',
        type: 'attachment'
      }));
    }

    return documents;
  }

  /**
   * Check Confluence API health
   * @returns {Promise<Object>}
   */
  async healthCheck() {
    try {
      if (!this.connected) {
        await this.connect();
      }

      const response = await this.makeRequest('/rest/api/space', { limit: 1 });

      return {
        healthy: true,
        connector: this.name,
        type: this.type,
        spaces: response.size,
        baseUrl: this.baseUrl,
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

module.exports = ConfluenceConnector;
