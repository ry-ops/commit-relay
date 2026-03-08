/**
 * Review Executor - Quality Review Loops for Task Output
 *
 * Provides LLM-based quality review for task outputs with:
 * - Configurable review cycles and confidence thresholds
 * - Task-type-specific review prompts
 * - Structured feedback for iterative refinement
 * - Integration with LLM gateway
 *
 * Part of commit-relay orchestration system.
 */

const fs = require('fs');
const path = require('path');

// Default config path
const DEFAULT_POLICY_PATH = path.join(__dirname, '../../coordination/config/review-policy.json');

/**
 * ReviewExecutor class for managing quality review cycles
 */
class ReviewExecutor {
  constructor(options = {}) {
    this.policyPath = options.policyPath || DEFAULT_POLICY_PATH;
    this.llmGateway = options.llmGateway || null;
    this.policy = null;
    this.loadPolicy();
  }

  /**
   * Load review policy configuration
   */
  loadPolicy() {
    try {
      if (fs.existsSync(this.policyPath)) {
        const content = fs.readFileSync(this.policyPath, 'utf8');
        this.policy = JSON.parse(content);
      } else {
        // Use default policy if file doesn't exist
        this.policy = this.getDefaultPolicy();
      }
    } catch (error) {
      console.error(`[ReviewExecutor] Failed to load policy: ${error.message}`);
      this.policy = this.getDefaultPolicy();
    }
  }

  /**
   * Get default policy when config file is unavailable
   */
  getDefaultPolicy() {
    return {
      enabled: true,
      default_cycles: 1,
      max_cycles: 3,
      confidence_threshold: 0.85,
      auto_approve_threshold: 0.95,
      review_prompts: {
        code: {
          system: 'You are an expert code reviewer focused on quality, correctness, and best practices.',
          focus_areas: ['correctness', 'security', 'performance', 'maintainability', 'test_coverage']
        },
        security: {
          system: 'You are a security expert reviewing code for vulnerabilities and security best practices.',
          focus_areas: ['vulnerabilities', 'authentication', 'authorization', 'data_validation', 'secrets_exposure']
        },
        documentation: {
          system: 'You are a technical writer reviewing documentation for clarity, completeness, and accuracy.',
          focus_areas: ['clarity', 'completeness', 'accuracy', 'examples', 'formatting']
        }
      },
      task_overrides: {}
    };
  }

  /**
   * Main review method - evaluates task output quality
   *
   * @param {object} task - Task definition with type, requirements, etc.
   * @param {object} output - Task output to review
   * @returns {Promise<object>} Review result with approval status, confidence, feedback
   */
  async review(task, output) {
    if (!this.policy.enabled) {
      return {
        approved: true,
        confidence: 1.0,
        feedback: 'Review disabled - auto-approved',
        suggestions: [],
        review_skipped: true
      };
    }

    // Build the review prompt
    const prompt = this.buildReviewPrompt(task, output);

    // Call LLM for review
    let reviewResponse;
    try {
      reviewResponse = await this.callLLM(prompt);
    } catch (error) {
      console.error(`[ReviewExecutor] LLM call failed: ${error.message}`);
      // Return conservative result on error
      return {
        approved: false,
        confidence: 0.0,
        feedback: `Review failed: ${error.message}`,
        suggestions: ['Retry review or escalate for manual review'],
        error: error.message
      };
    }

    // Parse and structure the review response
    const result = this.parseReviewResponse(reviewResponse, task);

    // Apply auto-approve logic
    if (result.confidence >= this.getAutoApproveThreshold(task)) {
      result.approved = true;
      result.auto_approved = true;
    } else if (result.confidence >= this.getConfidenceThreshold(task)) {
      result.approved = true;
    } else {
      result.approved = false;
    }

    return result;
  }

  /**
   * Build review prompt based on task type and output
   *
   * @param {object} task - Task definition
   * @param {object} output - Task output to review
   * @returns {object} Prompt object with system and user messages
   */
  buildReviewPrompt(task, output) {
    const taskType = this.getTaskType(task);
    const promptConfig = this.policy.review_prompts[taskType] || this.policy.review_prompts.code;

    // Get task-specific overrides
    const overrides = this.policy.task_overrides[task.type] || {};
    const focusAreas = overrides.focus_areas || promptConfig.focus_areas;

    const systemPrompt = promptConfig.system;

    const userPrompt = `
## Task Review Request

### Task Information
- **Task ID**: ${task.id || 'unknown'}
- **Task Type**: ${task.type || taskType}
- **Priority**: ${task.priority || 'medium'}
- **Description**: ${task.description || 'No description provided'}

### Requirements
${this.formatRequirements(task.requirements || task.scope || {})}

### Output to Review
\`\`\`
${this.formatOutput(output)}
\`\`\`

### Review Focus Areas
${focusAreas.map(area => `- ${area}`).join('\n')}

### Instructions
Please review the output above and provide:

1. **Confidence Score** (0.0 to 1.0): How confident are you that this output meets the requirements?
2. **Feedback**: Specific observations about quality, correctness, and completeness
3. **Suggestions**: Actionable improvements if confidence is below 0.95
4. **Issues**: Any critical problems that must be addressed

Respond in the following JSON format:
\`\`\`json
{
  "confidence": 0.85,
  "feedback": "Overall assessment of the output quality",
  "suggestions": ["suggestion 1", "suggestion 2"],
  "issues": ["critical issue 1"],
  "strengths": ["strength 1", "strength 2"]
}
\`\`\`
`;

    return {
      system: systemPrompt,
      user: userPrompt,
      taskType,
      focusAreas
    };
  }

  /**
   * Determine task type for review prompt selection
   */
  getTaskType(task) {
    const type = (task.type || '').toLowerCase();

    if (type.includes('security') || type.includes('scan') || type.includes('audit')) {
      return 'security';
    } else if (type.includes('doc') || type.includes('readme') || type.includes('comment')) {
      return 'documentation';
    } else {
      return 'code';
    }
  }

  /**
   * Format requirements for prompt
   */
  formatRequirements(requirements) {
    if (typeof requirements === 'string') {
      return requirements;
    }

    if (Array.isArray(requirements)) {
      return requirements.map((req, i) => `${i + 1}. ${req}`).join('\n');
    }

    return Object.entries(requirements)
      .map(([key, value]) => `- **${key}**: ${JSON.stringify(value)}`)
      .join('\n');
  }

  /**
   * Format output for prompt
   */
  formatOutput(output) {
    if (typeof output === 'string') {
      return output;
    }

    return JSON.stringify(output, null, 2);
  }

  /**
   * Call LLM gateway for review
   * Compatible with LLM gateway being implemented in parallel
   */
  async callLLM(prompt) {
    // If LLM gateway is provided, use it
    if (this.llmGateway) {
      return await this.llmGateway.complete({
        system: prompt.system,
        messages: [{ role: 'user', content: prompt.user }],
        temperature: 0.3, // Lower temperature for more consistent reviews
        max_tokens: 2000
      });
    }

    // Fallback: Check for environment-based LLM access
    if (process.env.LLM_GATEWAY_URL) {
      const response = await fetch(process.env.LLM_GATEWAY_URL + '/complete', {
        method: 'POST',
        headers: {
          'Content-Type': 'application/json',
          'Authorization': `Bearer ${process.env.LLM_GATEWAY_TOKEN || ''}`
        },
        body: JSON.stringify({
          system: prompt.system,
          messages: [{ role: 'user', content: prompt.user }],
          temperature: 0.3,
          max_tokens: 2000
        })
      });

      if (!response.ok) {
        throw new Error(`LLM gateway error: ${response.status}`);
      }

      return await response.json();
    }

    // Mock response for testing/development
    console.warn('[ReviewExecutor] No LLM gateway configured - returning mock response');
    return this.getMockResponse(prompt);
  }

  /**
   * Parse LLM response into structured review result
   */
  parseReviewResponse(response, task) {
    try {
      // Handle different response formats
      let content = response;

      if (typeof response === 'object') {
        content = response.content || response.text || response.message || JSON.stringify(response);
      }

      // Extract JSON from response
      const jsonMatch = content.match(/```json\s*([\s\S]*?)\s*```/);
      let parsed;

      if (jsonMatch) {
        parsed = JSON.parse(jsonMatch[1]);
      } else {
        // Try parsing the whole response as JSON
        parsed = JSON.parse(content);
      }

      return {
        confidence: parsed.confidence || 0.5,
        feedback: parsed.feedback || 'No feedback provided',
        suggestions: parsed.suggestions || [],
        issues: parsed.issues || [],
        strengths: parsed.strengths || [],
        raw_response: content
      };
    } catch (error) {
      console.error(`[ReviewExecutor] Failed to parse response: ${error.message}`);

      // Return conservative result on parse error
      return {
        confidence: 0.5,
        feedback: 'Unable to parse review response',
        suggestions: ['Manual review recommended'],
        issues: ['Review response parsing failed'],
        strengths: [],
        parse_error: error.message,
        raw_response: response
      };
    }
  }

  /**
   * Get confidence threshold for task (with overrides)
   */
  getConfidenceThreshold(task) {
    const override = this.policy.task_overrides[task.type];
    if (override && override.confidence_threshold) {
      return override.confidence_threshold;
    }
    return this.policy.confidence_threshold;
  }

  /**
   * Get auto-approve threshold for task (with overrides)
   */
  getAutoApproveThreshold(task) {
    const override = this.policy.task_overrides[task.type];
    if (override && override.auto_approve_threshold) {
      return override.auto_approve_threshold;
    }
    return this.policy.auto_approve_threshold;
  }

  /**
   * Get minimum cycles required for task type
   */
  getMinCycles(task) {
    const override = this.policy.task_overrides[task.type];
    if (override && override.min_cycles) {
      return override.min_cycles;
    }
    return this.policy.default_cycles;
  }

  /**
   * Get maximum cycles allowed for task type
   */
  getMaxCycles(task) {
    const override = this.policy.task_overrides[task.type];
    if (override && override.max_cycles) {
      return override.max_cycles;
    }
    return this.policy.max_cycles;
  }

  /**
   * Check if review is enabled for task
   */
  isReviewEnabled(task) {
    // Check global policy
    if (!this.policy.enabled) {
      return false;
    }

    // Check task-level override
    if (task.review && typeof task.review.enabled === 'boolean') {
      return task.review.enabled;
    }

    // Check task-type override
    const override = this.policy.task_overrides[task.type];
    if (override && typeof override.enabled === 'boolean') {
      return override.enabled;
    }

    return true;
  }

  /**
   * Mock response for development/testing
   */
  getMockResponse(prompt) {
    return {
      content: `\`\`\`json
{
  "confidence": 0.85,
  "feedback": "The output appears well-structured and meets most requirements. Minor improvements possible.",
  "suggestions": [
    "Consider adding more inline documentation",
    "Edge cases could be better handled"
  ],
  "issues": [],
  "strengths": [
    "Clean code structure",
    "Good separation of concerns"
  ]
}
\`\`\``,
      mock: true
    };
  }

  /**
   * Reload policy from disk
   */
  reloadPolicy() {
    this.loadPolicy();
  }

  /**
   * Set LLM gateway dynamically
   */
  setLLMGateway(gateway) {
    this.llmGateway = gateway;
  }
}

module.exports = {
  ReviewExecutor
};
