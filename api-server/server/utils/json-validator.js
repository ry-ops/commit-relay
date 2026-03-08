/**
 * JSON Validation and Repair Utility for Node.js
 * Provides validation and automatic repair for common JSON errors
 * Used by dashboard server to prevent malformed JSON in event logs
 */

const fs = require('fs');
const path = require('path');

// Configuration
const DEBUG = process.env.DEBUG_JSON_VALIDATION === '1';
const LOG_FILE = process.env.JSON_VALIDATION_LOG || null;

/**
 * Log validation events
 */
function logValidation(level, message, metadata = {}) {
  const timestamp = new Date().toISOString();
  const logEntry = {
    timestamp,
    level,
    message,
    ...metadata
  };

  // Console logging in debug mode
  if (DEBUG) {
    console.error(`[${timestamp}] [${level}] ${message}`);
  }

  // File logging if configured
  if (LOG_FILE) {
    try {
      fs.appendFileSync(LOG_FILE, JSON.stringify(logEntry) + '\n', 'utf-8');
    } catch (error) {
      console.error('Failed to write to validation log:', error);
    }
  }
}

/**
 * Validate JSON string
 * @param {string} jsonString - JSON string to validate
 * @returns {boolean} - True if valid, false otherwise
 */
function validateJSON(jsonString) {
  try {
    JSON.parse(jsonString);
    return true;
  } catch (error) {
    return false;
  }
}

/**
 * Repair common JSON errors
 * @param {string} jsonString - JSON string to repair
 * @returns {string} - Repaired JSON string
 */
function repairJSON(jsonString) {
  let repaired = jsonString;
  let repairAttempted = false;

  logValidation('INFO', 'Attempting JSON repair');

  // 1. Remove trailing commas before closing braces/brackets
  if (/,\s*[}\]]/.test(repaired)) {
    repaired = repaired.replace(/,(\s*[}\]])/g, '$1');
    repairAttempted = true;
    logValidation('INFO', 'Removed trailing commas');
  }

  // 2. Fix missing commas between objects (common in JSONL concatenation)
  // Pattern: }{ should be },{
  if (/\}\s*\{/.test(repaired)) {
    repaired = repaired.replace(/\}(\s*)\{/g, '},$1{');
    repairAttempted = true;
    logValidation('INFO', 'Added missing commas between objects');
  }

  // 3. Fix missing commas between array elements
  // Pattern: ][ should be ],[
  if (/\]\s*\[/.test(repaired)) {
    repaired = repaired.replace(/\](\s*)\[/g, '],$1[');
    repairAttempted = true;
    logValidation('INFO', 'Added missing commas between arrays');
  }

  // 4. Balance unclosed brackets
  const openBraces = (repaired.match(/\{/g) || []).length;
  const closeBraces = (repaired.match(/\}/g) || []).length;
  const openBrackets = (repaired.match(/\[/g) || []).length;
  const closeBrackets = (repaired.match(/\]/g) || []).length;

  // Add missing closing braces
  if (openBraces > closeBraces) {
    const missing = openBraces - closeBraces;
    repaired += '}'.repeat(missing);
    repairAttempted = true;
    logValidation('WARN', `Added ${missing} missing closing brace(s)`);
  }

  // Add missing closing brackets
  if (openBrackets > closeBrackets) {
    const missing = openBrackets - closeBrackets;
    repaired += ']'.repeat(missing);
    repairAttempted = true;
    logValidation('WARN', `Added ${missing} missing closing bracket(s)`);
  }

  // Warn about extra closing braces/brackets
  if (closeBraces > openBraces) {
    logValidation('ERROR', 'More closing braces than opening - cannot auto-repair');
  }

  if (closeBrackets > openBrackets) {
    logValidation('ERROR', 'More closing brackets than opening - cannot auto-repair');
  }

  if (repairAttempted) {
    logValidation('INFO', 'JSON repair completed');
  }

  return repaired;
}

/**
 * Validate and repair JSON
 * @param {string} jsonString - JSON string to validate and repair
 * @param {boolean} allowRepair - Whether to attempt repair (default: true)
 * @returns {object} - { success: boolean, data: string|null, error: string|null }
 */
function validateAndRepairJSON(jsonString, allowRepair = true) {
  // First, try to validate as-is
  if (validateJSON(jsonString)) {
    logValidation('INFO', 'JSON is valid');
    return { success: true, data: jsonString, error: null };
  }

  logValidation('WARN', 'JSON validation failed');

  // If repair is allowed, attempt to repair
  if (allowRepair) {
    const repaired = repairJSON(jsonString);

    // Validate repaired JSON
    if (validateJSON(repaired)) {
      logValidation('INFO', 'JSON repair successful');
      return { success: true, data: repaired, error: null };
    } else {
      const error = 'JSON repair failed - still invalid';
      logValidation('ERROR', error);
      return { success: false, data: null, error };
    }
  } else {
    const error = 'JSON invalid and repair disabled';
    logValidation('ERROR', error);
    return { success: false, data: null, error };
  }
}

/**
 * Validate JSONL file (newline-delimited JSON)
 * @param {string} filePath - Path to JSONL file
 * @param {boolean} repair - Whether to repair invalid lines (default: false)
 * @returns {object} - { success: boolean, errors: number, details: array }
 */
function validateJSONLFile(filePath, repair = false) {
  if (!fs.existsSync(filePath)) {
    const error = `File not found: ${filePath}`;
    logValidation('ERROR', error);
    return { success: false, errors: 1, details: [{ line: 0, error }] };
  }

  logValidation('INFO', `Validating JSONL file: ${filePath}`);

  const content = fs.readFileSync(filePath, 'utf-8');
  const lines = content.split('\n');
  let errors = 0;
  const details = [];

  lines.forEach((line, index) => {
    const lineNum = index + 1;

    // Skip empty lines
    if (!line.trim()) {
      return;
    }

    // Validate line
    if (!validateJSON(line)) {
      logValidation('ERROR', `Line ${lineNum}: Invalid JSON`);
      errors++;

      // Attempt repair if enabled
      if (repair) {
        const result = validateAndRepairJSON(line, true);
        if (result.success) {
          logValidation('INFO', `Line ${lineNum}: Repaired successfully`);
          errors--;
        } else {
          details.push({ line: lineNum, error: 'Cannot repair' });
        }
      } else {
        details.push({ line: lineNum, error: 'Invalid JSON' });
      }
    }
  });

  const success = errors === 0;
  const message = success
    ? 'JSONL file validation completed: All lines valid'
    : `JSONL file validation completed: ${errors} invalid line(s)`;

  logValidation(success ? 'INFO' : 'ERROR', message);

  return { success, errors, details };
}

/**
 * Repair JSONL file in place
 * @param {string} filePath - Path to JSONL file
 * @param {boolean} backup - Whether to create a backup (default: true)
 * @returns {object} - { success: boolean, repaired: number, failed: number, backup: string|null }
 */
function repairJSONLFile(filePath, backup = true) {
  if (!fs.existsSync(filePath)) {
    const error = `File not found: ${filePath}`;
    logValidation('ERROR', error);
    return { success: false, repaired: 0, failed: 0, backup: null, error };
  }

  logValidation('INFO', `Repairing JSONL file: ${filePath}`);

  // Create backup if requested
  let backupPath = null;
  if (backup) {
    backupPath = `${filePath}.backup.${Date.now()}`;
    fs.copyFileSync(filePath, backupPath);
    logValidation('INFO', `Backup created: ${backupPath}`);
  }

  const content = fs.readFileSync(filePath, 'utf-8');
  const lines = content.split('\n');
  const repairedLines = [];
  let repairedCount = 0;
  let failedCount = 0;

  lines.forEach((line, index) => {
    const lineNum = index + 1;

    // Skip empty lines
    if (!line.trim()) {
      return;
    }

    // Try to repair line
    const result = validateAndRepairJSON(line, true);
    if (result.success) {
      repairedLines.push(result.data);
      if (result.data !== line) {
        repairedCount++;
        logValidation('INFO', `Line ${lineNum}: Repaired`);
      }
    } else {
      logValidation('ERROR', `Line ${lineNum}: Cannot repair - skipping`);
      failedCount++;
    }
  });

  // Write repaired content
  fs.writeFileSync(filePath, repairedLines.join('\n') + '\n', 'utf-8');

  logValidation('INFO', `Repair completed: ${repairedCount} repaired, ${failedCount} failed`);

  return {
    success: failedCount === 0,
    repaired: repairedCount,
    failed: failedCount,
    backup: backupPath
  };
}

/**
 * Safely write JSON to file with validation
 * @param {string} filePath - Path to file
 * @param {object|string} data - Data to write (object will be stringified)
 * @param {boolean} append - Whether to append (default: false)
 * @returns {object} - { success: boolean, error: string|null }
 */
function safeWriteJSON(filePath, data, append = false) {
  try {
    // Convert to string if needed
    let jsonString;
    if (typeof data === 'string') {
      jsonString = data;
    } else {
      jsonString = JSON.stringify(data);
    }

    // Validate before writing
    const result = validateAndRepairJSON(jsonString, true);
    if (!result.success) {
      return { success: false, error: result.error };
    }

    // Write to file
    if (append) {
      fs.appendFileSync(filePath, result.data + '\n', 'utf-8');
    } else {
      fs.writeFileSync(filePath, result.data, 'utf-8');
    }

    return { success: true, error: null };
  } catch (error) {
    const errorMessage = `Failed to write JSON: ${error.message}`;
    logValidation('ERROR', errorMessage);
    return { success: false, error: errorMessage };
  }
}

module.exports = {
  validateJSON,
  repairJSON,
  validateAndRepairJSON,
  validateJSONLFile,
  repairJSONLFile,
  safeWriteJSON,
  logValidation
};
