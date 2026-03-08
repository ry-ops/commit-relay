/**
 * User Management API Routes
 *
 * Provides RESTful endpoints for managing users in the commit-relay system:
 * - GET /api/users - List all active users
 * - POST /api/users - Create new user
 * - GET /api/users/:userId - Get specific user details
 * - PUT /api/users/:userId - Update user information
 * - DELETE /api/users/:userId - Archive/soft-delete user
 *
 * All endpoints require authentication via X-API-Key header.
 */

const express = require('express');
const router = express.Router();
const { body, param, validationResult } = require('express-validator');
const fs = require('fs').promises;
const path = require('path');
const { validateId, isPathWithinDirectory } = require('../lib/path-validator');

// Configuration
const COORD_DIR = path.resolve(__dirname, '../../../coordination');
const USERS_DIR = path.join(COORD_DIR, 'users');
const ACTIVE_DIR = path.join(USERS_DIR, 'active');
const ARCHIVED_DIR = path.join(USERS_DIR, 'archived');

/**
 * Validation middleware helper
 */
const validate = (req, res, next) => {
  const errors = validationResult(req);
  if (!errors.isEmpty()) {
    return res.status(400).json({
      success: false,
      error: 'Validation failed',
      details: errors.array()
    });
  }
  next();
};

/**
 * Ensure users directories exist
 */
async function ensureDirectories() {
  try {
    await fs.mkdir(USERS_DIR, { recursive: true });
    await fs.mkdir(ACTIVE_DIR, { recursive: true });
    await fs.mkdir(ARCHIVED_DIR, { recursive: true });
  } catch (error) {
    console.error('Error creating users directories:', error);
  }
}

// Initialize directories on module load
ensureDirectories();

/**
 * Helper: Read user file
 */
async function readUser(userId, dir = ACTIVE_DIR) {
  // Validate userId to prevent path traversal
  const sanitizedUserId = validateId(userId);
  if (!sanitizedUserId) {
    throw new Error('Invalid user ID format');
  }

  const userFile = path.join(dir, `${sanitizedUserId}.json`);

  // Ensure the file path is within the expected directory
  if (!isPathWithinDirectory(userFile, USERS_DIR)) {
    throw new Error('Invalid user file path');
  }

  const content = await fs.readFile(userFile, 'utf-8');
  return JSON.parse(content);
}

/**
 * Helper: Write user file
 */
async function writeUser(user, dir = ACTIVE_DIR) {
  const userFile = path.join(dir, `${user.user_id}.json`);
  await fs.writeFile(userFile, JSON.stringify(user, null, 2), 'utf-8');
}

/**
 * Helper: Delete user file
 */
async function deleteUser(userId, dir = ACTIVE_DIR) {
  const userFile = path.join(dir, `${userId}.json`);
  await fs.unlink(userFile);
}

/**
 * Helper: Check if user exists
 */
async function userExists(userId, dir = ACTIVE_DIR) {
  const userFile = path.join(dir, `${userId}.json`);
  try {
    await fs.access(userFile);
    return true;
  } catch {
    return false;
  }
}

/**
 * GET /api/users
 * List all active users
 *
 * Query params:
 * - role: Filter by role (admin, user, viewer)
 * - status: Filter by status (active, suspended)
 * - limit: Max number of results (default: 100)
 */
router.get('/users', async (req, res) => {
  try {
    const { role, status, limit = 100 } = req.query;

    await ensureDirectories();
    const files = await fs.readdir(ACTIVE_DIR);
    let users = [];

    for (const file of files.filter(f => f.endsWith('.json'))) {
      try {
        const content = await fs.readFile(path.join(ACTIVE_DIR, file), 'utf-8');
        const user = JSON.parse(content);

        // Apply filters
        if (role && user.role !== role) continue;
        if (status && user.status !== status) continue;

        users.push(user);
      } catch (error) {
        console.error(`Error reading user file ${file}:`, error);
      }
    }

    // Apply limit
    users = users.slice(0, parseInt(limit));

    res.json({
      success: true,
      data: users,
      count: users.length,
      timestamp: new Date().toISOString()
    });
  } catch (error) {
    console.error('Error fetching users:', error);
    res.status(500).json({
      success: false,
      error: 'Failed to fetch users',
      message: error.message
    });
  }
});

/**
 * POST /api/users
 * Create new user
 *
 * Required body params:
 * - username: Unique username (3-50 chars, alphanumeric + _ -)
 * - email: Valid email address
 * - role: User role (admin, user, viewer)
 *
 * Optional body params:
 * - profile: Object with full_name, department, avatar_url
 */
router.post('/users',
  [
    body('username')
      .isString()
      .trim()
      .isLength({ min: 3, max: 50 })
      .matches(/^[a-zA-Z0-9_-]+$/)
      .withMessage('Username must be 3-50 characters, alphanumeric with _ or -'),
    body('email')
      .isEmail()
      .normalizeEmail()
      .withMessage('Valid email address required'),
    body('role')
      .isIn(['admin', 'user', 'viewer'])
      .withMessage('Role must be one of: admin, user, viewer'),
    body('profile')
      .optional()
      .isObject()
      .withMessage('Profile must be an object'),
    body('profile.full_name')
      .optional()
      .isString()
      .trim(),
    body('profile.department')
      .optional()
      .isString()
      .trim(),
    body('profile.avatar_url')
      .optional()
      .isURL()
  ],
  validate,
  async (req, res) => {
    try {
      const { username, email, role, profile } = req.body;

      await ensureDirectories();

      // Check for duplicate username
      const existingFiles = await fs.readdir(ACTIVE_DIR);
      for (const file of existingFiles.filter(f => f.endsWith('.json'))) {
        try {
          const existingUser = await readUser(file.replace('.json', ''));
          if (existingUser.username === username) {
            return res.status(409).json({
              success: false,
              error: 'Username already exists',
              message: `Username '${username}' is already taken`
            });
          }
          if (existingUser.email === email) {
            return res.status(409).json({
              success: false,
              error: 'Email already exists',
              message: `Email '${email}' is already registered`
            });
          }
        } catch (error) {
          // Skip invalid files
        }
      }

      // Generate unique user ID
      const userId = `user-${Date.now()}-${Math.random().toString(36).substr(2, 9)}`;

      // Get creator from header
      const createdBy = req.headers['x-user'] || 'system';

      // Create user object
      const user = {
        user_id: userId,
        username,
        email,
        role,
        created_at: new Date().toISOString(),
        created_by: createdBy,
        status: 'active',
        last_login: null
      };

      // Add optional profile
      if (profile) {
        user.profile = {
          full_name: profile.full_name || null,
          department: profile.department || null,
          avatar_url: profile.avatar_url || null
        };
      }

      // Save user
      await writeUser(user);

      res.status(201).json({
        success: true,
        data: user,
        message: 'User created successfully',
        timestamp: new Date().toISOString()
      });
    } catch (error) {
      console.error('Error creating user:', error);
      res.status(500).json({
        success: false,
        error: 'Failed to create user',
        message: error.message
      });
    }
  }
);

/**
 * GET /api/users/:userId
 * Get specific user details
 */
router.get('/users/:userId',
  [
    param('userId')
      .matches(/^user-[a-z0-9\-]+$/)
      .withMessage('Invalid user ID format')
  ],
  validate,
  async (req, res) => {
    try {
      const { userId } = req.params;

      const exists = await userExists(userId);
      if (!exists) {
        return res.status(404).json({
          success: false,
          error: 'User not found',
          message: `User with ID '${userId}' does not exist`
        });
      }

      const user = await readUser(userId);

      res.json({
        success: true,
        data: user,
        timestamp: new Date().toISOString()
      });
    } catch (error) {
      console.error('Error fetching user:', error);
      res.status(500).json({
        success: false,
        error: 'Failed to fetch user',
        message: error.message
      });
    }
  }
);

/**
 * PUT /api/users/:userId
 * Update user information
 *
 * Updatable fields:
 * - email
 * - role
 * - status
 * - profile (full_name, department, avatar_url)
 */
router.put('/users/:userId',
  [
    param('userId')
      .matches(/^user-[a-z0-9\-]+$/)
      .withMessage('Invalid user ID format'),
    body('email')
      .optional()
      .isEmail()
      .normalizeEmail(),
    body('role')
      .optional()
      .isIn(['admin', 'user', 'viewer']),
    body('status')
      .optional()
      .isIn(['active', 'suspended']),
    body('profile')
      .optional()
      .isObject()
  ],
  validate,
  async (req, res) => {
    try {
      const { userId } = req.params;
      const updates = req.body;

      const exists = await userExists(userId);
      if (!exists) {
        return res.status(404).json({
          success: false,
          error: 'User not found',
          message: `User with ID '${userId}' does not exist`
        });
      }

      const user = await readUser(userId);
      const updatedBy = req.headers['x-user'] || 'system';

      // Apply updates
      if (updates.email) user.email = updates.email;
      if (updates.role) user.role = updates.role;
      if (updates.status) user.status = updates.status;
      if (updates.profile) {
        user.profile = {
          ...user.profile,
          ...updates.profile
        };
      }

      // Add update metadata
      user.updated_at = new Date().toISOString();
      user.updated_by = updatedBy;

      // Save updated user
      await writeUser(user);

      res.json({
        success: true,
        data: user,
        message: 'User updated successfully',
        timestamp: new Date().toISOString()
      });
    } catch (error) {
      console.error('Error updating user:', error);
      res.status(500).json({
        success: false,
        error: 'Failed to update user',
        message: error.message
      });
    }
  }
);

/**
 * DELETE /api/users/:userId
 * Archive/soft-delete user
 *
 * Moves user from active to archived directory
 */
router.delete('/users/:userId',
  [
    param('userId')
      .matches(/^user-[a-z0-9\-]+$/)
      .withMessage('Invalid user ID format')
  ],
  validate,
  async (req, res) => {
    try {
      const { userId } = req.params;

      const exists = await userExists(userId);
      if (!exists) {
        return res.status(404).json({
          success: false,
          error: 'User not found',
          message: `User with ID '${userId}' does not exist`
        });
      }

      const user = await readUser(userId);
      const deletedBy = req.headers['x-user'] || 'system';

      // Update user metadata
      user.status = 'archived';
      user.archived_at = new Date().toISOString();
      user.archived_by = deletedBy;

      // Move to archived directory
      await writeUser(user, ARCHIVED_DIR);
      await deleteUser(userId, ACTIVE_DIR);

      res.json({
        success: true,
        message: 'User archived successfully',
        data: { user_id: userId },
        timestamp: new Date().toISOString()
      });
    } catch (error) {
      console.error('Error archiving user:', error);
      res.status(500).json({
        success: false,
        error: 'Failed to archive user',
        message: error.message
      });
    }
  }
);

/**
 * POST /api/users/:userId/login
 * Record user login
 *
 * Updates last_login timestamp
 */
router.post('/users/:userId/login',
  [
    param('userId')
      .matches(/^user-[a-z0-9\-]+$/)
      .withMessage('Invalid user ID format')
  ],
  validate,
  async (req, res) => {
    try {
      const { userId } = req.params;

      const exists = await userExists(userId);
      if (!exists) {
        return res.status(404).json({
          success: false,
          error: 'User not found',
          message: `User with ID '${userId}' does not exist`
        });
      }

      const user = await readUser(userId);

      // Check if user is suspended
      if (user.status === 'suspended') {
        return res.status(403).json({
          success: false,
          error: 'User suspended',
          message: 'This user account is currently suspended'
        });
      }

      // Update last login
      user.last_login = new Date().toISOString();
      await writeUser(user);

      res.json({
        success: true,
        data: user,
        message: 'Login recorded successfully',
        timestamp: new Date().toISOString()
      });
    } catch (error) {
      console.error('Error recording login:', error);
      res.status(500).json({
        success: false,
        error: 'Failed to record login',
        message: error.message
      });
    }
  }
);

module.exports = router;
