#!/usr/bin/env node
// lib/rag/parsers/pdf-parser.js
// PDF document parser using pdf-parse
// Part of RAG Enhancement: Document Conversion

const fs = require('fs');
const path = require('path');

// Lazy load pdf-parse to handle missing dependency gracefully
let pdfParse = null;

/**
 * PDFParser - Parse PDF documents into structured text
 *
 * Features:
 * - Multi-page document support
 * - Metadata extraction
 * - Table detection (basic)
 * - Page-by-page text extraction
 */
class PDFParser {
  constructor(options = {}) {
    this.options = {
      maxPages: options.maxPages || 0, // 0 = all pages
      preserveFormatting: options.preserveFormatting !== false,
      extractTables: options.extractTables !== false,
      ...options
    };
  }

  /**
   * Load pdf-parse dependency
   * @returns {Function} - pdf-parse module
   */
  async loadDependency() {
    if (!pdfParse) {
      try {
        pdfParse = require('pdf-parse');
      } catch (error) {
        throw new Error(
          'pdf-parse is not installed. Please run: npm install pdf-parse'
        );
      }
    }
    return pdfParse;
  }

  /**
   * Parse PDF from buffer
   * @param {Buffer} buffer - PDF file buffer
   * @returns {Promise<Object>} - Parsed content with text, pages, and metadata
   */
  async parsePDF(buffer) {
    const pdf = await this.loadDependency();

    if (!Buffer.isBuffer(buffer)) {
      throw new Error('Input must be a Buffer');
    }

    const parseOptions = {
      max: this.options.maxPages || 0
    };

    // Custom page render function to extract page-by-page content
    const pageTexts = [];
    parseOptions.pagerender = async (pageData) => {
      const textContent = await pageData.getTextContent();
      const pageText = this.processTextContent(textContent);
      pageTexts.push(pageText);
      return pageText;
    };

    const data = await pdf(buffer, parseOptions);

    // Extract metadata
    const metadata = this.extractMetadata(data.info || {}, data.metadata);

    // Detect tables (basic heuristic)
    const tables = this.options.extractTables ? this.detectTables(data.text) : [];

    return {
      text: data.text,
      pages: pageTexts.length > 0 ? pageTexts : [data.text],
      pageCount: data.numpages,
      metadata: {
        ...metadata,
        pdfVersion: data.version,
        isEncrypted: data.info?.IsAcroFormPresent === true,
        producer: data.info?.Producer || null,
        creator: data.info?.Creator || null
      },
      tables,
      wordCount: this.countWords(data.text),
      charCount: data.text.length
    };
  }

  /**
   * Parse PDF from file path
   * @param {string} filePath - Path to PDF file
   * @returns {Promise<Object>} - Parsed content
   */
  async parseFile(filePath) {
    const absolutePath = path.resolve(filePath);

    if (!fs.existsSync(absolutePath)) {
      throw new Error(`File not found: ${absolutePath}`);
    }

    const buffer = fs.readFileSync(absolutePath);
    const result = await this.parsePDF(buffer);

    // Add file metadata
    const stats = fs.statSync(absolutePath);
    result.metadata.fileName = path.basename(absolutePath);
    result.metadata.filePath = absolutePath;
    result.metadata.fileSize = stats.size;
    result.metadata.modifiedAt = stats.mtime.toISOString();

    return result;
  }

  /**
   * Process text content from PDF.js
   * @param {Object} textContent - Text content from PDF.js
   * @returns {string} - Processed text
   */
  processTextContent(textContent) {
    if (!textContent || !textContent.items) {
      return '';
    }

    let text = '';
    let lastY = null;

    for (const item of textContent.items) {
      if (item.str) {
        // Add newline if Y position changes significantly
        if (lastY !== null && Math.abs(item.transform[5] - lastY) > 5) {
          text += '\n';
        }
        text += item.str;
        lastY = item.transform[5];
      }
    }

    return text.trim();
  }

  /**
   * Extract metadata from PDF info
   * @param {Object} info - PDF info object
   * @param {Object} metadata - PDF metadata object
   * @returns {Object} - Extracted metadata
   */
  extractMetadata(info, metadata) {
    const result = {
      title: null,
      author: null,
      subject: null,
      keywords: [],
      creationDate: null,
      modificationDate: null
    };

    // Extract from info
    if (info) {
      result.title = info.Title || null;
      result.author = info.Author || null;
      result.subject = info.Subject || null;

      if (info.Keywords) {
        result.keywords = info.Keywords.split(/[,;]/).map(k => k.trim()).filter(Boolean);
      }

      if (info.CreationDate) {
        result.creationDate = this.parsePDFDate(info.CreationDate);
      }

      if (info.ModDate) {
        result.modificationDate = this.parsePDFDate(info.ModDate);
      }
    }

    // Override with metadata if available
    if (metadata && metadata._metadata) {
      const meta = metadata._metadata;
      result.title = meta['dc:title'] || result.title;
      result.author = meta['dc:creator'] || result.author;
      result.subject = meta['dc:description'] || result.subject;
    }

    return result;
  }

  /**
   * Parse PDF date string
   * @param {string} dateStr - PDF date string (D:YYYYMMDDHHmmSS)
   * @returns {string|null} - ISO date string or null
   */
  parsePDFDate(dateStr) {
    if (!dateStr) return null;

    // Remove D: prefix if present
    const clean = dateStr.replace(/^D:/, '');

    // Parse PDF date format: YYYYMMDDHHmmSS
    const match = clean.match(/(\d{4})(\d{2})(\d{2})(\d{2})?(\d{2})?(\d{2})?/);
    if (!match) return null;

    const [, year, month, day, hour = '00', minute = '00', second = '00'] = match;

    try {
      const date = new Date(`${year}-${month}-${day}T${hour}:${minute}:${second}Z`);
      return date.toISOString();
    } catch {
      return null;
    }
  }

  /**
   * Detect tables in text (basic heuristic)
   * @param {string} text - Document text
   * @returns {Array} - Detected table regions
   */
  detectTables(text) {
    const tables = [];
    const lines = text.split('\n');

    let tableStart = -1;
    let tableLines = [];

    for (let i = 0; i < lines.length; i++) {
      const line = lines[i];

      // Heuristic: lines with multiple tabs or consistent spacing might be tables
      const hasMultipleTabs = (line.match(/\t/g) || []).length >= 2;
      const hasConsistentSpacing = (line.match(/\s{2,}/g) || []).length >= 2;

      if (hasMultipleTabs || hasConsistentSpacing) {
        if (tableStart === -1) {
          tableStart = i;
        }
        tableLines.push(line);
      } else {
        // End of potential table
        if (tableLines.length >= 3) {
          tables.push({
            startLine: tableStart,
            endLine: i - 1,
            lines: tableLines,
            text: tableLines.join('\n')
          });
        }
        tableStart = -1;
        tableLines = [];
      }
    }

    // Handle table at end of document
    if (tableLines.length >= 3) {
      tables.push({
        startLine: tableStart,
        endLine: lines.length - 1,
        lines: tableLines,
        text: tableLines.join('\n')
      });
    }

    return tables;
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
      name: 'PDFParser',
      version: '1.0.0',
      supportedTypes: ['application/pdf', '.pdf'],
      options: this.options
    };
  }
}

/**
 * Factory function to create PDF parser
 * @param {Object} options - Parser options
 * @returns {PDFParser} - Parser instance
 */
function createPDFParser(options = {}) {
  return new PDFParser(options);
}

/**
 * Convenience function to parse PDF buffer
 * @param {Buffer} buffer - PDF buffer
 * @param {Object} options - Parser options
 * @returns {Promise<Object>} - Parsed content
 */
async function parsePDF(buffer, options = {}) {
  const parser = new PDFParser(options);
  return parser.parsePDF(buffer);
}

module.exports = {
  PDFParser,
  createPDFParser,
  parsePDF
};
