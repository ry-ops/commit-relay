/**
 * User Management API Routes
 *
 * Endpoints:
 * - GET    /api/users           - List all users
 * - GET    /api/users/stats     - Get user statistics
 * - POST   /api/users           - Create new user
 * - GET    /api/users/:id       - Get user by ID
 * - PUT    /api/users/:id       - Update user
 * - DELETE /api/users/:id       - Delete user
 */

const express = require('express');
const router = express.Router();
const { body, param, validationResult } = require('express-validator');
const path = require('path');
const fs = require('fs').promises;

// Path to user data storage
const USERS_FILE = path.join(__dirname, '../../../coordination/users.json');

/**
 * Validation middleware
 */
const validate = (req, res, next) => {
  const errors = validationResult(req);
  if (!errors.isEmpty()) {
    return res.status(400).json({
      error: 'Validation failed',
      details: errors.array()
    });
  }
  next();
};

/**
 * User validation rules for POST/PUT
 */
const userValidationRules = [
  body('username')
    .isLength({ min: 3, max: 50 })
    .matches(/^[a-zA-Z0-9_-]+$/)
    .withMessage('Username must be 3-50 alphanumeric characters, hyphens, or underscores'),
  body('email')
    .isEmail()
    .normalizeEmail()
    .withMessage('Must be a valid email address'),
  body('role')
    .optional()
    .isIn(['admin', 'user', 'viewer'])
    .withMessage('Role must be admin, user, or viewer'),
  body('name')
    .optional()
    .isLength({ min: 1, max: 100 })
    .trim()
    .withMessage('Name must be 1-100 characters')
];

/**
 * ID parameter validation
 */
const idValidationRules = [
  param('id')
    .isLength({ min: 1, max: 100 })
    .matches(/^[a-zA-Z0-9\-_]+$/)
    .withMessage('Invalid user ID format')
];

/**
 * Helper: Read users from storage
 */
async function readUsers() {
  try {
    const data = await fs.readFile(USERS_FILE, 'utf8');
    return JSON.parse(data);
  } catch (error) {
    if (error.code === 'ENOENT') {
      // File doesn't exist, return empty structure
      return { users: [], updated_at: new Date().toISOString() };
    }
    throw error;
  }
}

/**
 * Helper: Write users to storage
 */
async function writeUsers(data) {
  data.updated_at = new Date().toISOString();
  await fs.writeFile(USERS_FILE, JSON.stringify(data, null, 2), 'utf8');
}

/**
 * GET /api/users - List all users
 */
router.get('/', async (req, res) => {
  try {
    const data = await readUsers();
    res.json({
      success: true,
      data: data.users || [],
      count: (data.users || []).length
    });
  } catch (error) {
    console.error('Error fetching users:', error);
    res.status(500).json({
      error: 'Internal server error',
      message: 'Failed to fetch users'
    });
  }
});

/**
 * GET /api/users/stats - Get user statistics
 */
router.get('/stats', async (req, res) => {
  try {
    const data = await readUsers();
    const users = data.users || [];

    // Calculate statistics
    const stats = {
      total: users.length,
      by_role: {
        admin: users.filter(u => u.role === 'admin').length,
        user: users.filter(u => u.role === 'user').length,
        viewer: users.filter(u => u.role === 'viewer').length
      },
      by_status: {
        active: users.filter(u => u.status === 'active').length,
        inactive: users.filter(u => u.status === 'inactive').length,
        suspended: users.filter(u => u.status === 'suspended').length
      },
      recently_created: users
        .sort((a, b) => new Date(b.created_at) - new Date(a.created_at))
        .slice(0, 5)
        .map(u => ({
          id: u.id,
          username: u.username,
          role: u.role,
          created_at: u.created_at
        })),
      recently_updated: users
        .filter(u => u.updated_at)
        .sort((a, b) => new Date(b.updated_at) - new Date(a.updated_at))
        .slice(0, 5)
        .map(u => ({
          id: u.id,
          username: u.username,
          role: u.role,
          updated_at: u.updated_at
        })),
      timestamp: new Date().toISOString()
    };

    res.json({
      success: true,
      data: stats
    });
  } catch (error) {
    console.error('Error fetching user statistics:', error);
    res.status(500).json({
      error: 'Internal server error',
      message: 'Failed to fetch user statistics'
    });
  }
});

/**
 * POST /api/users - Create new user
 */
router.post('/',
  userValidationRules,
  validate,
  async (req, res) => {
    try {
      const { username, email, role = 'user', name } = req.body;
      const data = await readUsers();

      // Check if username already exists
      const existingUser = data.users.find(u => u.username === username);
      if (existingUser) {
        return res.status(409).json({
          error: 'Conflict',
          message: 'Username already exists'
        });
      }

      // Check if email already exists
      const existingEmail = data.users.find(u => u.email === email);
      if (existingEmail) {
        return res.status(409).json({
          error: 'Conflict',
          message: 'Email already exists'
        });
      }

      // Create new user
      const newUser = {
        id: `user-${Date.now()}-${Math.random().toString(36).substr(2, 9)}`,
        username,
        email,
        role,
        name: name || username,
        created_at: new Date().toISOString(),
        updated_at: new Date().toISOString(),
        status: 'active'
      };

      data.users.push(newUser);
      await writeUsers(data);

      res.status(201).json({
        success: true,
        message: 'User created successfully',
        data: newUser
      });
    } catch (error) {
      console.error('Error creating user:', error);
      res.status(500).json({
        error: 'Internal server error',
        message: 'Failed to create user'
      });
    }
  }
);

/**
 * GET /api/users/:id - Get user by ID
 */
router.get('/:id',
  idValidationRules,
  validate,
  async (req, res) => {
    try {
      const { id } = req.params;
      const data = await readUsers();

      const user = data.users.find(u => u.id === id);
      if (!user) {
        return res.status(404).json({
          error: 'Not found',
          message: 'User not found'
        });
      }

      res.json({
        success: true,
        data: user
      });
    } catch (error) {
      console.error('Error fetching user:', error);
      res.status(500).json({
        error: 'Internal server error',
        message: 'Failed to fetch user'
      });
    }
  }
);

/**
 * PUT /api/users/:id - Update user
 */
router.put('/:id',
  idValidationRules,
  [
    body('email')
      .optional()
      .isEmail()
      .normalizeEmail()
      .withMessage('Must be a valid email address'),
    body('role')
      .optional()
      .isIn(['admin', 'user', 'viewer'])
      .withMessage('Role must be admin, user, or viewer'),
    body('name')
      .optional()
      .isLength({ min: 1, max: 100 })
      .trim()
      .withMessage('Name must be 1-100 characters'),
    body('status')
      .optional()
      .isIn(['active', 'inactive', 'suspended'])
      .withMessage('Status must be active, inactive, or suspended')
  ],
  validate,
  async (req, res) => {
    try {
      const { id } = req.params;
      const updates = req.body;
      const data = await readUsers();

      const userIndex = data.users.findIndex(u => u.id === id);
      if (userIndex === -1) {
        return res.status(404).json({
          error: 'Not found',
          message: 'User not found'
        });
      }

      // Check if email is being changed and already exists
      if (updates.email && updates.email !== data.users[userIndex].email) {
        const existingEmail = data.users.find(u => u.email === updates.email);
        if (existingEmail) {
          return res.status(409).json({
            error: 'Conflict',
            message: 'Email already exists'
          });
        }
      }

      // Update user (username cannot be changed)
      data.users[userIndex] = {
        ...data.users[userIndex],
        email: updates.email || data.users[userIndex].email,
        role: updates.role || data.users[userIndex].role,
        name: updates.name || data.users[userIndex].name,
        status: updates.status || data.users[userIndex].status,
        updated_at: new Date().toISOString()
      };

      await writeUsers(data);

      res.json({
        success: true,
        message: 'User updated successfully',
        data: data.users[userIndex]
      });
    } catch (error) {
      console.error('Error updating user:', error);
      res.status(500).json({
        error: 'Internal server error',
        message: 'Failed to update user'
      });
    }
  }
);

/**
 * DELETE /api/users/:id - Delete user
 */
router.delete('/:id',
  idValidationRules,
  validate,
  async (req, res) => {
    try {
      const { id } = req.params;
      const data = await readUsers();

      const userIndex = data.users.findIndex(u => u.id === id);
      if (userIndex === -1) {
        return res.status(404).json({
          error: 'Not found',
          message: 'User not found'
        });
      }

      const deletedUser = data.users.splice(userIndex, 1)[0];
      await writeUsers(data);

      res.json({
        success: true,
        message: 'User deleted successfully',
        data: deletedUser
      });
    } catch (error) {
      console.error('Error deleting user:', error);
      res.status(500).json({
        error: 'Internal server error',
        message: 'Failed to delete user'
      });
    }
  }
);

module.exports = router;
