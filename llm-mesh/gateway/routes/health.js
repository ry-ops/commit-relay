// Health Check Routes

const express = require('express');
const router = express.Router();

router.get('/', (req, res) => {
  res.json({
    status: 'healthy',
    timestamp: new Date().toISOString(),
    uptime: process.uptime(),
    version: '1.0.0'
  });
});

router.get('/ready', (req, res) => {
  // Check if services are ready
  const ready = req.registry && req.policyEnforcer;

  if (ready) {
    res.json({ status: 'ready', timestamp: new Date().toISOString() });
  } else {
    res.status(503).json({ status: 'not_ready', timestamp: new Date().toISOString() });
  }
});

module.exports = router;
