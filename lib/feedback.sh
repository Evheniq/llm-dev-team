#!/usr/bin/env bash
# =============================================================================
# feedback.sh — Verdict parsing, feedback construction, routing
# =============================================================================

# Extract verdict from agent output
# Strategy: first check the first non-empty line (agents should put verdict there),
# then fall back to scanning the entire file for verdict keywords.
# Returns: APPROVE, REQUEST_CHANGES, REJECT, BUILD_OK, BUILD_FAIL,
#          ALL_PASS, TESTS_FAIL, NEEDS_CLARIFICATION, or UNKNOWN
extract_verdict() {
    local file="$1"
    local content
    content=$(tr -d '[:space:]' < "$file" 2>/dev/null | tr '[:lower:]' '[:upper:]')

    # Try first non-empty line first (preferred — agents should put verdict at top)
    local first_line
    first_line=$(grep -m1 -v '^[[:space:]]*$' "$file" 2>/dev/null | tr -d '[:space:]' | tr '[:lower:]' '[:upper:]')

    # Check first line, then fall back to full content
    for text in "$first_line" "$content"; do
        case "$text" in
            *REQUEST_CHANGES*|*REQUESTCHANGES*) echo "REQUEST_CHANGES"; return ;;
            *REJECT*)         echo "REJECT"; return ;;
            *APPROVE*)        echo "APPROVE"; return ;;
            *BUILD_FAIL*|*BUILDFAIL*) echo "BUILD_FAIL"; return ;;
            *BUILD_OK*|*BUILDOK*) echo "BUILD_OK"; return ;;
            *ALL_PASS*|*ALLPASS*) echo "ALL_PASS"; return ;;
            *TESTS_FAIL*|*TESTSFAIL*) echo "TESTS_FAIL"; return ;;
            *NEEDS_CLARIFICATION*|*NEEDSCLARIFICATION*) echo "NEEDS_CLARIFICATION"; return ;;
            *IMPROVEMENTS_FOUND*|*IMPROVEMENTSFOUND*) echo "IMPROVEMENTS_FOUND"; return ;;
            *ONE_OFF*|*ONEOFF*) echo "ONE_OFF"; return ;;
            *SUCCESS*)        echo "SUCCESS"; return ;;
        esac
    done

    echo "UNKNOWN"
}

# Build feedback document from a failed step
# Usage: build_feedback <source_file> <step_name> <iteration>
build_feedback() {
    local source_file="$1"
    local step_name="$2"
    local iteration="$3"

    local feedback="# Feedback from iteration ${iteration}\n\n"
    feedback+="## Source: ${step_name}\n\n"
    feedback+="The previous iteration failed at the **${step_name}** step.\n\n"
    feedback+="Fix ALL issues mentioned below before proceeding:\n\n"
    feedback+="---\n\n"
    feedback+=$(cat "$source_file")

    echo -e "$feedback"
}

# Check if verdict is a pass/approve
is_passing_verdict() {
    local verdict="$1"
    case "$verdict" in
        APPROVE|ALL_PASS|SUCCESS|BUILD_OK) return 0 ;;
        *) return 1 ;;
    esac
}

# Check if coder's build failed
is_build_failure() {
    local verdict="$1"
    [[ "$verdict" == "BUILD_FAIL" ]]
}
