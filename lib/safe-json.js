/**
 * Safe JSON Operations Library
 *
 * Provides safe read/write operations for JSON files with automatic schema validation.
 * Prevents corruption and ensures data integrity across the coordination system.
 *
 * Features:
 * - Schema validation on read and write
 * - Atomic writes with backup/rollback
 * - JSONL support for append-only logs
 * - Automatic repair attempts
 * - Detailed error reporting
 */

const fs = require('fs');
const path = require('path');
const { validator } = require('./schema-validator');

/**
 * Safe read JSON file with schema validation
 *
 * @param {string} filePath - Absolute path to JSON file
 * @param {string} schemaName - Schema to validate against (without .schema.json)
 * @param {object} options - Options { repair: boolean, createIfMissing: boolean }
 * @returns {object} { success: boolean, data: object|null, errors: array|null, repaired: boolean }
 */
function safeReadJSON(filePath, schemaName, options = {}) {
  const { repair = true, createIfMissing = false } = options;

  try {
    // Check if file exists
    if (!fs.existsSync(filePath)) {
      if (createIfMissing) {
        return {
          success: false,
          error: 'file_not_found',
          message: `File not found: ${filePath}`,
          data: null
        };
      }
      throw new Error(`File not found: ${filePath}`);
    }

    // Read file
    const content = fs.readFileSync(filePath, 'utf8');

    // Parse JSON
    let data;
    try {
      data = JSON.parse(content);
    } catch (parseError) {
      return {
        success: false,
        error: 'json_parse_error',
        message: `Failed to parse JSON: ${parseError.message}`,
        filePath,
        data: null
      };
    }

    // Validate with schema
    if (repair) {
      const result = validator.validateAndRepair(data, schemaName);

      if (!result.valid) {
        return {
          success: false,
          error: 'validation_failed',
          message: 'Data validation failed and could not be repaired',
          filePath,
          schemaName,
          data: result.data,
          errors: result.errors,
          repaired: result.repaired,
          repairs: result.repairs
        };
      }

      if (result.repaired) {
        // Data was repaired - optionally write back
        console.warn(`[SafeJSON] Data in ${filePath} was repaired:`, result.repairs);
      }

      return {
        success: true,
        data: result.data,
        repaired: result.repaired,
        repairs: result.repairs || [],
        filePath,
        schemaName
      };
    } else {
      // Validate without repair
      const result = validator.validate(data, schemaName);

      if (!result.valid) {
        return {
          success: false,
          error: 'validation_failed',
          message: 'Data validation failed',
          filePath,
          schemaName,
          data,
          errors: result.errors
        };
      }

      return {
        success: true,
        data,
        filePath,
        schemaName
      };
    }
  } catch (error) {
    return {
      success: false,
      error: 'read_error',
      message: error.message,
      filePath,
      schemaName,
      data: null
    };
  }
}

/**
 * Safe write JSON file with schema validation
 *
 * @param {string} filePath - Absolute path to JSON file
 * @param {object} data - Data to write
 * @param {string} schemaName - Schema to validate against
 * @param {object} options - Options { backup: boolean, repair: boolean, pretty: boolean }
 * @returns {object} { success: boolean, errors: array|null, backedUp: boolean, repaired: boolean }
 */
function safeWriteJSON(filePath, data, schemaName, options = {}) {
  const {
    backup = true,
    repair = true,
    pretty = true
  } = options;

  let backupPath = null;

  try {
    // Validate data before writing
    let validatedData = data;
    let repaired = false;
    let repairs = [];

    if (repair) {
      const result = validator.validateAndRepair(data, schemaName);

      if (!result.valid) {
        return {
          success: false,
          error: 'validation_failed',
          message: 'Data validation failed and could not be repaired',
          filePath,
          schemaName,
          errors: result.errors,
          repaired: result.repaired,
          repairs: result.repairs
        };
      }

      validatedData = result.data;
      repaired = result.repaired;
      repairs = result.repairs || [];

      if (repaired) {
        console.warn(`[SafeJSON] Data was repaired before writing to ${filePath}:`, repairs);
      }
    } else {
      const result = validator.validate(data, schemaName);

      if (!result.valid) {
        return {
          success: false,
          error: 'validation_failed',
          message: 'Data validation failed',
          filePath,
          schemaName,
          errors: result.errors
        };
      }
    }

    // Create backup if file exists
    let backedUp = false;
    if (backup && fs.existsSync(filePath)) {
      backupPath = `${filePath}.backup`;
      fs.copyFileSync(filePath, backupPath);
      backedUp = true;
    }

    // Ensure directory exists
    const dir = path.dirname(filePath);
    if (!fs.existsSync(dir)) {
      fs.mkdirSync(dir, { recursive: true });
    }

    // Write atomically (write to temp, then rename)
    const tempPath = `${filePath}.tmp`;
    const content = pretty
      ? JSON.stringify(validatedData, null, 2)
      : JSON.stringify(validatedData);

    fs.writeFileSync(tempPath, content, 'utf8');
    fs.renameSync(tempPath, filePath);

    // Delete backup if write succeeded
    if (backedUp && backupPath) {
      // Keep backup for now - can be cleaned up later
    }

    return {
      success: true,
      filePath,
      schemaName,
      repaired,
      repairs,
      backedUp,
      backupPath: backedUp ? backupPath : null
    };
  } catch (error) {
    // Rollback on error
    if (backupPath && fs.existsSync(backupPath)) {
      try {
        fs.copyFileSync(backupPath, filePath);
        console.error(`[SafeJSON] Write failed, restored from backup: ${filePath}`);
      } catch (rollbackError) {
        console.error(`[SafeJSON] Failed to rollback: ${rollbackError.message}`);
      }
    }

    return {
      success: false,
      error: 'write_error',
      message: error.message,
      filePath,
      schemaName
    };
  }
}

/**
 * Safe read JSONL file (JSON Lines - one JSON object per line)
 *
 * @param {string} filePath - Absolute path to JSONL file
 * @param {string} schemaName - Schema to validate each line against
 * @param {object} options - Options { repair: boolean, skipInvalid: boolean, limit: number }
 * @returns {object} { success: boolean, data: array, errors: array, invalidCount: number }
 */
function safeReadJSONL(filePath, schemaName, options = {}) {
  const { repair = true, skipInvalid = true, limit = null } = options;

  try {
    if (!fs.existsSync(filePath)) {
      return {
        success: false,
        error: 'file_not_found',
        message: `File not found: ${filePath}`,
        data: []
      };
    }

    const content = fs.readFileSync(filePath, 'utf8');
    const lines = content.split('\n').filter(line => line.trim().length > 0);

    const data = [];
    const errors = [];
    let invalidCount = 0;

    for (let i = 0; i < lines.length; i++) {
      if (limit && data.length >= limit) break;

      const line = lines[i];

      try {
        const entry = JSON.parse(line);

        if (repair) {
          const result = validator.validateAndRepair(entry, schemaName);

          if (result.valid) {
            data.push(result.data);
          } else {
            invalidCount++;
            errors.push({
              line: i + 1,
              entry,
              errors: result.errors
            });

            if (!skipInvalid) {
              return {
                success: false,
                error: 'validation_failed',
                message: `Line ${i + 1} validation failed`,
                data,
                errors,
                invalidCount
              };
            }
          }
        } else {
          const result = validator.validate(entry, schemaName);

          if (result.valid) {
            data.push(entry);
          } else {
            invalidCount++;
            errors.push({
              line: i + 1,
              entry,
              errors: result.errors
            });

            if (!skipInvalid) {
              return {
                success: false,
                error: 'validation_failed',
                message: `Line ${i + 1} validation failed`,
                data,
                errors,
                invalidCount
              };
            }
          }
        }
      } catch (parseError) {
        invalidCount++;
        errors.push({
          line: i + 1,
          error: 'json_parse_error',
          message: parseError.message
        });

        if (!skipInvalid) {
          return {
            success: false,
            error: 'json_parse_error',
            message: `Line ${i + 1} parse error`,
            data,
            errors,
            invalidCount
          };
        }
      }
    }

    return {
      success: true,
      data,
      filePath,
      schemaName,
      totalLines: lines.length,
      validLines: data.length,
      invalidCount,
      errors: errors.length > 0 ? errors : null
    };
  } catch (error) {
    return {
      success: false,
      error: 'read_error',
      message: error.message,
      filePath,
      data: []
    };
  }
}

/**
 * Safe append to JSONL file with schema validation
 *
 * @param {string} filePath - Absolute path to JSONL file
 * @param {object} entry - Entry to append
 * @param {string} schemaName - Schema to validate against
 * @param {object} options - Options { repair: boolean }
 * @returns {object} { success: boolean, errors: array|null, repaired: boolean }
 */
function safeAppendJSONL(filePath, entry, schemaName, options = {}) {
  const { repair = true } = options;

  try {
    // Validate entry
    let validatedEntry = entry;
    let repaired = false;
    let repairs = [];

    if (repair) {
      const result = validator.validateAndRepair(entry, schemaName);

      if (!result.valid) {
        return {
          success: false,
          error: 'validation_failed',
          message: 'Entry validation failed',
          filePath,
          schemaName,
          errors: result.errors
        };
      }

      validatedEntry = result.data;
      repaired = result.repaired;
      repairs = result.repairs || [];
    } else {
      const result = validator.validate(entry, schemaName);

      if (!result.valid) {
        return {
          success: false,
          error: 'validation_failed',
          message: 'Entry validation failed',
          filePath,
          schemaName,
          errors: result.errors
        };
      }
    }

    // Ensure directory exists
    const dir = path.dirname(filePath);
    if (!fs.existsSync(dir)) {
      fs.mkdirSync(dir, { recursive: true });
    }

    // Append to file
    const line = JSON.stringify(validatedEntry) + '\n';
    fs.appendFileSync(filePath, line, 'utf8');

    return {
      success: true,
      filePath,
      schemaName,
      repaired,
      repairs
    };
  } catch (error) {
    return {
      success: false,
      error: 'append_error',
      message: error.message,
      filePath,
      schemaName
    };
  }
}

/**
 * Validate handoff file
 */
function validateHandoff(handoff) {
  return validator.validate(handoff, 'handoff');
}

/**
 * Validate master state file
 */
function validateMasterState(state) {
  return validator.validate(state, 'master-state');
}

/**
 * Validate worker spec file
 */
function validateWorkerSpec(spec) {
  return validator.validate(spec, 'worker-spec');
}

/**
 * Validate task queue entry
 */
function validateTaskEntry(task) {
  return validator.validate(task, 'task-queue-entry');
}

/**
 * Validate routing decision
 */
function validateRoutingDecision(decision) {
  return validator.validate(decision, 'routing-decision');
}

/**
 * Validate dashboard event
 */
function validateDashboardEvent(event) {
  return validator.validate(event, 'dashboard-event');
}

module.exports = {
  // Core functions
  safeReadJSON,
  safeWriteJSON,
  safeReadJSONL,
  safeAppendJSONL,

  // Specialized validators
  validateHandoff,
  validateMasterState,
  validateWorkerSpec,
  validateTaskEntry,
  validateRoutingDecision,
  validateDashboardEvent,

  // Direct access to validator
  validator
};
