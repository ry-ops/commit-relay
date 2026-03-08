/**
 * Condition Evaluator for Workflow Engine
 *
 * Provides safe evaluation of conditional expressions without using eval.
 * Supports variable interpolation using {{ }} syntax and common comparison operators.
 *
 * Supported operators:
 * - Comparison: ==, !=, >, <, >=, <=
 * - Membership: in, not in
 * - Logical: and, or, not
 * - Parentheses for grouping
 */

class ConditionEvaluator {
  constructor(options = {}) {
    this.debug = options.debug || false;

    // Operator precedence (higher = binds tighter)
    this.precedence = {
      'or': 1,
      'and': 2,
      'not': 3,
      '==': 4,
      '!=': 4,
      '<': 5,
      '>': 5,
      '<=': 5,
      '>=': 5,
      'in': 6,
      'not in': 6
    };
  }

  /**
   * Evaluate a condition expression against a context
   * @param {string} condition - The condition expression
   * @param {Object} context - The context object with variables
   * @returns {boolean} Result of evaluation
   */
  evaluate(condition, context) {
    if (!condition || typeof condition !== 'string') {
      return true; // No condition means always execute
    }

    try {
      // Step 1: Resolve all {{ }} variable references
      const resolved = this.resolveVariables(condition, context);

      // Step 2: Tokenize the resolved expression
      const tokens = this.tokenize(resolved);

      // Step 3: Parse and evaluate
      const result = this.evaluateTokens(tokens);

      if (this.debug) {
        console.log(`Condition: ${condition}`);
        console.log(`Resolved: ${resolved}`);
        console.log(`Result: ${result}`);
      }

      return Boolean(result);

    } catch (error) {
      console.warn(`Condition evaluation failed: ${condition} - ${error.message}`);
      return false;
    }
  }

  /**
   * Resolve {{ variable }} syntax in an expression
   * @param {string} expr - Expression containing {{ }} syntax
   * @param {Object} context - Context object
   * @returns {string} Expression with variables resolved
   */
  resolveVariables(expr, context) {
    return expr.replace(
      /\{\{\s*([^}]+)\s*\}\}/g,
      (match, varExpr) => {
        const value = this._resolveVariablePath(varExpr.trim(), context);
        return this._serializeValue(value);
      }
    );
  }

  /**
   * Resolve a dot-notation variable path against context
   * @param {string} path - Variable path (e.g., 'steps.test.outputs.passed')
   * @param {Object} context - Context object
   * @returns {*} Resolved value
   */
  _resolveVariablePath(path, context) {
    // Handle array index notation: steps.scan.outputs.items[0]
    const parts = path.split(/\.|\[|\]/).filter(p => p !== '');
    let value = context;

    for (const part of parts) {
      if (value === undefined || value === null) {
        return undefined;
      }

      // Check if part is numeric (array index)
      const index = parseInt(part, 10);
      if (!isNaN(index) && Array.isArray(value)) {
        value = value[index];
      } else {
        value = value[part];
      }
    }

    return value;
  }

  /**
   * Serialize a value for use in the expression
   * @param {*} value - Value to serialize
   * @returns {string} Serialized representation
   */
  _serializeValue(value) {
    if (value === undefined) {
      return 'null';
    }
    if (value === null) {
      return 'null';
    }
    if (typeof value === 'string') {
      // Escape quotes in strings
      const escaped = value.replace(/'/g, "\\'").replace(/"/g, '\\"');
      return `"${escaped}"`;
    }
    if (typeof value === 'boolean') {
      return value ? 'true' : 'false';
    }
    if (typeof value === 'number') {
      return String(value);
    }
    if (Array.isArray(value)) {
      return JSON.stringify(value);
    }
    if (typeof value === 'object') {
      return JSON.stringify(value);
    }
    return String(value);
  }

  /**
   * Tokenize an expression into tokens
   * @param {string} expr - Expression to tokenize
   * @returns {Array} Array of tokens
   */
  tokenize(expr) {
    const tokens = [];
    let i = 0;

    while (i < expr.length) {
      // Skip whitespace
      if (/\s/.test(expr[i])) {
        i++;
        continue;
      }

      // Parentheses
      if (expr[i] === '(' || expr[i] === ')') {
        tokens.push({ type: 'paren', value: expr[i] });
        i++;
        continue;
      }

      // String literals (single or double quotes)
      if (expr[i] === '"' || expr[i] === "'") {
        const quote = expr[i];
        let str = '';
        i++;
        while (i < expr.length && expr[i] !== quote) {
          if (expr[i] === '\\' && i + 1 < expr.length) {
            i++;
            str += expr[i];
          } else {
            str += expr[i];
          }
          i++;
        }
        i++; // Skip closing quote
        tokens.push({ type: 'string', value: str });
        continue;
      }

      // Array literals
      if (expr[i] === '[') {
        let depth = 1;
        let arrayStr = '[';
        i++;
        while (i < expr.length && depth > 0) {
          if (expr[i] === '[') depth++;
          if (expr[i] === ']') depth--;
          arrayStr += expr[i];
          i++;
        }
        try {
          const arr = JSON.parse(arrayStr);
          tokens.push({ type: 'array', value: arr });
        } catch (e) {
          throw new Error(`Invalid array literal: ${arrayStr}`);
        }
        continue;
      }

      // Numbers
      if (/[\d.-]/.test(expr[i]) && (expr[i] !== '-' || tokens.length === 0 || tokens[tokens.length - 1].type === 'operator')) {
        let num = '';
        while (i < expr.length && /[\d.e+-]/.test(expr[i])) {
          num += expr[i];
          i++;
        }
        const parsed = parseFloat(num);
        if (isNaN(parsed)) {
          throw new Error(`Invalid number: ${num}`);
        }
        tokens.push({ type: 'number', value: parsed });
        continue;
      }

      // Operators and keywords
      // Check multi-character operators first
      const remaining = expr.slice(i).toLowerCase();

      // Check for 'not in' first (before 'not')
      if (remaining.startsWith('not in') && !/[a-z]/.test(remaining[6] || '')) {
        tokens.push({ type: 'operator', value: 'not in' });
        i += 6;
        continue;
      }

      // Two-character operators
      const twoChar = expr.slice(i, i + 2);
      if (['==', '!=', '<=', '>='].includes(twoChar)) {
        tokens.push({ type: 'operator', value: twoChar });
        i += 2;
        continue;
      }

      // Single-character operators
      if (['<', '>'].includes(expr[i])) {
        tokens.push({ type: 'operator', value: expr[i] });
        i++;
        continue;
      }

      // Keywords: and, or, not, in, true, false, null
      if (/[a-z]/i.test(expr[i])) {
        let word = '';
        while (i < expr.length && /[a-z_]/i.test(expr[i])) {
          word += expr[i];
          i++;
        }
        const lower = word.toLowerCase();

        if (lower === 'true') {
          tokens.push({ type: 'boolean', value: true });
        } else if (lower === 'false') {
          tokens.push({ type: 'boolean', value: false });
        } else if (lower === 'null' || lower === 'none') {
          tokens.push({ type: 'null', value: null });
        } else if (['and', 'or', 'not', 'in'].includes(lower)) {
          tokens.push({ type: 'operator', value: lower });
        } else {
          throw new Error(`Unknown identifier: ${word}`);
        }
        continue;
      }

      throw new Error(`Unexpected character: ${expr[i]} at position ${i}`);
    }

    return tokens;
  }

  /**
   * Evaluate tokenized expression using recursive descent parser
   * @param {Array} tokens - Array of tokens
   * @returns {*} Evaluation result
   */
  evaluateTokens(tokens) {
    let pos = 0;

    const peek = () => tokens[pos];
    const consume = () => tokens[pos++];

    // Parse OR expressions (lowest precedence)
    const parseOr = () => {
      let left = parseAnd();

      while (peek() && peek().type === 'operator' && peek().value === 'or') {
        consume(); // consume 'or'
        const right = parseAnd();
        left = left || right;
      }

      return left;
    };

    // Parse AND expressions
    const parseAnd = () => {
      let left = parseNot();

      while (peek() && peek().type === 'operator' && peek().value === 'and') {
        consume(); // consume 'and'
        const right = parseNot();
        left = left && right;
      }

      return left;
    };

    // Parse NOT expressions
    const parseNot = () => {
      if (peek() && peek().type === 'operator' && peek().value === 'not') {
        consume(); // consume 'not'
        return !parseNot();
      }
      return parseComparison();
    };

    // Parse comparison expressions
    const parseComparison = () => {
      let left = parsePrimary();

      const compOps = ['==', '!=', '<', '>', '<=', '>=', 'in', 'not in'];

      while (peek() && peek().type === 'operator' && compOps.includes(peek().value)) {
        const op = consume().value;
        const right = parsePrimary();

        switch (op) {
          case '==':
            left = this._equals(left, right);
            break;
          case '!=':
            left = !this._equals(left, right);
            break;
          case '<':
            left = left < right;
            break;
          case '>':
            left = left > right;
            break;
          case '<=':
            left = left <= right;
            break;
          case '>=':
            left = left >= right;
            break;
          case 'in':
            left = this._in(left, right);
            break;
          case 'not in':
            left = !this._in(left, right);
            break;
        }
      }

      return left;
    };

    // Parse primary expressions (values, parentheses)
    const parsePrimary = () => {
      const token = peek();

      if (!token) {
        throw new Error('Unexpected end of expression');
      }

      // Parenthesized expression
      if (token.type === 'paren' && token.value === '(') {
        consume(); // consume '('
        const result = parseOr();
        if (!peek() || peek().value !== ')') {
          throw new Error('Missing closing parenthesis');
        }
        consume(); // consume ')'
        return result;
      }

      // Literal values
      if (['string', 'number', 'boolean', 'null', 'array'].includes(token.type)) {
        consume();
        return token.value;
      }

      throw new Error(`Unexpected token: ${JSON.stringify(token)}`);
    };

    const result = parseOr();

    if (pos < tokens.length) {
      throw new Error(`Unexpected token at end: ${JSON.stringify(tokens[pos])}`);
    }

    return result;
  }

  /**
   * Compare two values for equality (deep comparison for objects/arrays)
   * @param {*} a - First value
   * @param {*} b - Second value
   * @returns {boolean} Whether values are equal
   */
  _equals(a, b) {
    // Handle null/undefined
    if (a === null || a === undefined) {
      return b === null || b === undefined;
    }
    if (b === null || b === undefined) {
      return false;
    }

    // Handle arrays and objects
    if (typeof a === 'object' || typeof b === 'object') {
      return JSON.stringify(a) === JSON.stringify(b);
    }

    // Handle type coercion for common cases
    if (typeof a === 'string' && typeof b === 'number') {
      return a === String(b);
    }
    if (typeof a === 'number' && typeof b === 'string') {
      return String(a) === b;
    }

    return a === b;
  }

  /**
   * Check if a value is in a collection
   * @param {*} value - Value to check
   * @param {*} collection - Collection to check against
   * @returns {boolean} Whether value is in collection
   */
  _in(value, collection) {
    if (Array.isArray(collection)) {
      return collection.some(item => this._equals(value, item));
    }
    if (typeof collection === 'string') {
      return collection.includes(String(value));
    }
    if (typeof collection === 'object' && collection !== null) {
      return value in collection;
    }
    return false;
  }

  /**
   * Validate a condition expression without evaluating it
   * @param {string} condition - Condition to validate
   * @returns {Object} Validation result with isValid and errors
   */
  validate(condition) {
    const errors = [];

    if (!condition || typeof condition !== 'string') {
      return { isValid: true, errors: [] };
    }

    try {
      // Check for unresolved variables (shouldn't have any {{ }})
      const unresolvedVars = condition.match(/\{\{\s*[^}]+\s*\}\}/g);
      if (unresolvedVars) {
        // This is fine during validation - variables will be resolved at runtime
      }

      // Try to resolve with empty context to check syntax
      const resolved = this.resolveVariables(condition, {
        inputs: {},
        steps: {},
        env: {}
      });

      // Tokenize to check syntax
      this.tokenize(resolved);

      return { isValid: true, errors: [] };

    } catch (error) {
      errors.push(error.message);
      return { isValid: false, errors };
    }
  }

  /**
   * Extract variable references from a condition
   * @param {string} condition - Condition expression
   * @returns {Array} Array of variable paths
   */
  extractVariables(condition) {
    const variables = [];
    const regex = /\{\{\s*([^}]+)\s*\}\}/g;
    let match;

    while ((match = regex.exec(condition)) !== null) {
      variables.push(match[1].trim());
    }

    return variables;
  }
}

module.exports = ConditionEvaluator;
