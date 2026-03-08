# Coordination Protocol

## Overview

This document defines the communication protocol used by all agents in the commit-relay system.

## Core Principles

1. **Asynchronous Communication**: Agents don't wait for each other; they communicate via shared state
2. **Git as Transport**: All coordination happens through Git commits
3. **JSON for Structure**: Machine-readable data in JSON format
4. **Markdown for Logs**: Human-readable activity logs in Markdown
5. **Atomic Updates**: Each agent commits their changes atomically

## Check-in Cycle

Every agent follows this cycle at the start of each interaction:

```bash
# 1. Navigate to coordination repository
cd ~/commit-relay

# 2. Pull latest state
git pull origin main

# 3. Read coordination files
# - coordination/task-queue.json
# - coordination/handoffs.json
# - coordination/status.json

# 4. Process assigned work

# 5. Update coordination files

# 6. Log activity
# - agents/logs/{agent-name}/YYYY-MM-DD.md

# 7. Commit changes
git add .
git commit -m "feat(agent): {agent-name} {action description}"
git push origin main
```

## File Structures

### task-queue.json

Maintains the queue of all active, pending, and blocked tasks.

**Schema**:
```json
{
  "version": "1.0",
  "updated_at": "ISO-8601 timestamp",
  "tasks": [
    {
      "id": "unique-task-id",
      "title": "Brief description",
      "type": "category",
      "priority": "critical|high|medium|low",
      "status": "pending|in-progress|blocked|handoff-pending|completed",
      "assigned_to": "agent-name",
      "created_at": "ISO-8601 timestamp",
      "created_by": "agent-name",
      "repository": "owner/repo-name",
      "context": {
        "description": "Detailed description",
        "related_issues": ["#123"],
        "previous_handoffs": []
      },
      "handoff_plan": {
        "after_completion": "next-agent-name",
        "reason": "Why handoff needed"
      }
    }
  ]
}
```

**Status Values**:
- `pending`: Not yet started
- `in-progress`: Currently being worked on
- `blocked`: Cannot proceed, waiting on external factor
- `handoff-pending`: Completed, waiting for next agent to accept
- `completed`: Fully done

### handoffs.json

Tracks work being transferred between agents.

**Schema**:
```json
{
  "version": "1.0",
  "updated_at": "ISO-8601 timestamp",
  "pending_handoffs": [
    {
      "id": "unique-handoff-id",
      "from_agent": "sender-agent",
      "to_agent": "receiver-agent",
      "task_id": "related-task-id",
      "status": "pending|accepted",
      "created_at": "ISO-8601 timestamp",
      "context": {
        "summary": "What was done",
        "deliverables": {
          "branch": "branch-name",
          "commit": "commit-hash",
          "files_changed": ["file1", "file2"]
        },
        "handoff_reason": "Why handing off",
        "notes": "Special instructions for receiver"
      },
      "accepted_at": "ISO-8601 timestamp or null",
      "accepted_by": "agent-name or null"
    }
  ],
  "completed_handoffs": []
}
```

### status.json

Real-time system and agent health status.

**Schema**:
```json
{
  "version": "1.0",
  "updated_at": "ISO-8601 timestamp",
  "agents": {
    "agent-name": {
      "status": "active|inactive|error",
      "last_checkin": "ISO-8601 timestamp",
      "current_tasks": ["task-id-1", "task-id-2"],
      "completed_today": 5,
      "blocked_tasks": [],
      "next_scheduled_checkin": "ISO-8601 timestamp"
    }
  },
  "system_health": {
    "total_active_tasks": 0,
    "pending_handoffs": 0,
    "blocked_tasks": 0,
    "agents_online": 0,
    "last_human_interaction": "ISO-8601 timestamp"
  }
}
```

## Handoff Protocol

### Initiating a Handoff

When an agent completes work that needs to pass to another agent:

1. **Update task status** in task-queue.json:
   ```json
   {
     "status": "handoff-pending"
   }
   ```

2. **Create handoff entry** in handoffs.json:
   ```json
   {
     "id": "handoff-{number}",
     "from_agent": "your-agent-name",
     "to_agent": "target-agent-name",
     "task_id": "task-123",
     "status": "pending",
     "created_at": "2025-10-31T10:00:00Z",
     "context": {
       "summary": "Feature implemented and tested",
       "deliverables": {
         "branch": "feature/task-123",
         "commit": "abc123",
         "files_changed": ["src/file.ts"]
       },
       "handoff_reason": "Ready for security review",
       "notes": "Pay attention to lines 45-67"
     }
   }
   ```

3. **Log in activity log**:
   ```markdown
   ### 10:00 - Created Handoff
   **Handoff ID**: handoff-045
   **To**: security-agent
   **Task**: task-123
   **Reason**: Security review needed before PR
   ```

4. **Commit and push**

### Accepting a Handoff

When an agent finds a pending handoff addressed to them:

1. **Review handoff context** from handoffs.json

2. **Accept handoff** by updating handoffs.json:
   ```json
   {
     "status": "accepted",
     "accepted_at": "2025-10-31T11:00:00Z",
     "accepted_by": "your-agent-name"
   }
   ```

3. **Create or update task** in task-queue.json

4. **Move to completed** handoffs:
   - Remove from `pending_handoffs`
   - Add to `completed_handoffs`

5. **Log acceptance**:
   ```markdown
   ### 11:00 - Accepted Handoff
   **Handoff ID**: handoff-045
   **From**: development-agent
   **Task**: task-123
   **Action**: Beginning security review
   ```

6. **Commit and push**

## Task Lifecycle

```
pending → in-progress → handoff-pending → [next agent] → completed
                    ↓
                  blocked → in-progress
```

1. **Creation**: Coordinator or agent creates task
2. **Assignment**: Task assigned to appropriate agent
3. **Execution**: Agent marks in-progress, does work
4. **Handoff (if needed)**: Agent creates handoff, marks handoff-pending
5. **Acceptance**: Next agent accepts, continues work
6. **Completion**: Final agent marks completed

## Escalation Protocol

When blocked or needing human input:

1. **Update task status**:
   ```json
   {
     "status": "blocked"
   }
   ```

2. **Add to blocked tasks** in status.json

3. **Create escalation task** for coordinator-agent

4. **Log blocker details**:
   ```markdown
   ### 14:00 - Task Blocked
   **Task**: task-123
   **Blocker**: Waiting for API key from external service
   **Impact**: Cannot proceed with integration
   **Escalated To**: coordinator-agent
   ```

5. **Coordinator creates GitHub issue** if human needed

## Commit Message Conventions

Use conventional commits format:

```
<type>(agent): <description>

[optional body]
```

**Types**:
- `feat`: Agent completed a task or feature
- `fix`: Agent fixed an issue
- `docs`: Agent updated documentation
- `chore`: Agent maintenance tasks
- `escalate`: Agent escalating to human

**Examples**:
- `feat(development): completed task-123 OAuth integration`
- `fix(security): patched CVE-2025-12345 in api-server`
- `docs(content): updated README with new features`
- `chore(coordinator): daily system health summary`
- `escalate(coordinator): need decision on agent proposal`

## Conflict Resolution

If Git conflicts occur (rare but possible):

1. **Pull latest**: `git pull origin main`
2. **Review conflicts**: Usually in JSON files
3. **Merge carefully**: Preserve both agents' updates
4. **Verify JSON validity**: `cat file.json | jq .`
5. **Commit merge**: `git commit -m "merge: resolved coordination conflict"`
6. **Log incident**: Document in activity log

To minimize conflicts:
- Commit frequently
- Pull before every update cycle
- Keep commits atomic and focused

## Best Practices

1. **Always pull before updating**: Ensure you have latest state
2. **Log everything**: Over-document rather than under-document
3. **Use ISO-8601 timestamps**: Consistent time format
4. **Validate JSON**: Run `jq` before committing
5. **Atomic commits**: One logical unit per commit
6. **Clear commit messages**: Describe what and why
7. **Check handoffs promptly**: Don't let handoffs wait
8. **Update status regularly**: Keep system health current

## Monitoring

Coordinator Agent monitors:
- Handoffs pending > 2 hours
- Tasks in-progress > 24 hours with no activity
- Blocked tasks increasing
- Agents not checking in within expected schedule
- Repeated patterns suggesting systemic issues

## Debugging

To debug coordination issues:

```bash
# View recent coordination commits
git log --oneline coordination/

# See what changed in last coordination update
git diff HEAD~1 coordination/

# View current task queue
jq '.tasks' coordination/task-queue.json

# Find pending handoffs
jq '.pending_handoffs' coordination/handoffs.json

# Check agent status
jq '.agents' coordination/status.json
```

---

*Version 1.0 - Living document, update as protocol evolves*
