#!/usr/bin/env node
// lib/rag/parsers/chunker.js
// Text chunking utilities for RAG document processing
// Part of RAG Enhancement: Document Conversion

/**
 * TextChunker - Split large documents into manageable chunks
 *
 * Features:
 * - Configurable chunk size and overlap
 * - Sentence boundary detection
 * - Paragraph-aware chunking
 * - Metadata preservation
 */
class TextChunker {
  constructor(options = {}) {
    this.options = {
      chunkSize: options.chunkSize || 1000,
      chunkOverlap: options.chunkOverlap || 200,
      respectSentences: options.respectSentences !== false,
      respectParagraphs: options.respectParagraphs !== false,
      minChunkSize: options.minChunkSize || 100,
      maxChunkSize: options.maxChunkSize || 2000,
      separator: options.separator || '\n\n',
      ...options
    };

    // Validate options
    if (this.options.chunkOverlap >= this.options.chunkSize) {
      throw new Error('chunkOverlap must be less than chunkSize');
    }
  }

  /**
   * Chunk text into smaller pieces
   * @param {string} text - Text to chunk
   * @param {Object} options - Override default options
   * @returns {Array} - Array of chunk objects
   */
  chunkText(text, options = {}) {
    const opts = { ...this.options, ...options };

    if (!text || typeof text !== 'string') {
      return [];
    }

    // Clean and normalize text
    const cleanedText = this.normalizeText(text);

    if (cleanedText.length <= opts.chunkSize) {
      return [{
        content: cleanedText,
        index: 0,
        startChar: 0,
        endChar: cleanedText.length,
        wordCount: this.countWords(cleanedText)
      }];
    }

    // Choose chunking strategy based on options
    let chunks;
    if (opts.respectParagraphs) {
      chunks = this.chunkByParagraphs(cleanedText, opts);
    } else if (opts.respectSentences) {
      chunks = this.chunkBySentences(cleanedText, opts);
    } else {
      chunks = this.chunkByCharacters(cleanedText, opts);
    }

    return chunks;
  }

  /**
   * Chunk text respecting paragraph boundaries
   * @param {string} text - Text to chunk
   * @param {Object} opts - Chunking options
   * @returns {Array} - Chunks
   */
  chunkByParagraphs(text, opts) {
    const paragraphs = text.split(/\n\s*\n/).filter(p => p.trim());
    const chunks = [];
    let currentChunk = [];
    let currentLength = 0;
    let startChar = 0;
    let textPosition = 0;

    for (const paragraph of paragraphs) {
      const paragraphLength = paragraph.length;

      // If single paragraph exceeds max size, split it
      if (paragraphLength > opts.maxChunkSize) {
        // Flush current chunk first
        if (currentChunk.length > 0) {
          const content = currentChunk.join('\n\n');
          chunks.push({
            content,
            index: chunks.length,
            startChar,
            endChar: startChar + content.length,
            wordCount: this.countWords(content)
          });
          startChar += content.length + 2;
          currentChunk = [];
          currentLength = 0;
        }

        // Split large paragraph by sentences
        const sentenceChunks = this.chunkBySentences(paragraph, opts);
        for (const chunk of sentenceChunks) {
          chunk.index = chunks.length;
          chunk.startChar = textPosition + chunk.startChar;
          chunk.endChar = textPosition + chunk.endChar;
          chunks.push(chunk);
        }
        textPosition += paragraphLength + 2;
        startChar = textPosition;
        continue;
      }

      // Check if adding paragraph exceeds chunk size
      if (currentLength + paragraphLength > opts.chunkSize && currentChunk.length > 0) {
        const content = currentChunk.join('\n\n');
        chunks.push({
          content,
          index: chunks.length,
          startChar,
          endChar: startChar + content.length,
          wordCount: this.countWords(content)
        });

        // Calculate overlap
        if (opts.chunkOverlap > 0) {
          const overlap = this.getOverlapFromEnd(currentChunk.join('\n\n'), opts.chunkOverlap);
          currentChunk = overlap ? [overlap] : [];
          currentLength = overlap ? overlap.length : 0;
          startChar = textPosition - currentLength;
        } else {
          currentChunk = [];
          currentLength = 0;
          startChar = textPosition;
        }
      }

      currentChunk.push(paragraph);
      currentLength += paragraphLength + 2; // +2 for paragraph separator
      textPosition += paragraphLength + 2;
    }

    // Flush remaining content
    if (currentChunk.length > 0) {
      const content = currentChunk.join('\n\n');
      if (content.trim().length >= opts.minChunkSize) {
        chunks.push({
          content,
          index: chunks.length,
          startChar,
          endChar: startChar + content.length,
          wordCount: this.countWords(content)
        });
      } else if (chunks.length > 0) {
        // Merge small final chunk with previous
        const lastChunk = chunks[chunks.length - 1];
        lastChunk.content += '\n\n' + content;
        lastChunk.endChar = startChar + content.length;
        lastChunk.wordCount = this.countWords(lastChunk.content);
      }
    }

    return chunks;
  }

  /**
   * Chunk text respecting sentence boundaries
   * @param {string} text - Text to chunk
   * @param {Object} opts - Chunking options
   * @returns {Array} - Chunks
   */
  chunkBySentences(text, opts) {
    const sentences = this.splitIntoSentences(text);
    const chunks = [];
    let currentChunk = [];
    let currentLength = 0;
    let startChar = 0;
    let textPosition = 0;

    for (const sentence of sentences) {
      const sentenceLength = sentence.length;

      // If single sentence exceeds max size, split by characters
      if (sentenceLength > opts.maxChunkSize) {
        // Flush current chunk first
        if (currentChunk.length > 0) {
          const content = currentChunk.join(' ');
          chunks.push({
            content,
            index: chunks.length,
            startChar,
            endChar: startChar + content.length,
            wordCount: this.countWords(content)
          });
          startChar = textPosition;
          currentChunk = [];
          currentLength = 0;
        }

        // Split by characters
        const charChunks = this.chunkByCharacters(sentence, opts);
        for (const chunk of charChunks) {
          chunk.index = chunks.length;
          chunk.startChar = textPosition + chunk.startChar;
          chunk.endChar = textPosition + chunk.endChar;
          chunks.push(chunk);
        }
        textPosition += sentenceLength + 1;
        startChar = textPosition;
        continue;
      }

      // Check if adding sentence exceeds chunk size
      if (currentLength + sentenceLength > opts.chunkSize && currentChunk.length > 0) {
        const content = currentChunk.join(' ');
        chunks.push({
          content,
          index: chunks.length,
          startChar,
          endChar: startChar + content.length,
          wordCount: this.countWords(content)
        });

        // Calculate overlap
        if (opts.chunkOverlap > 0) {
          const overlap = this.getOverlapSentences(currentChunk, opts.chunkOverlap);
          currentChunk = overlap;
          currentLength = overlap.join(' ').length;
          startChar = textPosition - currentLength;
        } else {
          currentChunk = [];
          currentLength = 0;
          startChar = textPosition;
        }
      }

      currentChunk.push(sentence);
      currentLength += sentenceLength + 1; // +1 for space
      textPosition += sentenceLength + 1;
    }

    // Flush remaining content
    if (currentChunk.length > 0) {
      const content = currentChunk.join(' ');
      if (content.trim().length >= opts.minChunkSize) {
        chunks.push({
          content,
          index: chunks.length,
          startChar,
          endChar: startChar + content.length,
          wordCount: this.countWords(content)
        });
      } else if (chunks.length > 0) {
        // Merge small final chunk with previous
        const lastChunk = chunks[chunks.length - 1];
        lastChunk.content += ' ' + content;
        lastChunk.endChar = startChar + content.length;
        lastChunk.wordCount = this.countWords(lastChunk.content);
      }
    }

    return chunks;
  }

  /**
   * Chunk text by character count (simple splitting)
   * @param {string} text - Text to chunk
   * @param {Object} opts - Chunking options
   * @returns {Array} - Chunks
   */
  chunkByCharacters(text, opts) {
    const chunks = [];
    let start = 0;

    while (start < text.length) {
      let end = Math.min(start + opts.chunkSize, text.length);

      // Try to break at word boundary
      if (end < text.length) {
        const lastSpace = text.lastIndexOf(' ', end);
        if (lastSpace > start + opts.minChunkSize) {
          end = lastSpace;
        }
      }

      const content = text.slice(start, end).trim();

      if (content.length > 0) {
        chunks.push({
          content,
          index: chunks.length,
          startChar: start,
          endChar: end,
          wordCount: this.countWords(content)
        });
      }

      // Move start with overlap
      start = end - opts.chunkOverlap;
      if (start <= chunks[chunks.length - 1]?.startChar) {
        start = end; // Prevent infinite loop
      }
    }

    return chunks;
  }

  /**
   * Split text into sentences
   * @param {string} text - Text to split
   * @returns {Array} - Sentences
   */
  splitIntoSentences(text) {
    // Split on sentence-ending punctuation followed by space or newline
    const sentenceRegex = /(?<=[.!?])\s+(?=[A-Z])|(?<=[.!?])$/g;

    const sentences = text
      .split(sentenceRegex)
      .map(s => s.trim())
      .filter(s => s.length > 0);

    // Handle case where regex didn't split anything
    if (sentences.length === 1 && text.length > this.options.chunkSize) {
      // Fall back to splitting on periods
      return text
        .split(/(?<=[.!?])\s+/)
        .map(s => s.trim())
        .filter(s => s.length > 0);
    }

    return sentences;
  }

  /**
   * Get overlap from end of text
   * @param {string} text - Text to get overlap from
   * @param {number} overlapSize - Target overlap size
   * @returns {string} - Overlap text
   */
  getOverlapFromEnd(text, overlapSize) {
    if (text.length <= overlapSize) {
      return text;
    }

    const start = text.length - overlapSize;
    // Try to start at word boundary
    const firstSpace = text.indexOf(' ', start);
    if (firstSpace > start && firstSpace < text.length) {
      return text.slice(firstSpace + 1);
    }

    return text.slice(start);
  }

  /**
   * Get overlap sentences from array
   * @param {Array} sentences - Array of sentences
   * @param {number} overlapSize - Target overlap size
   * @returns {Array} - Overlap sentences
   */
  getOverlapSentences(sentences, overlapSize) {
    const overlap = [];
    let length = 0;

    for (let i = sentences.length - 1; i >= 0; i--) {
      if (length + sentences[i].length > overlapSize && overlap.length > 0) {
        break;
      }
      overlap.unshift(sentences[i]);
      length += sentences[i].length + 1;
    }

    return overlap;
  }

  /**
   * Normalize text (clean whitespace, etc.)
   * @param {string} text - Text to normalize
   * @returns {string} - Normalized text
   */
  normalizeText(text) {
    return text
      .replace(/\r\n/g, '\n')
      .replace(/\r/g, '\n')
      .replace(/\t/g, ' ')
      .replace(/ +/g, ' ')
      .replace(/\n{3,}/g, '\n\n')
      .trim();
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
   * Estimate tokens (rough approximation)
   * @param {string} text - Text to estimate
   * @returns {number} - Estimated token count
   */
  estimateTokens(text) {
    // Rough estimate: 1 token ~= 4 characters
    return Math.ceil(text.length / 4);
  }

  /**
   * Get chunker info
   * @returns {Object} - Chunker information
   */
  getInfo() {
    return {
      name: 'TextChunker',
      version: '1.0.0',
      options: this.options
    };
  }
}

/**
 * Factory function to create text chunker
 * @param {Object} options - Chunker options
 * @returns {TextChunker} - Chunker instance
 */
function createChunker(options = {}) {
  return new TextChunker(options);
}

/**
 * Convenience function to chunk text
 * @param {string} text - Text to chunk
 * @param {Object} options - Chunker options
 * @returns {Array} - Chunks
 */
function chunkText(text, options = {}) {
  const chunker = new TextChunker(options);
  return chunker.chunkText(text);
}

module.exports = {
  TextChunker,
  createChunker,
  chunkText
};
