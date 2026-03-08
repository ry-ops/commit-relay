# Known Issues - Coordination Files

## 1. Duplicate Task IDs in task-queue.json

**Issue**: The task-queue.json file contains duplicate task IDs, which breaks Alpine.js rendering on the dashboard.

**Evidence**:
- 4 tasks with ID "task-012"
- 2 tasks with empty ID ""

**Impact**: 
- Alpine.js x-for requires unique :key values
- Duplicate keys cause "Alpine Warning: Duplicate key on x-for" errors
- Results in "Cannot read properties of undefined (reading 'after')" crash
- Dashboard fails to render task table

**Workaround**:
- Dashboard now uses array index as key instead of task.id
- See dashboard/public/index.html line 449: `:key="'task-' + index"`

**Root Cause**:
- scripts/create-task.sh has a bug generating task IDs
- Line 147: octal number error with leading zeros (e.g., "019")
- Some tasks created without proper ID assignment

**TODO**:
1. Fix create-task.sh to generate unique IDs correctly
2. Clean up task-queue.json to remove duplicates
3. Add validation to prevent duplicate IDs from being created
4. Consider using UUID instead of sequential IDs

**History**:
- First encountered: 2025-11-05
- Workaround added: commit f5b089f
- This issue has occurred before (per user feedback)

---

## 2. Duplicate Event IDs in dashboard-events.jsonl

**Issue**: Dashboard events have duplicate IDs, which breaks Alpine.js rendering on the dashboard overview and events pages.

**Evidence**:
- 4 events with ID "task-created-task-012"
- 4 events with ID "task-completed-task-012"
- 2 events with ID "task-created-"

**Impact**:
- Alpine.js x-for requires unique :key values
- Duplicate keys cause "Alpine Warning: Duplicate key on x-for" errors
- Results in "Cannot read properties of undefined (reading 'after')" crash
- Dashboard fails to render events on overview page, events page, and masters page

**Workaround**:
- Dashboard now uses array index as key instead of event.id
- See dashboard/public/index.html:
  - Line 356: Overview events `:key="'overview-event-' + eventIndex"`
  - Line 520: Events page `:key="'events-page-' + eventIndex"`
  - Line 572-676: Master-specific events (coordinator, security, dev, inventory, cicd)

**Root Cause**:
- Event IDs are generated from task IDs
- Duplicate task IDs lead to duplicate event IDs
- Same root cause as issue #1

**TODO**:
1. Fix task ID generation (see issue #1)
2. Regenerate event IDs or use UUID
3. Clean up dashboard-events.jsonl to remove duplicates
4. Add validation to prevent duplicate event IDs

**Affected Locations**:
- 7 x-for loops fixed in dashboard/public/index.html
- All now use index-based keys for stability

**History**:
- First encountered: 2025-11-05
- Workaround added: commit ceac7a7 (same session as task ID fix)
- User identified this as same root cause
- All 7 event x-for loops fixed successfully
- Dashboard now displays events correctly with no errors
