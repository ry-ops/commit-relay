/**
 * Schema Validator Library
 *
 * Production-grade JSON schema validation for commit-relay coordination files.
 * Uses AJV (Another JSON Schema Validator) with format validation.
 *
 * Features:
 * - Strict schema validation with detailed error reporting
 * - Automatic repair for common errors
 * - Schema registry with lazy loading
 * - Support for JSONL files
 * - Validation history tracking
 */

const Ajv = require('ajv');
const addFormats = require('ajv-formats');
const fs = require('fs');
const path = require('path');

class SchemaValidator {
  constructor(options = {}) {
    this.schemasDir = options.schemasDir || path.join(__dirname, '../coordination/schemas');
    this.enableLogging = options.enableLogging !== false;
    this.maxRetries = options.maxRetries || 3;

    // Initialize AJV with strict mode
    this.ajv = new Ajv({
      allErrors: true,          // Report all errors, not just first
      verbose: true,            // Include schema and data in errors
      strict: true,             // Strict mode for production
      validateFormats: true,    // Validate format keywords
      allowUnionTypes: true     // Allow union types (oneOf, anyOf)
    });

    // Add format validators (date-time, uri, email, etc.)
    addFormats(this.ajv);

    // Schema cache
    this.schemas = {};
    this.validators = {};

    // Validation history
    this.validationHistory = [];

    this.log('SchemaValidator initialized');
  }

  /**
   * Load and compile a schema by name
   */
  loadSchema(schemaName) {
    if (this.validators[schemaName]) {
      return this.validators[schemaName];
    }

    const schemaPath = path.join(this.schemasDir, `${schemaName}.schema.json`);

    if (!fs.existsSync(schemaPath)) {
      throw new Error(`Schema not found: ${schemaPath}`);
    }

    try {
      const schemaContent = fs.readFileSync(schemaPath, 'utf8');
      const schema = JSON.parse(schemaContent);

      this.schemas[schemaName] = schema;
      this.validators[schemaName] = this.ajv.compile(schema);

      this.log(`Loaded schema: ${schemaName}`);
      return this.validators[schemaName];
    } catch (error) {
      throw new Error(`Failed to load schema ${schemaName}: ${error.message}`);
    }
  }

  /**
   * Validate data against a schema
   *
   * @param {object|array} data - Data to validate
   * @param {string} schemaName - Schema name (without .schema.json)
   * @returns {object} { valid: boolean, errors: array|null, data: object }
   */
  validate(data, schemaName) {
    const validator = this.loadSchema(schemaName);
    const valid = validator(data);

    const result = {
      valid,
      errors: valid ? null : this.formatErrors(validator.errors),
      data,
      schemaName,
      timestamp: new Date().toISOString()
    };

    // Track validation history
    this.validationHistory.push({
      schemaName,
      valid,
      errorCount: valid ? 0 : validator.errors.length,
      timestamp: result.timestamp
    });

    if (!valid) {
      this.log(`Validation failed for ${schemaName}:`, result.errors);
    }

    return result;
  }

  /**
   * Validate and attempt to repair data
   *
   * @param {object|array} data - Data to validate and repair
   * @param {string} schemaName - Schema name
   * @param {number} maxRetries - Maximum repair attempts
   * @returns {object} { valid: boolean, errors: array|null, data: object, repaired: boolean, repairs: array }
   */
  validateAndRepair(data, schemaName, maxRetries = null) {
    maxRetries = maxRetries || this.maxRetries;

    const repairs = [];
    let currentData = JSON.parse(JSON.stringify(data)); // Deep clone
    let attempt = 0;

    while (attempt < maxRetries) {
      const result = this.validate(currentData, schemaName);

      if (result.valid) {
        return {
          valid: true,
          errors: null,
          data: currentData,
          repaired: repairs.length > 0,
          repairs,
          attempts: attempt
        };
      }

      // Attempt repair
      const repairResult = this.attemptRepair(currentData, schemaName, result.errors);

      if (!repairResult.repaired) {
        // Cannot repair further
        return {
          valid: false,
          errors: result.errors,
          data: currentData,
          repaired: repairs.length > 0,
          repairs,
          attempts: attempt + 1
        };
      }

      currentData = repairResult.data;
      repairs.push(...repairResult.repairs);
      attempt++;
    }

    // Max retries reached
    const finalResult = this.validate(currentData, schemaName);
    return {
      valid: finalResult.valid,
      errors: finalResult.errors,
      data: currentData,
      repaired: repairs.length > 0,
      repairs,
      attempts: maxRetries,
      maxRetriesReached: true
    };
  }

  /**
   * Attempt to repair common validation errors
   */
  attemptRepair(data, schemaName, errors) {
    const repairs = [];
    let repaired = false;
    const repairedData = JSON.parse(JSON.stringify(data)); // Deep clone

    for (const error of errors) {
      const repair = this.repairError(repairedData, error);
      if (repair.success) {
        repairs.push(repair);
        repaired = true;
      }
    }

    return { repaired, data: repairedData, repairs };
  }

  /**
   * Repair a single validation error
   */
  repairError(data, error) {
    const { instancePath, keyword, message, params } = error;

    // Convert instancePath to property path (remove leading slash)
    const propertyPath = instancePath.slice(1).split('/');

    try {
      switch (keyword) {
        case 'required':
          // Add missing required property with default value
          return this.addMissingProperty(data, propertyPath, params.missingProperty);

        case 'type':
          // Fix type mismatch
          return this.fixTypeMismatch(data, propertyPath, params.type);

        case 'enum':
          // Fix enum value
          return this.fixEnumValue(data, propertyPath, params.allowedValues);

        case 'pattern':
          // Pattern mismatch (usually IDs) - attempt to fix format
          return this.fixPattern(data, propertyPath, params.pattern);

        case 'format':
          // Format validation failed (date-time, etc.)
          return this.fixFormat(data, propertyPath, params.format);

        case 'additionalProperties':
          // Remove additional properties
          return this.removeAdditionalProperties(data, propertyPath, params.additionalProperty);

        case 'minimum':
        case 'maximum':
          // Clamp values to min/max
          return this.clampValue(data, propertyPath, keyword, params.limit);

        default:
          return { success: false, error: `Cannot repair ${keyword} error` };
      }
    } catch (err) {
      return { success: false, error: err.message };
    }
  }

  /**
   * Add missing required property with sensible default
   */
  addMissingProperty(data, propertyPath, missingProperty) {
    const target = this.navigateToProperty(data, propertyPath);

    if (!target || typeof target !== 'object') {
      return { success: false, error: 'Cannot add property to non-object' };
    }

    // Determine default value based on property name
    const defaultValue = this.getDefaultValue(missingProperty);
    target[missingProperty] = defaultValue;

    return {
      success: true,
      action: 'added_missing_property',
      property: [...propertyPath, missingProperty].join('.'),
      value: defaultValue
    };
  }

  /**
   * Fix type mismatch
   */
  fixTypeMismatch(data, propertyPath, expectedType) {
    const target = this.navigateToProperty(data, propertyPath.slice(0, -1));
    const property = propertyPath[propertyPath.length - 1];

    if (!target) {
      return { success: false, error: 'Property not found' };
    }

    const currentValue = target[property];

    try {
      switch (expectedType) {
        case 'string':
          target[property] = String(currentValue);
          break;
        case 'number':
          target[property] = Number(currentValue);
          break;
        case 'integer':
          target[property] = parseInt(currentValue, 10);
          break;
        case 'boolean':
          target[property] = Boolean(currentValue);
          break;
        case 'array':
          target[property] = Array.isArray(currentValue) ? currentValue : [currentValue];
          break;
        case 'object':
          target[property] = typeof currentValue === 'object' ? currentValue : {};
          break;
        default:
          return { success: false, error: `Unknown type: ${expectedType}` };
      }

      return {
        success: true,
        action: 'fixed_type_mismatch',
        property: propertyPath.join('.'),
        from: typeof currentValue,
        to: expectedType
      };
    } catch (err) {
      return { success: false, error: err.message };
    }
  }

  /**
   * Fix enum value
   */
  fixEnumValue(data, propertyPath, allowedValues) {
    const target = this.navigateToProperty(data, propertyPath.slice(0, -1));
    const property = propertyPath[propertyPath.length - 1];

    if (!target) {
      return { success: false, error: 'Property not found' };
    }

    const currentValue = target[property];

    // Try to find closest match (case-insensitive)
    const match = allowedValues.find(v =>
      String(v).toLowerCase() === String(currentValue).toLowerCase()
    );

    if (match) {
      target[property] = match;
      return {
        success: true,
        action: 'fixed_enum_value',
        property: propertyPath.join('.'),
        from: currentValue,
        to: match
      };
    }

    // Use first allowed value as fallback
    target[property] = allowedValues[0];
    return {
      success: true,
      action: 'fixed_enum_value_fallback',
      property: propertyPath.join('.'),
      from: currentValue,
      to: allowedValues[0],
      warning: 'Used fallback value'
    };
  }

  /**
   * Fix pattern mismatch (best effort)
   */
  fixPattern(data, propertyPath, pattern) {
    // Most pattern mismatches are structural (IDs, etc.) and hard to auto-fix
    // Return failure to let caller handle manually
    return {
      success: false,
      error: 'Pattern mismatch requires manual fix',
      pattern
    };
  }

  /**
   * Fix format validation
   */
  fixFormat(data, propertyPath, format) {
    const target = this.navigateToProperty(data, propertyPath.slice(0, -1));
    const property = propertyPath[propertyPath.length - 1];

    if (!target) {
      return { success: false, error: 'Property not found' };
    }

    const currentValue = target[property];

    try {
      switch (format) {
        case 'date-time':
          // Try to parse and format as ISO 8601
          const date = new Date(currentValue);
          if (!isNaN(date.getTime())) {
            target[property] = date.toISOString();
            return {
              success: true,
              action: 'fixed_datetime_format',
              property: propertyPath.join('.'),
              from: currentValue,
              to: target[property]
            };
          }
          break;

        case 'uri':
        case 'url':
          // Basic URL format fix
          if (!currentValue.startsWith('http://') && !currentValue.startsWith('https://')) {
            target[property] = 'https://' + currentValue;
            return {
              success: true,
              action: 'fixed_uri_format',
              property: propertyPath.join('.'),
              from: currentValue,
              to: target[property]
            };
          }
          break;
      }
    } catch (err) {
      return { success: false, error: err.message };
    }

    return { success: false, error: `Cannot auto-fix format: ${format}` };
  }

  /**
   * Remove additional properties not in schema
   */
  removeAdditionalProperties(data, propertyPath, additionalProperty) {
    const target = this.navigateToProperty(data, propertyPath);

    if (!target || typeof target !== 'object') {
      return { success: false, error: 'Cannot remove property from non-object' };
    }

    delete target[additionalProperty];

    return {
      success: true,
      action: 'removed_additional_property',
      property: [...propertyPath, additionalProperty].join('.'),
      value: additionalProperty
    };
  }

  /**
   * Clamp value to min/max
   */
  clampValue(data, propertyPath, constraint, limit) {
    const target = this.navigateToProperty(data, propertyPath.slice(0, -1));
    const property = propertyPath[propertyPath.length - 1];

    if (!target) {
      return { success: false, error: 'Property not found' };
    }

    const currentValue = target[property];

    if (constraint === 'minimum') {
      target[property] = Math.max(currentValue, limit);
    } else if (constraint === 'maximum') {
      target[property] = Math.min(currentValue, limit);
    }

    return {
      success: true,
      action: 'clamped_value',
      property: propertyPath.join('.'),
      constraint,
      limit,
      from: currentValue,
      to: target[property]
    };
  }

  /**
   * Navigate to nested property in object
   */
  navigateToProperty(obj, path) {
    if (path.length === 0) return obj;

    let current = obj;
    for (const segment of path) {
      if (current === undefined || current === null) return null;
      current = current[segment];
    }
    return current;
  }

  /**
   * Get sensible default value for property
   */
  getDefaultValue(propertyName) {
    const name = propertyName.toLowerCase();

    // Timestamps
    if (name.includes('timestamp') || name.includes('_at') || name.includes('date')) {
      return new Date().toISOString();
    }

    // IDs
    if (name.includes('_id') || name === 'id') {
      return `generated-${Date.now()}`;
    }

    // Status/state
    if (name === 'status') return 'pending';
    if (name === 'state') return 'active';

    // Arrays
    if (name.includes('list') || name.includes('array') || name.includes('items')) {
      return [];
    }

    // Objects
    if (name.includes('context') || name.includes('metadata') || name.includes('config')) {
      return {};
    }

    // Numbers
    if (name.includes('count') || name.includes('total') || name.includes('number')) {
      return 0;
    }

    // Booleans
    if (name.startsWith('is_') || name.startsWith('has_') || name.startsWith('enable')) {
      return false;
    }

    // Default to empty string
    return '';
  }

  /**
   * Format AJV errors for better readability
   */
  formatErrors(errors) {
    return errors.map(error => ({
      path: error.instancePath || '/',
      keyword: error.keyword,
      message: error.message,
      params: error.params,
      schemaPath: error.schemaPath
    }));
  }

  /**
   * Get validation statistics
   */
  getStatistics() {
    const total = this.validationHistory.length;
    const valid = this.validationHistory.filter(v => v.valid).length;
    const invalid = total - valid;

    return {
      total,
      valid,
      invalid,
      successRate: total > 0 ? (valid / total) : 0,
      bySchema: this.getStatisticsBySchema()
    };
  }

  /**
   * Get statistics grouped by schema
   */
  getStatisticsBySchema() {
    const bySchema = {};

    for (const entry of this.validationHistory) {
      if (!bySchema[entry.schemaName]) {
        bySchema[entry.schemaName] = { total: 0, valid: 0, invalid: 0 };
      }
      bySchema[entry.schemaName].total++;
      if (entry.valid) {
        bySchema[entry.schemaName].valid++;
      } else {
        bySchema[entry.schemaName].invalid++;
      }
    }

    return bySchema;
  }

  /**
   * Log message (if logging enabled)
   */
  log(...args) {
    if (this.enableLogging) {
      console.log('[SchemaValidator]', ...args);
    }
  }
}

// Export singleton instance and class
const validator = new SchemaValidator();

module.exports = {
  SchemaValidator,
  validator,

  // Convenience methods
  validate: (data, schemaName) => validator.validate(data, schemaName),
  validateAndRepair: (data, schemaName, maxRetries) => validator.validateAndRepair(data, schemaName, maxRetries),
  getStatistics: () => validator.getStatistics()
};
