#!/usr/bin/env node
// lib/rag/connectors/slack-connector.js
// Slack Web API connector
// Part of RAG Knowledge Ingestion System

const BaseConnector = require('./base-connector');

/**
 * SlackConnector - Fetch messages from Slack channels
 *
 * Features:
 * - Fetch messages from channels
 * - Thread support
 * - User mention resolution
 * - File/attachment metadata
 * - Reaction tracking
 */
class SlackConnector extends BaseConnector {
  constructor(config = {}) {
    super(config);

    this.name = config.name || 'slack';
    this.type = 'slack';

    // Slack-specific configuration
    this.token = config.token || process.env.SLACK_BOT_TOKEN;
    this.baseUrl = 'https://slack.com/api';

    // Channel configuration
    this.channels = config.channels || [];
    this.excludeChannels = config.excludeChannels || [];

    // Message filtering
    this.messageLimit = config.messageLimit || 1000;
    this.fetchThreads = config.fetchThreads !== false;
    this.minReactions = config.minReactions || 0;

    // Time range (timestamps in seconds)
    this.oldest = config.oldest || null;
    this.latest = config.latest || null;

    // User cache
    this.userCache = new Map();
    this.channelCache = new Map();
  }

  /**
   * Connect to Slack API
   * @returns {Promise<boolean>}
   */
  async connect() {
    this.validateConfig(['token']);

    try {
      // Test connection with auth.test
      const response = await this.makeRequest('auth.test');

      if (response.ok) {
        this.connected = true;
        this.teamId = response.team_id;
        this.teamName = response.team;
        this.botId = response.bot_id;

        this.log('info', 'Connected to Slack API', {
          team: this.teamName,
          teamId: this.teamId
        });

        return true;
      }

      throw new Error(response.error || 'Authentication failed');
    } catch (error) {
      this.log('error', 'Failed to connect to Slack', { error: error.message });
      throw error;
    }
  }

  /**
   * Make request to Slack API
   * @param {string} method - API method
   * @param {Object} params - Request parameters
   * @returns {Promise<Object>}
   */
  async makeRequest(method, params = {}) {
    const url = `${this.baseUrl}/${method}`;

    const response = await fetch(url, {
      method: 'POST',
      headers: {
        'Authorization': `Bearer ${this.token}`,
        'Content-Type': 'application/json; charset=utf-8'
      },
      body: JSON.stringify(params),
      signal: AbortSignal.timeout(this.timeout)
    });

    const data = await response.json();

    if (!response.ok) {
      throw new Error(`Slack API error: ${response.status}`);
    }

    // Handle rate limiting
    if (data.error === 'ratelimited') {
      const retryAfter = parseInt(response.headers.get('Retry-After') || '60', 10);
      this.log('warn', 'Rate limited by Slack API', { retryAfter });
      await this.sleep(retryAfter * 1000);
      return this.makeRequest(method, params);
    }

    return data;
  }

  /**
   * Fetch data from Slack
   * @param {Object} options - Fetch options
   * @param {Array<string>} options.channels - Channel IDs or names
   * @param {number} options.oldest - Oldest message timestamp
   * @param {number} options.latest - Latest message timestamp
   * @returns {Promise<Object>}
   */
  async fetch(options = {}) {
    if (!this.connected) {
      await this.connect();
    }

    const results = {
      messages: [],
      threads: [],
      channels: [],
      users: []
    };

    try {
      // Get channel list if none specified
      let channelIds = options.channels || this.channels;
      if (channelIds.length === 0) {
        results.channels = await this.fetchChannels();
        channelIds = results.channels.map(c => c.id);
      }

      // Filter out excluded channels
      channelIds = channelIds.filter(id => !this.excludeChannels.includes(id));

      // Fetch messages from each channel
      for (const channelId of channelIds) {
        const channelMessages = await this.fetchChannelMessages(
          channelId,
          options.oldest || this.oldest,
          options.latest || this.latest
        );
        results.messages.push(...channelMessages);

        await this.sleep(this.rateLimitDelay);
      }

      // Fetch threads if enabled
      if (this.fetchThreads) {
        const threadedMessages = results.messages.filter(m => m.thread_ts && m.reply_count > 0);
        for (const message of threadedMessages) {
          const replies = await this.fetchThreadReplies(message.channel, message.thread_ts);
          results.threads.push({
            parent: message,
            replies
          });

          await this.sleep(this.rateLimitDelay / 2);
        }
      }

      // Resolve user mentions
      const userIds = this.extractUserIds(results.messages);
      results.users = await this.fetchUsers(userIds);

      this.updateStats(true);
      return results;
    } catch (error) {
      this.updateStats(false);
      this.log('error', 'Failed to fetch from Slack', { error: error.message });
      throw error;
    }
  }

  /**
   * Fetch list of channels
   * @returns {Promise<Array>}
   */
  async fetchChannels() {
    const channels = [];
    let cursor = null;

    while (true) {
      const response = await this.makeRequest('conversations.list', {
        types: 'public_channel,private_channel',
        limit: 200,
        cursor
      });

      if (!response.ok) {
        throw new Error(response.error);
      }

      for (const channel of response.channels) {
        channels.push({
          id: channel.id,
          name: channel.name,
          isPrivate: channel.is_private,
          topic: channel.topic?.value,
          purpose: channel.purpose?.value,
          memberCount: channel.num_members
        });

        this.channelCache.set(channel.id, channel.name);
      }

      cursor = response.response_metadata?.next_cursor;
      if (!cursor) break;

      await this.sleep(this.rateLimitDelay / 2);
    }

    return channels;
  }

  /**
   * Fetch messages from a channel
   * @param {string} channelId - Channel ID
   * @param {number} oldest - Oldest timestamp
   * @param {number} latest - Latest timestamp
   * @returns {Promise<Array>}
   */
  async fetchChannelMessages(channelId, oldest, latest) {
    const messages = [];
    let cursor = null;

    while (messages.length < this.messageLimit) {
      const params = {
        channel: channelId,
        limit: 200,
        cursor
      };

      if (oldest) params.oldest = oldest;
      if (latest) params.latest = latest;

      const response = await this.makeRequest('conversations.history', params);

      if (!response.ok) {
        if (response.error === 'channel_not_found') {
          this.log('warn', 'Channel not found', { channelId });
          return [];
        }
        throw new Error(response.error);
      }

      for (const message of response.messages) {
        // Filter by reactions if specified
        if (this.minReactions > 0 && (message.reactions?.length || 0) < this.minReactions) {
          continue;
        }

        messages.push({
          ...message,
          channel: channelId,
          channelName: this.channelCache.get(channelId) || channelId
        });
      }

      cursor = response.response_metadata?.next_cursor;
      if (!cursor || !response.has_more) break;

      await this.sleep(this.rateLimitDelay / 2);
    }

    return messages;
  }

  /**
   * Fetch thread replies
   * @param {string} channelId - Channel ID
   * @param {string} threadTs - Thread timestamp
   * @returns {Promise<Array>}
   */
  async fetchThreadReplies(channelId, threadTs) {
    const replies = [];
    let cursor = null;

    while (true) {
      const response = await this.makeRequest('conversations.replies', {
        channel: channelId,
        ts: threadTs,
        limit: 200,
        cursor
      });

      if (!response.ok) {
        throw new Error(response.error);
      }

      // Skip first message (it's the parent)
      const threadReplies = response.messages.slice(1);
      replies.push(...threadReplies);

      cursor = response.response_metadata?.next_cursor;
      if (!cursor || !response.has_more) break;

      await this.sleep(this.rateLimitDelay / 2);
    }

    return replies;
  }

  /**
   * Extract user IDs from messages
   * @param {Array} messages - Messages
   * @returns {Array<string>}
   */
  extractUserIds(messages) {
    const userIds = new Set();

    for (const message of messages) {
      if (message.user) {
        userIds.add(message.user);
      }

      // Extract mentions from text
      const mentions = message.text?.match(/<@([A-Z0-9]+)>/g) || [];
      for (const mention of mentions) {
        const userId = mention.match(/<@([A-Z0-9]+)>/)?.[1];
        if (userId) {
          userIds.add(userId);
        }
      }
    }

    return Array.from(userIds);
  }

  /**
   * Fetch user information
   * @param {Array<string>} userIds - User IDs
   * @returns {Promise<Array>}
   */
  async fetchUsers(userIds) {
    const users = [];

    for (const userId of userIds) {
      if (this.userCache.has(userId)) {
        users.push(this.userCache.get(userId));
        continue;
      }

      try {
        const response = await this.makeRequest('users.info', { user: userId });

        if (response.ok) {
          const userData = {
            id: response.user.id,
            name: response.user.name,
            realName: response.user.real_name,
            displayName: response.user.profile?.display_name,
            email: response.user.profile?.email,
            isBot: response.user.is_bot
          };

          this.userCache.set(userId, userData);
          users.push(userData);
        }

        await this.sleep(this.rateLimitDelay / 5);
      } catch (error) {
        this.log('warn', 'Failed to fetch user', { userId, error: error.message });
      }
    }

    return users;
  }

  /**
   * Resolve user mentions in text
   * @param {string} text - Message text
   * @returns {string}
   */
  resolveUserMentions(text) {
    if (!text) return '';

    return text.replace(/<@([A-Z0-9]+)>/g, (match, userId) => {
      const user = this.userCache.get(userId);
      if (user) {
        return `@${user.displayName || user.realName || user.name}`;
      }
      return match;
    });
  }

  /**
   * Format message timestamp
   * @param {string} ts - Slack timestamp
   * @returns {string}
   */
  formatTimestamp(ts) {
    const seconds = parseFloat(ts);
    return new Date(seconds * 1000).toISOString();
  }

  /**
   * Transform Slack data to standard documents
   * @param {Object} data - Raw Slack data
   * @returns {Array<Object>}
   */
  transform(data) {
    const documents = [];

    // Transform messages
    for (const message of data.messages || []) {
      const text = this.resolveUserMentions(message.text || '');
      const user = this.userCache.get(message.user);

      documents.push(this.createDocument({
        id: `${message.channel}-${message.ts}`,
        content: text,
        title: `Message in #${message.channelName}`,
        url: `https://slack.com/archives/${message.channel}/p${message.ts.replace('.', '')}`,
        metadata: {
          type: 'message',
          channel: message.channel,
          channelName: message.channelName,
          user: message.user,
          userName: user?.realName || user?.name,
          timestamp: this.formatTimestamp(message.ts),
          threadTs: message.thread_ts,
          replyCount: message.reply_count || 0,
          reactions: message.reactions?.map(r => r.name) || [],
          hasFiles: (message.files?.length || 0) > 0
        },
        source: `slack:${message.channelName}`,
        type: 'message'
      }));
    }

    // Transform threads
    for (const thread of data.threads || []) {
      const replies = thread.replies.map(r => {
        const user = this.userCache.get(r.user);
        return `[${user?.realName || r.user}]: ${this.resolveUserMentions(r.text || '')}`;
      }).join('\n');

      const parentText = this.resolveUserMentions(thread.parent.text || '');

      documents.push(this.createDocument({
        id: `thread-${thread.parent.channel}-${thread.parent.thread_ts}`,
        content: `Thread:\n${parentText}\n\nReplies:\n${replies}`,
        title: `Thread in #${thread.parent.channelName}`,
        url: `https://slack.com/archives/${thread.parent.channel}/p${thread.parent.thread_ts.replace('.', '')}`,
        metadata: {
          type: 'thread',
          channel: thread.parent.channel,
          channelName: thread.parent.channelName,
          timestamp: this.formatTimestamp(thread.parent.thread_ts),
          replyCount: thread.replies.length,
          participants: [...new Set(thread.replies.map(r => r.user))]
        },
        source: `slack:${thread.parent.channelName}`,
        type: 'thread'
      }));
    }

    return documents;
  }

  /**
   * Check Slack API health
   * @returns {Promise<Object>}
   */
  async healthCheck() {
    try {
      if (!this.connected) {
        await this.connect();
      }

      const response = await this.makeRequest('api.test');

      return {
        healthy: response.ok,
        connector: this.name,
        type: this.type,
        team: this.teamName,
        teamId: this.teamId,
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

module.exports = SlackConnector;
