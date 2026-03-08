#!/usr/bin/env bash
#
# Template Validator
# Part of Q2 Week 23-24: Agent Designer & Templates
#
# Validates agent templates against schema and best practices
#

set -euo pipefail

if [[ -z "${SCRIPT_DIR:-}" ]]; then
    readonly SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
fi

if [[ -z "${PROJECT_ROOT:-}" ]]; then
    readonly PROJECT_ROOT="$(cd "$SCRIPT_DIR/../../.." && pwd)"
fi

readonly TEMPLATES_DIR="${TEMPLATES_DIR:-$PROJECT_ROOT/coordination/agentstudio/templates}"
readonly SCHEMA_FILE="${SCHEMA_FILE:-$PROJECT_ROOT/coordination/agentstudio/schemas/agent-template-schema.json}"

#
# Validate JSON syntax
#
validate_json_syntax() {
    local file="$1"

    if ! jq empty "$file" 2>/dev/null; then
        echo "ERROR: Invalid JSON syntax in $file"
        return 1
    fi

    return 0
}

#
# Validate required fields
#
validate_required_fields() {
    local template_file="$1"
    local template=$(cat "$template_file")

    local required_fields=(
        "template_id"
        "name"
        "version"
        "agent_type"
        "agent_class"
        "description"
        "capabilities"
        "scaffold"
        "customization"
    )

    local errors=0

    for field in "${required_fields[@]}"; do
        local value=$(echo "$template" | jq -r ".$field // empty")
        if [[ -z "$value" || "$value" == "null" ]]; then
            echo "ERROR: Missing required field: $field"
            errors=$((errors + 1))
        fi
    done

    return $errors
}

#
# Validate template ID format
#
validate_template_id() {
    local template_file="$1"
    local template_id=$(cat "$template_file" | jq -r '.template_id')

    if [[ ! "$template_id" =~ ^[a-z][a-z0-9-]*$ ]]; then
        echo "ERROR: Invalid template_id format: $template_id (must match ^[a-z][a-z0-9-]*$)"
        return 1
    fi

    return 0
}

#
# Validate agent_type
#
validate_agent_type() {
    local template_file="$1"
    local agent_type=$(cat "$template_file" | jq -r '.agent_type')

    local valid_types=("master" "worker" "learning" "daemon" "utility")
    local valid=false

    for type in "${valid_types[@]}"; do
        if [[ "$agent_type" == "$type" ]]; then
            valid=true
            break
        fi
    done

    if [[ "$valid" == "false" ]]; then
        echo "ERROR: Invalid agent_type: $agent_type (must be one of: ${valid_types[*]})"
        return 1
    fi

    return 0
}

#
# Validate capabilities structure
#
validate_capabilities() {
    local template_file="$1"
    local capabilities=$(cat "$template_file" | jq -c '.capabilities[]?')

    if [[ -z "$capabilities" ]]; then
        echo "ERROR: No capabilities defined"
        return 1
    fi

    local errors=0
    local index=0

    while IFS= read -r cap; do
        if [[ -n "$cap" ]]; then
            local cap_id=$(echo "$cap" | jq -r '.capability_id // empty')
            local cap_name=$(echo "$cap" | jq -r '.name // empty')
            local cap_category=$(echo "$cap" | jq -r '.category // empty')

            if [[ -z "$cap_id" ]]; then
                echo "ERROR: Capability $index missing capability_id"
                errors=$((errors + 1))
            fi

            if [[ -z "$cap_name" ]]; then
                echo "ERROR: Capability $index missing name"
                errors=$((errors + 1))
            fi

            if [[ -z "$cap_category" ]]; then
                echo "ERROR: Capability $index missing category"
                errors=$((errors + 1))
            fi

            index=$((index + 1))
        fi
    done <<< "$capabilities"

    return $errors
}

#
# Validate scaffold configuration
#
validate_scaffold() {
    local template_file="$1"
    local scaffold=$(cat "$template_file" | jq -r '.scaffold')

    if [[ -z "$scaffold" || "$scaffold" == "null" ]]; then
        echo "ERROR: Missing scaffold configuration"
        return 1
    fi

    local script_path=$(echo "$scaffold" | jq -r '.script_path // empty')
    local script_template=$(echo "$scaffold" | jq -r '.script_template // empty')

    if [[ -z "$script_path" ]]; then
        echo "ERROR: Missing scaffold.script_path"
        return 1
    fi

    if [[ -z "$script_template" ]]; then
        echo "ERROR: Missing scaffold.script_template"
        return 1
    fi

    # Check for required template variables
    if [[ ! "$script_path" =~ \{\{agent_name\}\} ]]; then
        echo "WARNING: script_path does not contain {{agent_name}} placeholder"
    fi

    return 0
}

#
# Validate customization parameters
#
validate_customization() {
    local template_file="$1"
    local params=$(cat "$template_file" | jq -c '.customization.parameters[]?')

    if [[ -z "$params" ]]; then
        echo "WARNING: No customization parameters defined"
        return 0
    fi

    local errors=0
    local index=0

    while IFS= read -r param; do
        if [[ -n "$param" ]]; then
            local param_name=$(echo "$param" | jq -r '.name // empty')
            local param_type=$(echo "$param" | jq -r '.type // empty')
            local param_desc=$(echo "$param" | jq -r '.description // empty')

            if [[ -z "$param_name" ]]; then
                echo "ERROR: Parameter $index missing name"
                errors=$((errors + 1))
            fi

            if [[ -z "$param_type" ]]; then
                echo "ERROR: Parameter $index missing type"
                errors=$((errors + 1))
            fi

            if [[ -z "$param_desc" ]]; then
                echo "WARNING: Parameter $param_name missing description"
            fi

            # Validate type
            local valid_types=("string" "integer" "number" "boolean" "array" "object")
            local valid=false
            for type in "${valid_types[@]}"; do
                if [[ "$param_type" == "$type" ]]; then
                    valid=true
                    break
                fi
            done

            if [[ "$valid" == "false" ]]; then
                echo "ERROR: Parameter $param_name has invalid type: $param_type"
                errors=$((errors + 1))
            fi

            index=$((index + 1))
        fi
    done <<< "$params"

    # Check for required agent_name parameter
    local has_agent_name=$(cat "$template_file" | jq -r '.customization.parameters[] | select(.name == "agent_name") | .name')
    if [[ -z "$has_agent_name" ]]; then
        echo "ERROR: Missing required parameter: agent_name"
        errors=$((errors + 1))
    fi

    return $errors
}

#
# Validate variable placeholders
#
validate_placeholders() {
    local template_file="$1"
    local script_template=$(cat "$template_file" | jq -r '.scaffold.script_template')

    # Extract all {{variable}} placeholders
    local placeholders=$(echo "$script_template" | grep -o '{{[a-z_][a-z0-9_]*}}' | sort -u || true)

    if [[ -z "$placeholders" ]]; then
        echo "WARNING: No variable placeholders found in script template"
        return 0
    fi

    local errors=0

    # Check each placeholder has a corresponding parameter
    while IFS= read -r placeholder; do
        if [[ -n "$placeholder" ]]; then
            local var_name="${placeholder//\{\{/}"
            var_name="${var_name//\}\}/}"

            # Skip special variables
            if [[ "$var_name" == "capabilities_json" ]]; then
                continue
            fi

            # Check if parameter exists
            local param_exists=$(cat "$template_file" | jq -r --arg name "$var_name" '.customization.parameters[] | select(.name == $name) | .name')

            if [[ -z "$param_exists" ]]; then
                echo "WARNING: Placeholder {{$var_name}} has no corresponding parameter"
                errors=$((errors + 1))
            fi
        fi
    done <<< "$placeholders"

    return $errors
}

#
# Validate single template
#
validate_template() {
    local template_file="$1"
    local verbose="${2:-false}"

    if [[ ! -f "$template_file" ]]; then
        echo "ERROR: Template file not found: $template_file"
        return 1
    fi

    local template_id=$(basename "$template_file" | sed 's/-template\.json$//')

    if [[ "$verbose" == "true" ]]; then
        echo "Validating template: $template_id"
        echo "File: $template_file"
        echo ""
    fi

    local total_errors=0
    local total_warnings=0

    # Run validations
    if validate_json_syntax "$template_file"; then
        if [[ "$verbose" == "true" ]]; then
            echo "✓ JSON syntax valid"
        fi
    else
        total_errors=$((total_errors + 1))
    fi

    if validate_required_fields "$template_file" 2>&1 | tee /tmp/validate_output.txt | grep -q "ERROR"; then
        cat /tmp/validate_output.txt
        total_errors=$((total_errors + $(grep -c "ERROR" /tmp/validate_output.txt)))
    else
        if [[ "$verbose" == "true" ]]; then
            echo "✓ All required fields present"
        fi
    fi

    if validate_template_id "$template_file"; then
        if [[ "$verbose" == "true" ]]; then
            echo "✓ Template ID format valid"
        fi
    else
        total_errors=$((total_errors + 1))
    fi

    if validate_agent_type "$template_file"; then
        if [[ "$verbose" == "true" ]]; then
            echo "✓ Agent type valid"
        fi
    else
        total_errors=$((total_errors + 1))
    fi

    if validate_capabilities "$template_file" 2>&1 | tee /tmp/validate_output.txt | grep -q "ERROR"; then
        cat /tmp/validate_output.txt
        total_errors=$((total_errors + $(grep -c "ERROR" /tmp/validate_output.txt)))
    else
        if [[ "$verbose" == "true" ]]; then
            echo "✓ Capabilities valid"
        fi
    fi

    if validate_scaffold "$template_file" 2>&1 | tee /tmp/validate_output.txt | grep -q "ERROR"; then
        cat /tmp/validate_output.txt
        local error_count=$(grep -c "ERROR" /tmp/validate_output.txt || true)
        local warning_count=$(grep -c "WARNING" /tmp/validate_output.txt || true)
        total_errors=$((total_errors + error_count))
        total_warnings=$((total_warnings + warning_count))
    else
        if [[ "$verbose" == "true" ]]; then
            echo "✓ Scaffold configuration valid"
        fi
    fi

    if validate_customization "$template_file" 2>&1 | tee /tmp/validate_output.txt | grep -q -E "(ERROR|WARNING)"; then
        cat /tmp/validate_output.txt
        local error_count=$(grep -c "ERROR" /tmp/validate_output.txt || true)
        local warning_count=$(grep -c "WARNING" /tmp/validate_output.txt || true)
        total_errors=$((total_errors + error_count))
        total_warnings=$((total_warnings + warning_count))
    else
        if [[ "$verbose" == "true" ]]; then
            echo "✓ Customization parameters valid"
        fi
    fi

    if validate_placeholders "$template_file" 2>&1 | tee /tmp/validate_output.txt | grep -q "WARNING"; then
        cat /tmp/validate_output.txt
        total_warnings=$((total_warnings + $(grep -c "WARNING" /tmp/validate_output.txt)))
    else
        if [[ "$verbose" == "true" ]]; then
            echo "✓ Variable placeholders valid"
        fi
    fi

    echo ""
    if [[ $total_errors -eq 0 && $total_warnings -eq 0 ]]; then
        echo "✓ Template validation passed"
        return 0
    elif [[ $total_errors -eq 0 ]]; then
        echo "⚠ Template validation passed with $total_warnings warning(s)"
        return 0
    else
        echo "✗ Template validation failed with $total_errors error(s) and $total_warnings warning(s)"
        return 1
    fi
}

#
# Validate all templates
#
validate_all_templates() {
    local verbose="${1:-false}"

    echo "=== Validating All Templates ==="
    echo ""

    local template_files=$(find "$TEMPLATES_DIR" -name "*-template.json" 2>/dev/null | sort)

    if [[ -z "$template_files" ]]; then
        echo "No templates found in $TEMPLATES_DIR"
        return 1
    fi

    local total_templates=0
    local passed=0
    local failed=0

    while IFS= read -r template_file; do
        if [[ -f "$template_file" ]]; then
            total_templates=$((total_templates + 1))

            if validate_template "$template_file" "$verbose"; then
                passed=$((passed + 1))
            else
                failed=$((failed + 1))
            fi

            echo ""
            echo "---"
            echo ""
        fi
    done <<< "$template_files"

    echo "=== Summary ==="
    echo "Total templates: $total_templates"
    echo "Passed: $passed"
    echo "Failed: $failed"

    if [[ $failed -gt 0 ]]; then
        return 1
    fi

    return 0
}

# Export functions
export -f validate_json_syntax
export -f validate_required_fields
export -f validate_template_id
export -f validate_agent_type
export -f validate_capabilities
export -f validate_scaffold
export -f validate_customization
export -f validate_placeholders
export -f validate_template
export -f validate_all_templates
