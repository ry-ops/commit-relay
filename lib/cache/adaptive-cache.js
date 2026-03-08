#!/usr/bin/env node
// lib/cache/adaptive-cache.js
// Adaptive Caching System
// Part of Enhancement Phase: Adaptive Caching
//
// Responsibilities:
// - Intelligent cache management
// - Adaptive TTL based on access patterns
// - Cache warming and prefetching
// - Memory-efficient LRU eviction

const fs = require('fs').promises;
const path = require('path');
const crypto = require('crypto');

class AdaptiveCache {
  constructor(options = {}) {
    this.maxSize = options.maxSize || 1000;
    this.defaultTTL = options.defaultTTL || 3600000; // 1 hour
    this.cachePath = options.cachePath || 'coordination/cache';
    
    // In-memory cache
    this.cache = new Map();
    
    // Access patterns
    this.accessPatterns = new Map();
    
    // Statistics
    this.stats = {
      hits: 0,
      misses: 0,
      evictions: 0,
      warming_operations: 0
    };
  }

  /**
   * Initialize adaptive cache
   */
  async initialize() {
    try {
      await fs.mkdir(this.cachePath, { recursive: true });
      
      // Load persistent cache
      await this._loadPersistentCache();
      
      console.log('Adaptive Cache initialized');
      console.log(`Max size: ${this.maxSize}, Default TTL: ${this.defaultTTL}ms`);
      
      return true;
    } catch (error) {
      console.error('Failed to initialize Adaptive Cache:', error.message);
      return false;
    }
  }

  /**
   * Get value from cache
   */
  async get(key) {
    const entry = this.cache.get(key);

    if (!entry) {
      this.stats.misses++;
      this._recordAccess(key, false);
      return null;
    }

    // Check expiration
    if (Date.now() > entry.expiresAt) {
      this.cache.delete(key);
      this.stats.misses++;
      this._recordAccess(key, false);
      return null;
    }

    // Update access time
    entry.lastAccess = Date.now();
    entry.accessCount++;

    this.stats.hits++;
    this._recordAccess(key, true);

    // Adapt TTL based on access pattern
    await this._adaptTTL(key);

    return entry.value;
  }

  /**
   * Set value in cache
   */
  async set(key, value, options = {}) {
    const ttl = options.ttl || this.defaultTTL;

    // Evict if cache is full
    if (this.cache.size >= this.maxSize) {
      await this._evictLRU();
    }

    const entry = {
      key: key,
      value: value,
      createdAt: Date.now(),
      expiresAt: Date.now() + ttl,
      lastAccess: Date.now(),
      accessCount: 0,
      ttl: ttl
    };

    this.cache.set(key, entry);

    // Persist to disk if needed
    if (options.persist) {
      await this._persistEntry(key, entry);
    }

    return true;
  }

  /**
   * Delete from cache
   */
  async delete(key) {
    const deleted = this.cache.delete(key);

    // Remove from persistent storage
    try {
      const entryPath = path.join(this.cachePath, `${this._hashKey(key)}.json`);
      await fs.unlink(entryPath);
    } catch (error) {
      // Ignore if not found
    }

    return deleted;
  }

  /**
   * Warm cache with frequently accessed data
   */
  async warmCache(dataLoader, keys = []) {
    let warmed = 0;

    for (const key of keys) {
      try {
        const value = await dataLoader(key);
        await this.set(key, value, { persist: true });
        warmed++;
      } catch (error) {
        console.error(`Failed to warm cache for ${key}:`, error.message);
      }
    }

    this.stats.warming_operations++;

    console.log(`Warmed cache with ${warmed} entries`);

    return warmed;
  }

  /**
   * Prefetch based on access patterns
   */
  async prefetch(dataLoader) {
    // Analyze access patterns to identify frequently accessed keys
    const hotKeys = this._identifyHotKeys();

    let prefetched = 0;

    for (const key of hotKeys) {
      // Only prefetch if not already in cache
      if (!this.cache.has(key)) {
        try {
          const value = await dataLoader(key);
          await this.set(key, value);
          prefetched++;
        } catch (error) {
          console.error(`Failed to prefetch ${key}:`, error.message);
        }
      }
    }

    console.log(`Prefetched ${prefetched} entries`);

    return prefetched;
  }

  /**
   * Get cache statistics
   */
  getStatistics() {
    const hitRate = this.stats.hits + this.stats.misses > 0
      ? (this.stats.hits / (this.stats.hits + this.stats.misses)) * 100
      : 0;

    return {
      size: this.cache.size,
      max_size: this.maxSize,
      hits: this.stats.hits,
      misses: this.stats.misses,
      hit_rate: Math.round(hitRate * 100) / 100,
      evictions: this.stats.evictions,
      warming_operations: this.stats.warming_operations
    };
  }

  /**
   * Clear entire cache
   */
  async clear() {
    this.cache.clear();
    this.accessPatterns.clear();

    // Clear persistent cache
    try {
      const files = await fs.readdir(this.cachePath);
      for (const file of files) {
        await fs.unlink(path.join(this.cachePath, file));
      }
    } catch (error) {
      // Ignore
    }

    console.log('Cache cleared');
  }

  /**
   * Record access for pattern analysis
   */
  _recordAccess(key, hit) {
    if (!this.accessPatterns.has(key)) {
      this.accessPatterns.set(key, {
        hits: 0,
        misses: 0,
        lastAccess: Date.now()
      });
    }

    const pattern = this.accessPatterns.get(key);
    if (hit) {
      pattern.hits++;
    } else {
      pattern.misses++;
    }
    pattern.lastAccess = Date.now();
  }

  /**
   * Adapt TTL based on access patterns
   */
  async _adaptTTL(key) {
    const entry = this.cache.get(key);
    const pattern = this.accessPatterns.get(key);

    if (!entry || !pattern) return;

    // Frequently accessed items get longer TTL
    if (pattern.hits > 10) {
      const newTTL = Math.min(entry.ttl * 1.5, this.defaultTTL * 3);
      entry.expiresAt = Date.now() + newTTL;
      entry.ttl = newTTL;
    }
  }

  /**
   * Evict least recently used entry
   */
  async _evictLRU() {
    let lruKey = null;
    let lruTime = Infinity;

    for (const [key, entry] of this.cache.entries()) {
      if (entry.lastAccess < lruTime) {
        lruTime = entry.lastAccess;
        lruKey = key;
      }
    }

    if (lruKey) {
      this.cache.delete(lruKey);
      this.stats.evictions++;
      console.log(`Evicted LRU entry: ${lruKey}`);
    }
  }

  /**
   * Identify frequently accessed keys
   */
  _identifyHotKeys(threshold = 5) {
    const hotKeys = [];

    for (const [key, pattern] of this.accessPatterns.entries()) {
      if (pattern.hits >= threshold) {
        hotKeys.push(key);
      }
    }

    // Sort by hit count (descending)
    hotKeys.sort((a, b) => {
      const patternA = this.accessPatterns.get(a);
      const patternB = this.accessPatterns.get(b);
      return patternB.hits - patternA.hits;
    });

    return hotKeys.slice(0, 20); // Top 20 hot keys
  }

  /**
   * Persist cache entry to disk
   */
  async _persistEntry(key, entry) {
    const hash = this._hashKey(key);
    const entryPath = path.join(this.cachePath, `${hash}.json`);

    await fs.writeFile(entryPath, JSON.stringify({
      key: key,
      value: entry.value,
      expiresAt: entry.expiresAt
    }, null, 2));
  }

  /**
   * Load persistent cache from disk
   */
  async _loadPersistentCache() {
    try {
      const files = await fs.readdir(this.cachePath);

      for (const file of files) {
        const filePath = path.join(this.cachePath, file);
        const content = await fs.readFile(filePath, 'utf8');
        const data = JSON.parse(content);

        // Only load if not expired
        if (data.expiresAt > Date.now()) {
          await this.set(data.key, data.value, {
            ttl: data.expiresAt - Date.now()
          });
        } else {
          // Remove expired entry
          await fs.unlink(filePath);
        }
      }

      console.log(`Loaded ${this.cache.size} persistent cache entries`);
    } catch (error) {
      // No persistent cache yet
    }
  }

  /**
   * Hash key for filename
   */
  _hashKey(key) {
    return crypto.createHash('md5').update(key).digest('hex');
  }
}

// CLI interface
if (require.main === module) {
  const action = process.argv[2];
  const cache = new AdaptiveCache();

  (async () => {
    await cache.initialize();

    switch (action) {
      case 'stats':
        const stats = cache.getStatistics();
        console.log('\nCache Statistics:');
        console.log(JSON.stringify(stats, null, 2));
        break;

      case 'clear':
        await cache.clear();
        console.log('Cache cleared');
        break;

      default:
        console.log('Usage: node adaptive-cache.js <action>');
        console.log('Actions:');
        console.log('  stats   - Show cache statistics');
        console.log('  clear   - Clear cache');
        break;
    }
  })();
}

module.exports = AdaptiveCache;
