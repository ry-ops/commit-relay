#!/usr/bin/env node
// lib/rag/search/keyword-search.js
// Keyword Search using MiniSearch for BM25-style search
// Part of Hybrid Search Implementation for commit-relay RAG

const MiniSearch = require('minisearch');

class KeywordSearch {
  constructor(options = {}) {
    // Configure search fields
    this.fields = options.fields || ['content', 'title', 'tags'];
    this.storeFields = options.storeFields || ['content', 'title', 'tags', 'metadata'];

    // Search options
    this.searchOptions = {
      boost: options.boost || { title: 2, tags: 1.5, content: 1 },
      fuzzy: options.fuzzy !== undefined ? options.fuzzy : 0.2,
      prefix: options.prefix !== undefined ? options.prefix : true,
      combineWith: options.combineWith || 'OR'
    };

    // Collection-specific indices
    this.indices = new Map();

    // Document counter for ID generation
    this.docCounters = new Map();
  }

  /**
   * Get or create index for a collection
   * @param {string} collection - Collection name
   * @returns {MiniSearch} - MiniSearch instance
   */
  _getIndex(collection) {
    if (!this.indices.has(collection)) {
      const miniSearch = new MiniSearch({
        fields: this.fields,
        storeFields: this.storeFields,
        searchOptions: {
          boost: this.searchOptions.boost,
          fuzzy: this.searchOptions.fuzzy,
          prefix: this.searchOptions.prefix
        }
      });
      this.indices.set(collection, miniSearch);
      this.docCounters.set(collection, 0);
    }
    return this.indices.get(collection);
  }

  /**
   * Add documents to the keyword index
   * @param {string} collection - Collection name
   * @param {Array} documents - Array of documents to index
   * @returns {number} - Number of documents indexed
   */
  addDocuments(collection, documents) {
    const index = this._getIndex(collection);
    let counter = this.docCounters.get(collection) || 0;

    const docsToAdd = documents.map(doc => {
      // Ensure document has required fields
      const normalizedDoc = {
        id: doc.id || `${collection}-${++counter}`,
        content: doc.content || '',
        title: doc.title || doc.metadata?.title || '',
        tags: this._extractTags(doc),
        metadata: doc.metadata || {},
        _originalDoc: doc
      };
      return normalizedDoc;
    });

    this.docCounters.set(collection, counter);

    // Add documents to index
    for (const doc of docsToAdd) {
      try {
        // Remove existing document with same ID if it exists
        if (index.has(doc.id)) {
          index.discard(doc.id);
        }
        index.add(doc);
      } catch (error) {
        console.error(`Failed to index document ${doc.id}:`, error.message);
      }
    }

    return docsToAdd.length;
  }

  /**
   * Add a single document
   * @param {string} collection - Collection name
   * @param {Object} document - Document to index
   * @returns {string} - Document ID
   */
  addDocument(collection, document) {
    const index = this._getIndex(collection);
    let counter = this.docCounters.get(collection) || 0;

    const docId = document.id || `${collection}-${++counter}`;
    this.docCounters.set(collection, counter);

    const normalizedDoc = {
      id: docId,
      content: document.content || '',
      title: document.title || document.metadata?.title || '',
      tags: this._extractTags(document),
      metadata: document.metadata || {},
      _originalDoc: document
    };

    try {
      if (index.has(docId)) {
        index.discard(docId);
      }
      index.add(normalizedDoc);
    } catch (error) {
      console.error(`Failed to index document ${docId}:`, error.message);
    }

    return docId;
  }

  /**
   * Extract tags from document
   * @param {Object} doc - Document
   * @returns {string} - Tags as space-separated string
   */
  _extractTags(doc) {
    const tags = [];

    if (doc.tags) {
      if (Array.isArray(doc.tags)) {
        tags.push(...doc.tags);
      } else if (typeof doc.tags === 'string') {
        tags.push(doc.tags);
      }
    }

    // Extract tags from metadata
    if (doc.metadata) {
      if (doc.metadata.tags) {
        if (Array.isArray(doc.metadata.tags)) {
          tags.push(...doc.metadata.tags);
        } else {
          tags.push(doc.metadata.tags);
        }
      }

      // Add other useful metadata as tags
      if (doc.metadata.category) tags.push(doc.metadata.category);
      if (doc.metadata.type) tags.push(doc.metadata.type);
      if (doc.metadata.language) tags.push(doc.metadata.language);
    }

    return tags.join(' ');
  }

  /**
   * Search documents using keyword matching
   * @param {string} collection - Collection name
   * @param {string} query - Search query
   * @param {Object} options - Search options
   * @returns {Array} - Search results with scores
   */
  search(collection, query, options = {}) {
    const index = this._getIndex(collection);

    if (index.documentCount === 0) {
      return [];
    }

    const limit = options.limit || 10;
    const minScore = options.minScore || 0;

    // Build search options
    const searchOpts = {
      boost: options.boost || this.searchOptions.boost,
      fuzzy: options.fuzzy !== undefined ? options.fuzzy : this.searchOptions.fuzzy,
      prefix: options.prefix !== undefined ? options.prefix : this.searchOptions.prefix,
      combineWith: options.combineWith || this.searchOptions.combineWith
    };

    // Add filter if provided
    if (options.filter) {
      searchOpts.filter = (result) => {
        const doc = result;
        for (const [key, value] of Object.entries(options.filter)) {
          if (doc.metadata && doc.metadata[key] !== value) {
            return false;
          }
        }
        return true;
      };
    }

    try {
      const results = index.search(query, searchOpts);

      // Normalize scores and format results
      const maxScore = results.length > 0 ? results[0].score : 1;

      return results
        .filter(r => r.score >= minScore)
        .slice(0, limit)
        .map(r => ({
          id: r.id,
          content: r.content,
          title: r.title,
          tags: r.tags,
          metadata: r.metadata,
          score: r.score / maxScore, // Normalize to 0-1 range
          rawScore: r.score,
          match: r.match,
          terms: r.terms
        }));
    } catch (error) {
      console.error(`Keyword search failed in ${collection}:`, error.message);
      return [];
    }
  }

  /**
   * Search across multiple collections
   * @param {Array} collections - Collection names
   * @param {string} query - Search query
   * @param {Object} options - Search options
   * @returns {Array} - Combined search results
   */
  searchMultiple(collections, query, options = {}) {
    const allResults = [];
    const limit = options.limit || 10;

    for (const collection of collections) {
      const results = this.search(collection, query, {
        ...options,
        limit: limit * 2 // Get more results per collection, then limit globally
      });

      allResults.push(...results.map(r => ({
        ...r,
        collection
      })));
    }

    // Sort by score and apply global limit
    allResults.sort((a, b) => b.score - a.score);
    return allResults.slice(0, limit);
  }

  /**
   * Auto-suggest terms based on query prefix
   * @param {string} collection - Collection name
   * @param {string} query - Query prefix
   * @param {Object} options - Options
   * @returns {Array} - Suggested terms
   */
  suggest(collection, query, options = {}) {
    const index = this._getIndex(collection);
    const limit = options.limit || 5;

    try {
      return index.autoSuggest(query, {
        fuzzy: options.fuzzy !== undefined ? options.fuzzy : this.searchOptions.fuzzy
      }).slice(0, limit);
    } catch (error) {
      console.error(`Suggestion failed for ${collection}:`, error.message);
      return [];
    }
  }

  /**
   * Remove document from index
   * @param {string} collection - Collection name
   * @param {string} docId - Document ID
   * @returns {boolean} - Success
   */
  removeDocument(collection, docId) {
    const index = this._getIndex(collection);

    try {
      if (index.has(docId)) {
        index.discard(docId);
        return true;
      }
      return false;
    } catch (error) {
      console.error(`Failed to remove document ${docId}:`, error.message);
      return false;
    }
  }

  /**
   * Clear all documents from a collection
   * @param {string} collection - Collection name
   */
  clearCollection(collection) {
    // Create a new empty index for the collection
    const miniSearch = new MiniSearch({
      fields: this.fields,
      storeFields: this.storeFields,
      searchOptions: {
        boost: this.searchOptions.boost,
        fuzzy: this.searchOptions.fuzzy,
        prefix: this.searchOptions.prefix
      }
    });
    this.indices.set(collection, miniSearch);
    this.docCounters.set(collection, 0);
  }

  /**
   * Get index statistics
   * @param {string} collection - Collection name (optional)
   * @returns {Object} - Statistics
   */
  getStats(collection = null) {
    if (collection) {
      const index = this._getIndex(collection);
      return {
        collection,
        documentCount: index.documentCount,
        termCount: index.termCount
      };
    }

    const stats = {
      collections: {},
      totalDocuments: 0,
      totalTerms: 0
    };

    for (const [name, index] of this.indices) {
      stats.collections[name] = {
        documentCount: index.documentCount,
        termCount: index.termCount
      };
      stats.totalDocuments += index.documentCount;
      stats.totalTerms += index.termCount;
    }

    return stats;
  }

  /**
   * Export index for persistence
   * @param {string} collection - Collection name
   * @returns {Object} - Serialized index
   */
  exportIndex(collection) {
    const index = this._getIndex(collection);
    return JSON.stringify(index);
  }

  /**
   * Import index from serialized data
   * @param {string} collection - Collection name
   * @param {string} data - Serialized index data
   */
  importIndex(collection, data) {
    const miniSearch = MiniSearch.loadJSON(data, {
      fields: this.fields,
      storeFields: this.storeFields
    });
    this.indices.set(collection, miniSearch);
  }

  /**
   * Check if collection exists
   * @param {string} collection - Collection name
   * @returns {boolean}
   */
  hasCollection(collection) {
    return this.indices.has(collection);
  }

  /**
   * List all collections
   * @returns {Array} - Collection names
   */
  listCollections() {
    return Array.from(this.indices.keys());
  }
}

module.exports = KeywordSearch;
