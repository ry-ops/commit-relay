#!/bin/bash
# Simple incident logger for health alerts that exceed SLA

ALERT_ID="${1}"
WORKER_ID="${2}"
OUTCOME="${3:-sla_exceeded}"
NOTES="${4:-No additional notes}"

if [ -z "$ALERT_ID" ] || [ -z "$WORKER_ID" ]; then
    echo "Usage: $0 <alert_id> <worker_id> [outcome] [notes]"
    exit 1
fi

INCIDENT_DIR="coordination/health-incidents"
INCIDENT_FILE="${INCIDENT_DIR}/$(date +%Y-%m-%d)-${ALERT_ID}.log"

# Create incident log
cat >> "$INCIDENT_FILE" << EOF
================================================================================
HEALTH ALERT INCIDENT REPORT
================================================================================
Incident ID: inc-$(date +%s)
Alert ID: ${ALERT_ID}
Worker ID: ${WORKER_ID}
Outcome: ${OUTCOME}
Timestamp: $(date +"%Y-%m-%dT%H:%M:%S%z")

DETAILS:
${NOTES}

NEXT STEPS:
- Review worker logs for details
- Check if issue persists
- Consider manual intervention
- Update alert status to 'needs_review'

================================================================================
EOF

echo "Incident logged: $INCIDENT_FILE"

# Update alert status to needs_review
if [ -f "coordination/health-alerts.json" ]; then
    jq --arg aid "$ALERT_ID" \
       '(.alerts[] | select(.id == $aid) | .status) = "needs_review"' \
       coordination/health-alerts.json > /tmp/alerts.json && \
    mv /tmp/alerts.json coordination/health-alerts.json
    echo "Updated alert $ALERT_ID status to 'needs_review'"
fi
