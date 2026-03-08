#!/usr/bin/env node
// lib/rag/parsers/markdown-parser.js
// Markdown document parser using marked
// Part of RAG Enhancement: Document Conversion

const fs = require('fs');
const path = require('path');

// Lazy load marked to handle missing dependency gracefully
let marked = null;

/**
 * MarkdownParser - Parse Markdown documents into structured chunks
 *
 * Features:
 * - Chunk by heading hierarchy
 * - Preserve code blocks
 * - Extract frontmatter
 * - Table extraction
 */
class MarkdownParser {
  constructor(options = {}) {
    this.options = {
      preserveCodeBlocks: options.preserveCodeBlocks !== false,
      extractFrontmatter: options.extractFrontmatter !== false,
      minHeadingLevel: options.minHeadingLevel || 1,
      maxHeadingLevel: options.maxHeadingLevel || 3,
      includeEmptyChunks: options.includeEmptyChunks === true,
      ...options
    };
  }

  /**
   * Load marked dependency
   * @returns {Object} - marked module
   */
  async loadDependency() {
    if (!marked) {
      try {
        const markedModule = require('marked');
        marked = markedModule.marked || markedModule;
      } catch (error) {
        throw new Error(
          'marked is not installed. Please run: npm install marked'
        );
      }
    }
    return marked;
  }

  /**
   * Parse Markdown content
   * @param {string} content - Markdown content
   * @returns {Promise<Object>} - Parsed content with chunks, metadata
   */
  async parseMarkdown(content) {
    await this.loadDependency();

    if (typeof content !== 'string') {
      throw new Error('Content must be a string');
    }

    // Extract frontmatter
    const { frontmatter, body } = this.extractFrontmatter(content);

    // Parse into tokens
    const tokens = marked.lexer(body);

    // Extract chunks by heading
    const chunks = this.extractChunks(tokens);

    // Extract code blocks
    const codeBlocks = this.extractCodeBlocks(tokens);

    // Extract links
    const links = this.extractLinks(tokens);

    // Extract tables
    const tables = this.extractTables(tokens);

    // Build heading tree
    const headingTree = this.buildHeadingTree(tokens);

    return {
      chunks,
      frontmatter,
      codeBlocks,
      links,
      tables,
      headingTree,
      metadata: {
        title: frontmatter?.title || this.extractFirstHeading(tokens),
        wordCount: this.countWords(body),
        charCount: body.length,
        headingCount: chunks.length,
        codeBlockCount: codeBlocks.length,
        linkCount: links.length,
        tableCount: tables.length
      }
    };
  }

  /**
   * Parse Markdown from file
   * @param {string} filePath - Path to Markdown file
   * @returns {Promise<Object>} - Parsed content
   */
  async parseFile(filePath) {
    const absolutePath = path.resolve(filePath);

    if (!fs.existsSync(absolutePath)) {
      throw new Error(`File not found: ${absolutePath}`);
    }

    const content = fs.readFileSync(absolutePath, 'utf-8');
    const result = await this.parseMarkdown(content);

    // Add file metadata
    const stats = fs.statSync(absolutePath);
    result.metadata.fileName = path.basename(absolutePath);
    result.metadata.filePath = absolutePath;
    result.metadata.fileSize = stats.size;
    result.metadata.modifiedAt = stats.mtime.toISOString();

    return result;
  }

  /**
   * Extract frontmatter from content
   * @param {string} content - Full content with potential frontmatter
   * @returns {Object} - { frontmatter, body }
   */
  extractFrontmatter(content) {
    if (!this.options.extractFrontmatter) {
      return { frontmatter: null, body: content };
    }

    // Match YAML frontmatter
    const match = content.match(/^---\s*\n([\s\S]*?)\n---\s*\n/);

    if (!match) {
      return { frontmatter: null, body: content };
    }

    const frontmatterStr = match[1];
    const body = content.slice(match[0].length);

    // Parse YAML-like frontmatter (simple key: value)
    const frontmatter = {};
    const lines = frontmatterStr.split('\n');

    for (const line of lines) {
      const colonIndex = line.indexOf(':');
      if (colonIndex > 0) {
        const key = line.slice(0, colonIndex).trim();
        let value = line.slice(colonIndex + 1).trim();

        // Remove quotes
        if ((value.startsWith('"') && value.endsWith('"')) ||
            (value.startsWith("'") && value.endsWith("'"))) {
          value = value.slice(1, -1);
        }

        // Parse arrays
        if (value.startsWith('[') && value.endsWith(']')) {
          try {
            value = JSON.parse(value);
          } catch {
            // Keep as string if parsing fails
          }
        }

        // Parse booleans and numbers
        if (value === 'true') value = true;
        else if (value === 'false') value = false;
        else if (!isNaN(value) && value !== '') value = Number(value);

        frontmatter[key] = value;
      }
    }

    return { frontmatter, body };
  }

  /**
   * Extract chunks organized by headings
   * @param {Array} tokens - Marked tokens
   * @returns {Array} - Chunks with heading hierarchy
   */
  extractChunks(tokens) {
    const chunks = [];
    let currentChunk = null;
    let currentContent = [];

    const flushChunk = () => {
      if (currentChunk) {
        const text = currentContent.join('\n').trim();
        if (text || this.options.includeEmptyChunks) {
          chunks.push({
            ...currentChunk,
            content: text,
            wordCount: this.countWords(text)
          });
        }
      }
      currentContent = [];
    };

    for (const token of tokens) {
      if (token.type === 'heading') {
        const level = token.depth;

        // Check if heading is within our range
        if (level >= this.options.minHeadingLevel && level <= this.options.maxHeadingLevel) {
          flushChunk();

          currentChunk = {
            heading: token.text,
            level,
            slug: this.slugify(token.text)
          };
        } else if (currentChunk) {
          // Include headings outside range as content
          currentContent.push(`${'#'.repeat(token.depth)} ${token.text}`);
        }
      } else if (currentChunk) {
        const text = this.tokenToText(token);
        if (text) {
          currentContent.push(text);
        }
      } else {
        // Content before first heading
        const text = this.tokenToText(token);
        if (text) {
          if (!currentChunk) {
            currentChunk = {
              heading: null,
              level: 0,
              slug: 'intro'
            };
          }
          currentContent.push(text);
        }
      }
    }

    // Flush final chunk
    flushChunk();

    return chunks;
  }

  /**
   * Convert token to plain text
   * @param {Object} token - Marked token
   * @returns {string} - Plain text
   */
  tokenToText(token) {
    switch (token.type) {
      case 'paragraph':
      case 'text':
        return token.text || token.raw;

      case 'code':
        if (this.options.preserveCodeBlocks) {
          const lang = token.lang ? ` ${token.lang}` : '';
          return `\`\`\`${lang}\n${token.text}\n\`\`\``;
        }
        return token.text;

      case 'blockquote':
        return token.text ? `> ${token.text}` : '';

      case 'list':
        return token.items?.map(item => `- ${item.text}`).join('\n') || '';

      case 'table':
        return this.tableTokenToText(token);

      case 'html':
        return token.text || '';

      case 'space':
        return '';

      default:
        return token.raw || token.text || '';
    }
  }

  /**
   * Convert table token to text
   * @param {Object} token - Table token
   * @returns {string} - Table as text
   */
  tableTokenToText(token) {
    if (!token.header || !token.rows) return '';

    const header = token.header.map(h => h.text).join(' | ');
    const separator = token.header.map(() => '---').join(' | ');
    const rows = token.rows.map(row =>
      row.map(cell => cell.text).join(' | ')
    ).join('\n');

    return `| ${header} |\n| ${separator} |\n| ${rows} |`;
  }

  /**
   * Extract code blocks from tokens
   * @param {Array} tokens - Marked tokens
   * @returns {Array} - Code blocks
   */
  extractCodeBlocks(tokens) {
    const codeBlocks = [];

    for (const token of tokens) {
      if (token.type === 'code') {
        codeBlocks.push({
          language: token.lang || null,
          code: token.text,
          lines: token.text.split('\n').length
        });
      }
    }

    return codeBlocks;
  }

  /**
   * Extract links from tokens
   * @param {Array} tokens - Marked tokens
   * @returns {Array} - Links
   */
  extractLinks(tokens) {
    const links = [];

    const extractFromToken = (token) => {
      if (token.type === 'link') {
        links.push({
          text: token.text,
          href: token.href,
          title: token.title || null
        });
      }

      // Recurse into nested tokens
      if (token.tokens) {
        for (const t of token.tokens) {
          extractFromToken(t);
        }
      }
    };

    for (const token of tokens) {
      extractFromToken(token);
    }

    // Also extract inline links via regex
    const tokenStr = JSON.stringify(tokens);
    const linkRegex = /\[([^\]]+)\]\(([^)]+)\)/g;
    let match;
    while ((match = linkRegex.exec(tokenStr)) !== null) {
      const existing = links.find(l => l.href === match[2]);
      if (!existing) {
        links.push({
          text: match[1],
          href: match[2],
          title: null
        });
      }
    }

    return links;
  }

  /**
   * Extract tables from tokens
   * @param {Array} tokens - Marked tokens
   * @returns {Array} - Tables
   */
  extractTables(tokens) {
    const tables = [];

    for (const token of tokens) {
      if (token.type === 'table') {
        tables.push({
          header: token.header?.map(h => h.text) || [],
          rows: token.rows?.map(row => row.map(cell => cell.text)) || [],
          align: token.align || []
        });
      }
    }

    return tables;
  }

  /**
   * Build heading tree structure
   * @param {Array} tokens - Marked tokens
   * @returns {Array} - Hierarchical heading tree
   */
  buildHeadingTree(tokens) {
    const tree = [];
    const stack = [{ children: tree, level: 0 }];

    for (const token of tokens) {
      if (token.type === 'heading') {
        const node = {
          text: token.text,
          level: token.depth,
          slug: this.slugify(token.text),
          children: []
        };

        // Find appropriate parent
        while (stack.length > 1 && stack[stack.length - 1].level >= token.depth) {
          stack.pop();
        }

        stack[stack.length - 1].children.push(node);
        stack.push(node);
      }
    }

    return tree;
  }

  /**
   * Extract first heading from tokens
   * @param {Array} tokens - Marked tokens
   * @returns {string|null} - First heading text
   */
  extractFirstHeading(tokens) {
    for (const token of tokens) {
      if (token.type === 'heading') {
        return token.text;
      }
    }
    return null;
  }

  /**
   * Create URL-friendly slug from text
   * @param {string} text - Text to slugify
   * @returns {string} - Slug
   */
  slugify(text) {
    return text
      .toLowerCase()
      .replace(/[^a-z0-9\s-]/g, '')
      .replace(/\s+/g, '-')
      .replace(/-+/g, '-')
      .replace(/^-|-$/g, '');
  }

  /**
   * Count words in text
   * @param {string} text - Text to count
   * @returns {number} - Word count
   */
  countWords(text) {
    if (!text) return 0;
    return text.split(/\s+/).filter(word => word.length > 0).length;
  }

  /**
   * Get parser info
   * @returns {Object} - Parser information
   */
  getInfo() {
    return {
      name: 'MarkdownParser',
      version: '1.0.0',
      supportedTypes: ['text/markdown', '.md', '.markdown'],
      options: this.options
    };
  }
}

/**
 * Factory function to create Markdown parser
 * @param {Object} options - Parser options
 * @returns {MarkdownParser} - Parser instance
 */
function createMarkdownParser(options = {}) {
  return new MarkdownParser(options);
}

/**
 * Convenience function to parse Markdown content
 * @param {string} content - Markdown content
 * @param {Object} options - Parser options
 * @returns {Promise<Object>} - Parsed content
 */
async function parseMarkdown(content, options = {}) {
  const parser = new MarkdownParser(options);
  return parser.parseMarkdown(content);
}

module.exports = {
  MarkdownParser,
  createMarkdownParser,
  parseMarkdown
};
