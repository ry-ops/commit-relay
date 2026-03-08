# Terminal Window Control System - Implementation Guide

## Overview

Dashboard-controlled terminal window management for worker spawning. Allows toggling between visible Terminal windows (for testing/debugging) and headless mode (for production).

## ✅ Completed Implementation

### 1. Configuration File
**File**: `/Users/ryandahlberg/commit-relay/coordination/config/terminal-settings.json`

```json
{
  "terminal_windows_enabled": true,
  "headless_mode": false,
  "auto_close_duration_minutes": 0,
  "last_updated": "2025-11-12T08:05:00-0600",
  "updated_by": "system"
}
```

**Fields**:
- `terminal_windows_enabled`: Main toggle for Terminal windows (true/false)
- `headless_mode`: Alternative flag to force headless operation
- `auto_close_duration_minutes`: Auto-close terminals after N minutes (0 = never)
- `last_updated`: Timestamp of last modification
- `updated_by`: User/system that made the change

### 2. Worker Daemon Integration
**File**: `/Users/ryandahlberg/commit-relay/scripts/worker-daemon.sh` (lines 200-242)

**Changes Made**:
- Reads terminal settings before each worker launch
- Supports two launch modes:
  1. **Terminal Mode** (`terminal_windows_enabled: true, headless_mode: false`)
     - Launches worker in visible Terminal.app window
     - Optional auto-close after duration
  2. **Headless Mode** (either flag set to disable terminals)
     - Launches worker in background without Terminal window
     - Redirects output to `agents/workers/{worker_id}/logs/stdout.log`

**Code Logic**:
```bash
if [ "$TERMINAL_ENABLED" = "true" ] && [ "$HEADLESS_MODE" = "false" ]; then
    # Launch in Terminal window with optional auto-close
    osascript -e "tell application \"Terminal\"..."
else
    # Launch headless in background
    "$CLAUDE_LAUNCHER" "$WORKER_ID" > "agents/workers/$WORKER_ID/logs/stdout.log" 2>&1 &
fi
```

## 🚧 Pending Implementation

### 3. Dashboard API Endpoints

**Add to**: `/Users/ryandahlberg/commit-relay/dashboard/server/index.js`
**Location**: After line 2547 (after event-log routes)

#### GET /api/terminal-settings
```javascript
/**
 * GET /api/terminal-settings
 * Get current terminal window settings
 */
app.get('/api/terminal-settings', async (req, res) => {
  try {
    const settingsPath = path.join(COMMIT_RELAY_HOME, 'coordination', 'config', 'terminal-settings.json');

    // Default settings if file doesn't exist
    const defaultSettings = {
      terminal_windows_enabled: true,
      headless_mode: false,
      auto_close_duration_minutes: 0,
      last_updated: new Date().toISOString(),
      updated_by: "system"
    };

    if (!fsSync.existsSync(settingsPath)) {
      return res.json(defaultSettings);
    }

    const settings = JSON.parse(await fs.readFile(settingsPath, 'utf-8'));
    res.json(settings);
  } catch (error) {
    console.error('Error reading terminal settings:', error);
    res.status(500).json({ error: 'Failed to read terminal settings' });
  }
});
```

#### POST /api/terminal-settings
```javascript
/**
 * POST /api/terminal-settings
 * Update terminal window settings
 * Body: { terminal_windows_enabled, headless_mode, auto_close_duration_minutes }
 */
app.post('/api/terminal-settings', async (req, res) => {
  try {
    const settingsPath = path.join(COMMIT_RELAY_HOME, 'coordination', 'config', 'terminal-settings.json');
    const { terminal_windows_enabled, headless_mode, auto_close_duration_minutes } = req.body;

    // Validation
    if (typeof terminal_windows_enabled !== 'boolean' && terminal_windows_enabled !== undefined) {
      return res.status(400).json({ error: 'terminal_windows_enabled must be boolean' });
    }
    if (typeof headless_mode !== 'boolean' && headless_mode !== undefined) {
      return res.status(400).json({ error: 'headless_mode must be boolean' });
    }
    if (auto_close_duration_minutes !== undefined &&
        (typeof auto_close_duration_minutes !== 'number' || auto_close_duration_minutes < 0)) {
      return res.status(400).json({ error: 'auto_close_duration_minutes must be non-negative number' });
    }

    // Read current settings
    let settings = {
      terminal_windows_enabled: true,
      headless_mode: false,
      auto_close_duration_minutes: 0
    };

    if (fsSync.existsSync(settingsPath)) {
      settings = JSON.parse(await fs.readFile(settingsPath, 'utf-8'));
    }

    // Update with new values
    if (terminal_windows_enabled !== undefined) settings.terminal_windows_enabled = terminal_windows_enabled;
    if (headless_mode !== undefined) settings.headless_mode = headless_mode;
    if (auto_close_duration_minutes !== undefined) settings.auto_close_duration_minutes = auto_close_duration_minutes;

    // Add metadata
    settings.last_updated = new Date().toISOString();
    settings.updated_by = req.headers['x-user'] || 'dashboard';

    // Write updated settings
    await fs.writeFile(settingsPath, JSON.stringify(settings, null, 2), 'utf-8');

    // Broadcast event
    const eventData = {
      terminal_windows_enabled: settings.terminal_windows_enabled,
      headless_mode: settings.headless_mode,
      auto_close_duration_minutes: settings.auto_close_duration_minutes
    };
    // TODO: Emit event via emit-event.sh

    res.json({
      success: true,
      settings: settings
    });
  } catch (error) {
    console.error('Error updating terminal settings:', error);
    res.status(500).json({ error: 'Failed to update terminal settings' });
  }
});
```

### 4. Dashboard UI Components

**Add to**: `/Users/ryandahlberg/commit-relay/dashboard/public/index.html`
**Location**: In the Settings panel or as a new Quick Controls section

#### HTML Structure
```html
<!-- Terminal Control Panel -->
<div class="control-panel">
  <h3>🖥️ Terminal Window Control</h3>

  <div class="control-group">
    <label class="switch">
      <input type="checkbox" id="terminal-windows-toggle" checked>
      <span class="slider"></span>
    </label>
    <label for="terminal-windows-toggle">Show Terminal Windows</label>
  </div>

  <div class="control-group">
    <label for="auto-close-duration">Auto-Close Duration (minutes)</label>
    <input type="number" id="auto-close-duration" min="0" max="180" value="0">
    <span class="help-text">0 = never auto-close</span>
  </div>

  <div class="control-group">
    <label class="switch">
      <input type="checkbox" id="headless-mode-toggle">
      <span class="slider"></span>
    </label>
    <label for="headless-mode-toggle">Force Headless Mode</label>
  </div>

  <button id="apply-terminal-settings" class="btn-primary">Apply Settings</button>

  <div id="terminal-settings-status" class="status-message"></div>
</div>
```

#### JavaScript Functions
```javascript
// Load current terminal settings
async function loadTerminalSettings() {
  try {
    const response = await fetch('/api/terminal-settings');
    const settings = await response.json();

    document.getElementById('terminal-windows-toggle').checked = settings.terminal_windows_enabled;
    document.getElementById('headless-mode-toggle').checked = settings.headless_mode;
    document.getElementById('auto-close-duration').value = settings.auto_close_duration_minutes;

    updateTerminalStatusDisplay(settings);
  } catch (error) {
    console.error('Failed to load terminal settings:', error);
  }
}

// Save terminal settings
async function saveTerminalSettings() {
  const settings = {
    terminal_windows_enabled: document.getElementById('terminal-windows-toggle').checked,
    headless_mode: document.getElementById('headless-mode-toggle').checked,
    auto_close_duration_minutes: parseInt(document.getElementById('auto-close-duration').value)
  };

  try {
    const response = await fetch('/api/terminal-settings', {
      method: 'POST',
      headers: { 'Content-Type': 'application/json' },
      body: JSON.stringify(settings)
    });

    const result = await response.json();

    if (result.success) {
      showStatus('Settings saved! New workers will use these settings.', 'success');
    } else {
      showStatus('Failed to save settings', 'error');
    }
  } catch (error) {
    console.error('Failed to save terminal settings:', error);
    showStatus('Error saving settings', 'error');
  }
}

// Display current mode status
function updateTerminalStatusDisplay(settings) {
  let mode = 'Unknown';
  if (settings.headless_mode || !settings.terminal_windows_enabled) {
    mode = '🔇 Headless Mode (no terminal windows)';
  } else {
    mode = '🖥️ Terminal Mode (visible windows)';
    if (settings.auto_close_duration_minutes > 0) {
      mode += ` (auto-close after ${settings.auto_close_duration_minutes}m)`;
    }
  }

  document.getElementById('terminal-settings-status').textContent = mode;
}

// Initialize on page load
document.addEventListener('DOMContentLoaded', () => {
  loadTerminalSettings();

  document.getElementById('apply-terminal-settings').addEventListener('click', saveTerminalSettings);
});
```

#### CSS Styling
```css
.control-panel {
  background: #f5f5f5;
  border: 1px solid #ddd;
  border-radius: 8px;
  padding: 20px;
  margin: 20px 0;
}

.control-group {
  margin: 15px 0;
  display: flex;
  align-items: center;
  gap: 10px;
}

.switch {
  position: relative;
  display: inline-block;
  width: 50px;
  height: 24px;
}

.switch input {
  opacity: 0;
  width: 0;
  height: 0;
}

.slider {
  position: absolute;
  cursor: pointer;
  top: 0;
  left: 0;
  right: 0;
  bottom: 0;
  background-color: #ccc;
  transition: .4s;
  border-radius: 24px;
}

.slider:before {
  position: absolute;
  content: "";
  height: 18px;
  width: 18px;
  left: 3px;
  bottom: 3px;
  background-color: white;
  transition: .4s;
  border-radius: 50%;
}

input:checked + .slider {
  background-color: #2196F3;
}

input:checked + .slider:before {
  transform: translateX(26px);
}

.help-text {
  font-size: 12px;
  color: #666;
}

.status-message {
  margin-top: 10px;
  padding: 10px;
  border-radius: 4px;
  font-weight: bold;
}

.status-message.success {
  background: #d4edda;
  color: #155724;
}

.status-message.error {
  background: #f8d7da;
  color: #721c24;
}
```

## Usage Instructions

### For Testing/Development (Terminal Windows ON)
```bash
# Via dashboard:
1. Open dashboard at http://localhost:3000
2. Navigate to Terminal Control panel
3. Enable "Show Terminal Windows"
4. Disable "Force Headless Mode"
5. Set Auto-Close Duration as desired (0 = keep open)
6. Click "Apply Settings"

# Via CLI:
jq '.terminal_windows_enabled = true | .headless_mode = false' \
  coordination/config/terminal-settings.json > /tmp/settings.json
mv /tmp/settings.json coordination/config/terminal-settings.json
```

### For Production (Headless Mode ON)
```bash
# Via dashboard:
1. Open dashboard at http://localhost:3000
2. Navigate to Terminal Control panel
3. Disable "Show Terminal Windows" OR Enable "Force Headless Mode"
4. Click "Apply Settings"

# Via CLI:
jq '.headless_mode = true' \
  coordination/config/terminal-settings.json > /tmp/settings.json
mv /tmp/settings.json coordination/config/terminal-settings.json
```

## Benefits

1. **Cleaner Testing**: Enable terminals during active development, disable for overnight runs
2. **Production Ready**: Run headless in production without Terminal.app clutter
3. **Auto-Cleanup**: Optional auto-close prevents accumulation of terminal windows
4. **Real-Time Control**: No daemon restart required - settings apply to next worker launch
5. **Dashboard Integration**: Easy on/off toggle without touching config files

## Testing Checklist

- [ ] Verify terminal settings file is created with defaults
- [ ] Test Terminal mode launches workers in visible windows
- [ ] Test Headless mode launches workers without windows
- [ ] Test auto-close duration closes terminals after specified time
- [ ] Verify dashboard API endpoints work (GET/POST)
- [ ] Verify dashboard UI loads and displays current settings
- [ ] Test toggling settings via dashboard
- [ ] Verify new settings apply to newly launched workers
- [ ] Test with 20+ workers to confirm reduced window clutter in headless mode

## Next Steps

1. Add API endpoints to dashboard/server/index.js
2. Add UI components to dashboard/public/index.html
3. Test both modes (terminal vs headless)
4. Document user-facing feature in main README
5. Consider adding "Close All Terminal Windows" button for quick cleanup
