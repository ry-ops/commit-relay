#!/usr/bin/env node
// lib/rag/parsers/index.js
// Parser factory and unified interface
// Part of RAG Enhancement: Document Conversion

const path = require('path');
const fs = require('fs');
const { PDFParser, createPDFParser, parsePDF } = require('./pdf-parser');
const { MarkdownParser, createMarkdownParser, parseMarkdown } = require('./markdown-parser');
const { TextChunker, createChunker, chunkText } = require('./chunker');

/**
 * ParserFactory - Create appropriate parser based on file type
 *
 * Features:
 * - Auto-detect file type from extension or MIME type
 * - Unified parse interface
 * - Support for custom parsers
 */
class ParserFactory {
  constructor() {
    // Registry of parsers by type
    this.parsers = new Map();

    // Register default parsers
    this.registerParser('pdf', PDFParser);
    this.registerParser('markdown', MarkdownParser);
    this.registerParser('md', MarkdownParser);

    // Extension to type mapping
    this.extensionMap = {
      '.pdf': 'pdf',
      '.md': 'markdown',
      '.markdown': 'markdown',
      '.txt': 'text'
    };

    // MIME type to type mapping
    this.mimeMap = {
      'application/pdf': 'pdf',
      'text/markdown': 'markdown',
      'text/plain': 'text',
      'text/x-markdown': 'markdown'
    };
  }

  /**
   * Register a custom parser
   * @param {string} type - Parser type identifier
   * @param {Function} ParserClass - Parser class constructor
   */
  registerParser(type, ParserClass) {
    this.parsers.set(type.toLowerCase(), ParserClass);
  }

  /**
   * Create parser instance by type
   * @param {string} type - Parser type
   * @param {Object} options - Parser options
   * @returns {Object} - Parser instance
   */
  createParser(type, options = {}) {
    const normalizedType = type.toLowerCase();

    // Handle extension format
    if (normalizedType.startsWith('.')) {
      const mappedType = this.extensionMap[normalizedType];
      if (mappedType) {
        return this.createParser(mappedType, options);
      }
    }

    const ParserClass = this.parsers.get(normalizedType);

    if (!ParserClass) {
      throw new Error(`No parser registered for type: ${type}`);
    }

    return new ParserClass(options);
  }

  /**
   * Detect parser type from file path
   * @param {string} filePath - File path
   * @returns {string} - Parser type
   */
  detectType(filePath) {
    const ext = path.extname(filePath).toLowerCase();
    const type = this.extensionMap[ext];

    if (!type) {
      throw new Error(`Unknown file type: ${ext}`);
    }

    return type;
  }

  /**
   * Detect parser type from MIME type
   * @param {string} mimeType - MIME type
   * @returns {string} - Parser type
   */
  detectTypeFromMime(mimeType) {
    const type = this.mimeMap[mimeType.toLowerCase()];

    if (!type) {
      throw new Error(`Unknown MIME type: ${mimeType}`);
    }

    return type;
  }

  /**
   * Get list of supported types
   * @returns {Array} - Supported parser types
   */
  getSupportedTypes() {
    return Array.from(this.parsers.keys());
  }

  /**
   * Get supported extensions
   * @returns {Array} - Supported file extensions
   */
  getSupportedExtensions() {
    return Object.keys(this.extensionMap);
  }

  /**
   * Check if type is supported
   * @param {string} type - Type to check
   * @returns {boolean} - Whether type is supported
   */
  isSupported(type) {
    return this.parsers.has(type.toLowerCase()) ||
           this.extensionMap.hasOwnProperty(type.toLowerCase());
  }
}

/**
 * UnifiedParser - Parse any supported document type
 *
 * Provides a single interface for parsing different document types
 */
class UnifiedParser {
  constructor(options = {}) {
    this.factory = new ParserFactory();
    this.chunker = new TextChunker(options.chunker || {});
    this.options = {
      autoChunk: options.autoChunk !== false,
      chunkOptions: options.chunkOptions || {},
      ...options
    };
  }

  /**
   * Parse document from buffer
   * @param {Buffer|string} content - Document content
   * @param {Object} options - Parse options
   * @returns {Promise<Object>} - Parsed document
   */
  async parse(content, options = {}) {
    const type = options.type;

    if (!type) {
      throw new Error('Document type must be specified');
    }

    const parser = this.factory.createParser(type, options.parserOptions);

    let result;
    if (Buffer.isBuffer(content)) {
      if (type === 'pdf') {
        result = await parser.parsePDF(content);
      } else {
        result = await parser.parseMarkdown(content.toString('utf-8'));
      }
    } else {
      if (type === 'pdf') {
        throw new Error('PDF content must be a Buffer');
      }
      result = await parser.parseMarkdown(content);
    }

    // Auto-chunk if enabled
    if (this.options.autoChunk && result.text) {
      const chunkOpts = { ...this.options.chunkOptions, ...options.chunkOptions };
      result.chunks = this.chunker.chunkText(result.text, chunkOpts);
    } else if (this.options.autoChunk && result.chunks) {
      // Already chunked by heading - optionally re-chunk large sections
      const rechunked = [];
      const chunkOpts = { ...this.options.chunkOptions, ...options.chunkOptions };

      for (const chunk of result.chunks) {
        if (chunk.content.length > (chunkOpts.maxChunkSize || 2000)) {
          const subChunks = this.chunker.chunkText(chunk.content, chunkOpts);
          for (const subChunk of subChunks) {
            rechunked.push({
              ...subChunk,
              heading: chunk.heading,
              headingLevel: chunk.level,
              parentSlug: chunk.slug
            });
          }
        } else {
          rechunked.push(chunk);
        }
      }

      result.chunks = rechunked;
    }

    return result;
  }

  /**
   * Parse document from file
   * @param {string} filePath - File path
   * @param {Object} options - Parse options
   * @returns {Promise<Object>} - Parsed document
   */
  async parseFile(filePath, options = {}) {
    const absolutePath = path.resolve(filePath);

    if (!fs.existsSync(absolutePath)) {
      throw new Error(`File not found: ${absolutePath}`);
    }

    // Auto-detect type from extension
    const type = options.type || this.factory.detectType(absolutePath);
    const parser = this.factory.createParser(type, options.parserOptions);

    let result = await parser.parseFile(absolutePath);

    // Auto-chunk if enabled
    if (this.options.autoChunk && result.text) {
      const chunkOpts = { ...this.options.chunkOptions, ...options.chunkOptions };
      result.chunks = this.chunker.chunkText(result.text, chunkOpts);
    } else if (this.options.autoChunk && result.chunks && result.chunks.length > 0) {
      // Re-chunk large sections
      const rechunked = [];
      const chunkOpts = { ...this.options.chunkOptions, ...options.chunkOptions };

      for (const chunk of result.chunks) {
        if (chunk.content && chunk.content.length > (chunkOpts.maxChunkSize || 2000)) {
          const subChunks = this.chunker.chunkText(chunk.content, chunkOpts);
          for (const subChunk of subChunks) {
            rechunked.push({
              ...subChunk,
              heading: chunk.heading,
              headingLevel: chunk.level,
              parentSlug: chunk.slug
            });
          }
        } else {
          rechunked.push(chunk);
        }
      }

      result.chunks = rechunked;
    }

    return result;
  }

  /**
   * Parse multiple files
   * @param {Array} filePaths - Array of file paths
   * @param {Object} options - Parse options
   * @returns {Promise<Array>} - Array of parsed documents
   */
  async parseFiles(filePaths, options = {}) {
    const results = [];

    for (const filePath of filePaths) {
      try {
        const result = await this.parseFile(filePath, options);
        results.push({
          filePath,
          success: true,
          result
        });
      } catch (error) {
        results.push({
          filePath,
          success: false,
          error: error.message
        });
      }
    }

    return results;
  }

  /**
   * Get supported types
   * @returns {Array} - Supported types
   */
  getSupportedTypes() {
    return this.factory.getSupportedTypes();
  }

  /**
   * Get supported extensions
   * @returns {Array} - Supported extensions
   */
  getSupportedExtensions() {
    return this.factory.getSupportedExtensions();
  }

  /**
   * Check if type/extension is supported
   * @param {string} typeOrExt - Type or extension
   * @returns {boolean} - Whether supported
   */
  isSupported(typeOrExt) {
    return this.factory.isSupported(typeOrExt);
  }

  /**
   * Get parser info
   * @returns {Object} - Parser information
   */
  getInfo() {
    return {
      name: 'UnifiedParser',
      version: '1.0.0',
      supportedTypes: this.getSupportedTypes(),
      supportedExtensions: this.getSupportedExtensions(),
      autoChunk: this.options.autoChunk,
      chunkOptions: this.options.chunkOptions
    };
  }
}

/**
 * Factory function to create parser
 * @param {string} type - Parser type
 * @param {Object} options - Parser options
 * @returns {Object} - Parser instance
 */
function createParser(type, options = {}) {
  const factory = new ParserFactory();
  return factory.createParser(type, options);
}

/**
 * Create unified parser
 * @param {Object} options - Parser options
 * @returns {UnifiedParser} - Unified parser instance
 */
function createUnifiedParser(options = {}) {
  return new UnifiedParser(options);
}

// Export all components
module.exports = {
  // Classes
  ParserFactory,
  UnifiedParser,
  PDFParser,
  MarkdownParser,
  TextChunker,

  // Factory functions
  createParser,
  createUnifiedParser,
  createPDFParser,
  createMarkdownParser,
  createChunker,

  // Convenience functions
  parsePDF,
  parseMarkdown,
  chunkText
};
