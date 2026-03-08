#!/bin/bash
WORKER_DIR="$(dirname "$0")"
cd "$WORKER_DIR"

# Add NVM paths to ensure claude CLI is available in Terminal.app subprocess
export PATH="/Users/ryandahlberg/.nvm/versions/node/v24.11.0/bin:$PATH"

echo "[$(date -u +%Y-%m-%dT%H:%M:%SZ)] Worker execution starting..." | tee -a logs/stdout.log
echo "[$(date -u +%Y-%m-%dT%H:%M:%SZ)] Working directory: $WORKER_DIR" | tee -a logs/stdout.log
echo "[$(date -u +%Y-%m-%dT%H:%M:%SZ)] Prompt file: prompt.md" | tee -a logs/stdout.log

# Execute Claude Code with prompt file in non-interactive mode
# Use -p flag for headless/non-interactive execution
# Redirect output to logs without using exec/process substitution to avoid TTY issues
cat prompt.md | claude -p >> logs/stdout.log 2>> logs/stderr.log

# Capture exit status
EXIT_CODE=$?

echo "[$(date -u +%Y-%m-%dT%H:%M:%SZ)] Claude Code exited with code: $EXIT_CODE"

# Check for Ink TTY errors in stderr
if grep -q "Raw mode is not supported" logs/stderr.log 2>/dev/null; then
    echo "[$(date -u +%Y-%m-%dT%H:%M:%SZ)] ERROR: Ink TTY error detected"
    echo "{\"status\": \"failed\", \"error\": \"ink_tty_error\", \"exit_code\": $EXIT_CODE, \"timestamp\": \"$(date -u +%Y-%m-%dT%H:%M:%SZ)\"}" > status.json
    exit 1
fi

# Update completion status
if [ $EXIT_CODE -eq 0 ]; then
    echo "{\"status\": \"completed\", \"timestamp\": \"$(date -u +%Y-%m-%dT%H:%M:%SZ)\"}" > status.json
    echo "[$(date -u +%Y-%m-%dT%H:%M:%SZ)] Worker completed successfully"
else
    echo "{\"status\": \"failed\", \"exit_code\": $EXIT_CODE, \"timestamp\": \"$(date -u +%Y-%m-%dT%H:%M:%SZ)\"}" > status.json
    echo "[$(date -u +%Y-%m-%dT%H:%M:%SZ)] Worker failed with exit code: $EXIT_CODE"
fi

exit $EXIT_CODE
