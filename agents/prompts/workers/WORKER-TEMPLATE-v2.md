# [Worker Name] Worker

**Specialist Agent for [Primary Function]**
*Token Budget: [X,000] | Timeout: [X]min | Master: [master-name]*

---

## Commands (Execute These First)

```bash
# 1. Read worker spec
jq . coordination/worker-specs/active/$(ls coordination/worker-specs/active/ | grep [worker-type]).json

# 2. Extract task parameters from spec
PARAM=$(jq -r '.scope.param' coordination/worker-specs/active/[spec].json)

# 3. Navigate to workspace
cd ~/[repo-or-workspace]

# 4. [Worker-specific setup command]

# 5. [Execute primary task]

# 6. [Verify results]

# 7. [Generate report]
```

---

## Tech Stack

**[Category 1]**:
- Tool 1: Description and version
- Tool 2: Description and version
- Tool 3: Description and version

**[Category 2]**:
- Tool 4: Description and version
- Tool 5: Description and version

---

## Always Do

✅ **[Action 1]** - Explanation and rationale
✅ **[Action 2]** - Explanation and rationale
✅ **[Action 3]** - Explanation and rationale
✅ **[Action 4]** - Explanation and rationale
✅ **[Action 5]** - Explanation and rationale
✅ **Generate report** - JSON + markdown summary
✅ **Track token usage** - Monitor budget throughout
✅ **Verify completion criteria** - Check acceptance criteria met

---

## Ask First

⚠️ **[Action requiring permission 1]** - Rationale and risk
⚠️ **[Action requiring permission 2]** - Rationale and risk
⚠️ **[Action requiring permission 3]** - Rationale and risk

---

## Never Do

❌ **[Anti-pattern 1]** - Why this is problematic
❌ **[Anti-pattern 2]** - Why this is problematic
❌ **[Anti-pattern 3]** - Why this is problematic
❌ **[Anti-pattern 4]** - Why this is problematic

---

## Real [Task Type] Examples

### Example 1: [Scenario Name]

**Before** (Problematic):
```[language]
// ❌ Current implementation with issues
[problematic code example]
```

**After** (Correct):
```[language]
// ✅ Improved implementation
[corrected code example]
```

**Why**: Explanation of what was wrong and why the fix works.

**Verification**:
```[language]
// Test to verify the fix
[test code example]
```

---

### Example 2: [Another Scenario]

```[language]
// Example code demonstrating best practice
[code example]
```

**Explanation**: Description of what this example demonstrates and why it's the right approach.

---

## [Task Type] Workflow

### 1. Initialize (1min)
```bash
# Read spec and extract parameters
TASK_ID=$(jq -r '.task_id' [spec].json)
PARAM1=$(jq -r '.scope.param1' [spec].json)

# Setup workspace
cd ~/[workspace]
```

### 2. [Phase 2 Name] (X-Y min)
- Step 1 description
- Step 2 description
- Step 3 description

```bash
# Commands for this phase
command1
command2
```

### 3. [Phase 3 Name] (X-Y min)
- Step 1 description
- Step 2 description

```bash
# Commands for this phase
command3
command4
```

### 4. Verify Results (X min)
```bash
# Verification commands
verify_command
```

### 5. Generate Report (X min)
```json
{
  "worker_id": "worker-[type]-[id]",
  "task_id": "task-[id]",
  "repository": "[repo-name]",
  "[timestamp_field]": "2025-11-26T00:00:00-06:00",
  "summary": {
    "status": "success",
    "[metric1]": 0,
    "[metric2]": 0
  },
  "[results_section]": {
    "[field1]": "value1",
    "[field2]": "value2"
  },
  "metrics": {
    "duration_minutes": 0,
    "tokens_used": 0
  }
}
```

### 6. Update Coordination (1min)
```bash
# Save results
mkdir -p agents/logs/workers/$(date +%Y-%m-%d)/$WORKER_ID
cp [report].json agents/logs/workers/$(date +%Y-%m-%d)/$WORKER_ID/

# Commit
git add agents/logs/
git commit -m "[type](worker): [worker-id] completed [task-description]

[Summary of work completed]

Worker: $WORKER_ID
Tokens: $TOKENS_USED

🤖 Generated with Claude Code
Co-Authored-By: Claude <noreply@anthropic.com>"

git push origin main
```

---

## Completion Checklist

Before marking task complete:

- [ ] Worker spec read and understood
- [ ] [Task-specific criterion 1]
- [ ] [Task-specific criterion 2]
- [ ] [Task-specific criterion 3]
- [ ] [Task-specific criterion 4]
- [ ] [Task-specific criterion 5]
- [ ] Report generated (JSON + markdown)
- [ ] Token usage under budget
- [ ] Coordination updated
- [ ] Changes committed and pushed

---

## [Task Type] Types Reference

### [Type 1]
**Description**: What this type involves
**When to use**: Specific scenarios
**Key considerations**: Important factors

### [Type 2]
**Description**: What this type involves
**When to use**: Specific scenarios
**Key considerations**: Important factors

---

## Decision Matrix / Strategies

### [Decision Point or Strategy Type]

**Use when**: Condition for using this approach

**Steps**:
1. Step one
2. Step two
3. Step three

---

**Remember**: You are a **[worker specialty] specialist**. [Key principle 1]. [Key principle 2]. [Key principle 3]. [Memorable motto or guideline].

---

*Worker Type: [worker-name]-worker v2.0*

---

## Template Usage Instructions

This template follows the AGENTS.md format optimized for Claude Code workers based on GitHub's research of 2,500+ repositories. When creating a new worker prompt:

### Structure Requirements

1. **Commands Section** - Executable commands with specific flags
2. **Tech Stack** - Versions and tool specifications
3. **Three-Tier Boundaries** - Always Do / Ask First / Never Do
4. **Real Examples** - Full code implementations, not abstractions
5. **Workflow** - Step-by-step with time estimates
6. **Completion Checklist** - Concrete verification criteria

### Writing Guidelines

- **Commands**: Use real bash with actual flags, not pseudocode
- **Examples**: Show before/after code, explain why
- **Boundaries**: Be specific about actions, not generic
- **Workflow**: Include bash commands in code blocks
- **Tone**: Direct and actionable, not abstract

### Common Mistakes to Avoid

❌ Don't: "Set up your environment"
✅ Do: `cd ~/repo && git checkout main && git pull`

❌ Don't: "Write good tests"
✅ Do: "Write tests covering happy path, edge cases, and error scenarios"

❌ Don't: "Handle errors appropriately"
✅ Do: "Add try-catch with logging and throw custom error types"

### Format Validation

Before finalizing a new worker prompt, verify:
- [ ] Commands section has executable bash (no placeholders)
- [ ] Tech stack includes version numbers
- [ ] Always/Ask/Never sections have 5+ items each
- [ ] Real examples include full code, not snippets
- [ ] Workflow has time estimates for each phase
- [ ] Checklist has 10+ concrete items
