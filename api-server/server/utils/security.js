/**
 * Security Utilities
 * Safe command execution and other security helper functions
 */

const { spawn, execSync } = require('child_process');
const path = require('path');
const { validatePid } = require('../middleware/validators');

/**
 * Safely execute a command without shell injection risks
 * Uses spawn() without shell=true
 *
 * @param {string} command - The command to execute
 * @param {string[]} args - Array of arguments
 * @param {object} options - Spawn options (without shell)
 * @returns {Promise} - Resolves with stdout, rejects with error
 */
async function safeExec(command, args = [], options = {}) {
  return new Promise((resolve, reject) => {
    // Force shell: false for security
    const safeOptions = {
      ...options,
      shell: false,
      timeout: options.timeout || 30000 // 30 second default timeout
    };

    const proc = spawn(command, args, safeOptions);
    let stdout = '';
    let stderr = '';

    if (proc.stdout) {
      proc.stdout.on('data', (data) => {
        stdout += data.toString();
      });
    }

    if (proc.stderr) {
      proc.stderr.on('data', (data) => {
        stderr += data.toString();
      });
    }

    proc.on('error', (error) => {
      reject(new Error(`Command failed: ${error.message}`));
    });

    proc.on('close', (code) => {
      if (code === 0) {
        resolve({ stdout, stderr, code });
      } else {
        reject(new Error(`Command exited with code ${code}: ${stderr}`));
      }
    });
  });
}

/**
 * Safely check if a process is running by PID
 * @param {number|string} pid - Process ID to check
 * @returns {boolean} - True if process exists
 */
function isProcessRunning(pid) {
  try {
    const validPid = validatePid(pid);

    // Use kill with signal 0 to check if process exists (doesn't actually kill it)
    process.kill(validPid, 0);
    return true;
  } catch (error) {
    // ESRCH means process doesn't exist
    if (error.code === 'ESRCH') {
      return false;
    }
    // EPERM means process exists but we don't have permission (still running)
    if (error.code === 'EPERM') {
      return true;
    }
    // Other errors
    return false;
  }
}

/**
 * Safely kill a process by PID
 * @param {number|string} pid - Process ID to kill
 * @param {string} signal - Signal to send (default: SIGTERM)
 * @returns {boolean} - True if successful
 */
function safeKillProcess(pid, signal = 'SIGTERM') {
  try {
    const validPid = validatePid(pid);
    process.kill(validPid, signal);
    return true;
  } catch (error) {
    console.error(`Failed to kill process ${pid}:`, error.message);
    return false;
  }
}

/**
 * Safely start a bash script with arguments
 * @param {string} scriptPath - Absolute path to script
 * @param {string[]} args - Script arguments
 * @param {string} baseDir - Expected base directory for script
 * @returns {Promise} - Resolves when script starts
 */
async function safeStartScript(scriptPath, args = [], baseDir) {
  // Validate script path is within base directory
  const resolvedScript = path.resolve(scriptPath);
  const resolvedBase = path.resolve(baseDir);

  if (!resolvedScript.startsWith(resolvedBase + path.sep)) {
    throw new Error('Script path outside allowed directory');
  }

  // Check script exists and is executable
  const fs = require('fs');
  if (!fs.existsSync(resolvedScript)) {
    throw new Error('Script not found');
  }

  // Execute using bash with validated path
  return safeExec('bash', [resolvedScript, ...args], {
    cwd: baseDir,
    detached: false
  });
}

/**
 * Sanitize error messages for production
 * Removes sensitive information like file paths
 * @param {Error} error - The error object
 * @param {boolean} isDevelopment - Whether in development mode
 * @returns {object} - Sanitized error object
 */
function sanitizeError(error, isDevelopment = false) {
  if (isDevelopment) {
    return {
      error: error.message,
      stack: error.stack,
      type: error.name
    };
  }

  // In production, return generic error
  const safeMessages = {
    'ENOENT': 'Resource not found',
    'EACCES': 'Permission denied',
    'ETIMEDOUT': 'Operation timed out',
    'ECONNREFUSED': 'Connection refused'
  };

  return {
    error: safeMessages[error.code] || 'An error occurred',
    type: 'ServerError'
  };
}

/**
 * Generate a secure random token
 * @param {number} length - Token length
 * @returns {string} - Random hex token
 */
function generateToken(length = 32) {
  const crypto = require('crypto');
  return crypto.randomBytes(length).toString('hex');
}

module.exports = {
  safeExec,
  isProcessRunning,
  safeKillProcess,
  safeStartScript,
  sanitizeError,
  generateToken
};
