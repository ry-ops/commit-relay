/**
 * Data Filter
 *
 * Row and column level security for sensitive data.
 * Filters data based on principal's permissions and asset sensitivity.
 *
 * Features:
 * - Row-level filtering (filter entire records)
 * - Column-level filtering (redact sensitive fields)
 * - PII detection and masking
 * - Performance-optimized for large datasets
 */

const AccessControl = require('./access-control');
const CatalogManager = require('./catalog-manager');

class DataFilter {
  constructor(options = {}) {
    this.accessControl = new AccessControl(options);
    this.catalogManager = null;

    // Sensitive field patterns
    this.sensitivePatterns = [
      /password/i,
      /secret/i,
      /api[_-]?key/i,
      /token/i,
      /credential/i,
      /auth/i,
      /ssn/i,
      /social[_-]?security/i,
      /credit[_-]?card/i,
      /email/i,
      /phone/i,
      /address/i
    ];
  }

  /**
   * Initialize the data filter
   */
  async initialize() {
    await this.accessControl.initialize();
    this.catalogManager = this.accessControl.catalogManager;
    console.log('[DataFilter] Initialized successfully');
  }

  /**
   * Filter sensitive fields from data based on principal's permissions
   *
   * @param {Object|Array} data - Data to filter (object or array of objects)
   * @param {string} principal - Principal identifier
   * @returns {Object|Array} Filtered data
   */
  async filterSensitiveFields(data, principal) {
    if (!this.catalogManager) {
      await this.initialize();
    }

    // Handle arrays
    if (Array.isArray(data)) {
      return Promise.all(data.map(item => this._filterObject(item, principal)));
    }

    // Handle single object
    return this._filterObject(data, principal);
  }

  /**
   * Filter rows based on principal's access level
   *
   * @param {Array} rows - Array of data rows
   * @param {string} principal - Principal identifier
   * @param {Object} filterCriteria - Filtering criteria
   * @returns {Array} Filtered rows
   */
  async filterRows(rows, principal, filterCriteria = {}) {
    if (!this.catalogManager) {
      await this.initialize();
    }

    const role = this.accessControl.getPrincipalRole(principal);
    if (!role) {
      throw new Error(`No role assigned to principal: ${principal}`);
    }

    // System admin sees all rows
    if (role.role_id === 'system-admin') {
      return rows;
    }

    const filtered = [];

    for (const row of rows) {
      // Check if principal can access this row
      const canAccess = await this._canAccessRow(row, principal, role, filterCriteria);
      if (canAccess) {
        filtered.push(row);
      }
    }

    return filtered;
  }

  /**
   * Mask PII data in a string
   *
   * @param {string} value - Value to mask
   * @param {string} maskType - Type of masking (partial, full, hash)
   * @returns {string} Masked value
   */
  maskPII(value, maskType = 'partial') {
    if (typeof value !== 'string') {
      return value;
    }

    switch (maskType) {
      case 'full':
        return '[REDACTED]';

      case 'hash':
        const crypto = require('crypto');
        return crypto.createHash('sha256').update(value).digest('hex').substring(0, 8);

      case 'partial':
      default:
        // Show first and last 2 characters
        if (value.length <= 4) {
          return '****';
        }
        return value.substring(0, 2) + '****' + value.substring(value.length - 2);
    }
  }

  /**
   * Detect if a field contains PII
   *
   * @param {string} fieldName - Field name to check
   * @param {any} fieldValue - Field value to check
   * @returns {boolean} True if field likely contains PII
   */
  detectPII(fieldName, fieldValue) {
    // Check field name against patterns
    for (const pattern of this.sensitivePatterns) {
      if (pattern.test(fieldName)) {
        return true;
      }
    }

    // Check value patterns
    if (typeof fieldValue === 'string') {
      // Email pattern
      if (/^[^\s@]+@[^\s@]+\.[^\s@]+$/.test(fieldValue)) {
        return true;
      }

      // Phone pattern
      if (/^\+?[\d\s\-\(\)]{10,}$/.test(fieldValue)) {
        return true;
      }

      // SSN pattern
      if (/^\d{3}-\d{2}-\d{4}$/.test(fieldValue)) {
        return true;
      }

      // Credit card pattern
      if (/^\d{4}[\s\-]?\d{4}[\s\-]?\d{4}[\s\-]?\d{4}$/.test(fieldValue)) {
        return true;
      }
    }

    return false;
  }

  /**
   * Get filtered schema for an asset
   *
   * @param {string} assetId - Asset identifier
   * @param {string} principal - Principal identifier
   * @returns {Object} Filtered schema with allowed fields
   */
  async getFilteredSchema(assetId, principal) {
    if (!this.catalogManager) {
      await this.initialize();
    }

    const role = this.accessControl.getPrincipalRole(principal);
    if (!role) {
      throw new Error(`No role assigned to principal: ${principal}`);
    }

    // Get asset info
    const assetInfo = await this.catalogManager.metastore.assets[assetId];
    if (!assetInfo) {
      throw new Error(`Asset not found: ${assetId}`);
    }

    // System admin sees all fields
    if (role.role_id === 'system-admin') {
      return {
        asset_id: assetId,
        all_fields_visible: true,
        fields: []
      };
    }

    // Determine which fields are visible
    const schema = {
      asset_id: assetId,
      all_fields_visible: false,
      allowed_fields: [],
      redacted_fields: []
    };

    // For now, implement basic field filtering
    // In production, this would use asset metadata from catalog
    const commonFields = ['id', 'created_at', 'updated_at', 'status', 'type'];
    const sensitiveFields = ['password', 'secret', 'api_key', 'token', 'ssn', 'credit_card'];

    schema.allowed_fields = commonFields;

    if (role.role_id === 'observer') {
      schema.redacted_fields = [...sensitiveFields, 'write_access', 'modification_history'];
    } else {
      schema.redacted_fields = sensitiveFields;
    }

    return schema;
  }

  // ==================== PRIVATE METHODS ====================

  /**
   * Filter a single object based on principal's permissions
   */
  async _filterObject(obj, principal) {
    if (!obj || typeof obj !== 'object') {
      return obj;
    }

    const role = this.accessControl.getPrincipalRole(principal);
    if (!role) {
      throw new Error(`No role assigned to principal: ${principal}`);
    }

    // System admin sees everything
    if (role.role_id === 'system-admin') {
      return obj;
    }

    const filtered = { ...obj };

    // Filter sensitive fields
    for (const [key, value] of Object.entries(filtered)) {
      // Check if field is sensitive
      if (this._isSensitiveField(key)) {
        // Check if principal can access sensitive fields
        if (role.restrictions && role.restrictions.cannot_read) {
          if (role.restrictions.cannot_read.includes('pii_data')) {
            filtered[key] = this.maskPII(value);
            continue;
          }
        }
      }

      // Detect PII in value
      if (this.detectPII(key, value)) {
        filtered[key] = this.maskPII(value);
      }

      // Recursively filter nested objects
      if (typeof value === 'object' && value !== null) {
        if (Array.isArray(value)) {
          filtered[key] = await Promise.all(
            value.map(item => this._filterObject(item, principal))
          );
        } else {
          filtered[key] = await this._filterObject(value, principal);
        }
      }
    }

    return filtered;
  }

  /**
   * Check if field name is sensitive
   */
  _isSensitiveField(fieldName) {
    for (const pattern of this.sensitivePatterns) {
      if (pattern.test(fieldName)) {
        return true;
      }
    }
    return false;
  }

  /**
   * Check if principal can access a specific row
   */
  async _canAccessRow(row, principal, role, filterCriteria) {
    // System admin can access all rows
    if (role.role_id === 'system-admin') {
      return true;
    }

    // Check ownership filter
    if (filterCriteria.owner_only) {
      if (row.owner !== principal && row.created_by !== principal) {
        return false;
      }
    }

    // Check sensitivity filter
    if (filterCriteria.max_sensitivity) {
      const sensitivityLevels = ['public', 'internal', 'confidential', 'pii'];
      const rowLevel = sensitivityLevels.indexOf(row.sensitivity || 'internal');
      const maxLevel = sensitivityLevels.indexOf(filterCriteria.max_sensitivity);

      if (rowLevel > maxLevel) {
        return false;
      }
    }

    // Check if row contains PII and principal can't access PII
    if (row.sensitivity === 'pii') {
      if (role.restrictions && role.restrictions.cannot_read) {
        if (role.restrictions.cannot_read.includes('pii_data')) {
          return false;
        }
      }
    }

    return true;
  }
}

module.exports = DataFilter;
