#!/usr/bin/env bash
# =============================================================================
# metrics.sh — Per-step timing, JSON metrics output
# =============================================================================

declare -A STEP_TIMERS
declare -A STEP_DURATIONS

# Start a timer for a step
start_timer() {
    local step="$1"
    STEP_TIMERS["$step"]=$(date +%s)
    log_debug "Timer started: ${step}"
}

# Stop timer, record duration
stop_timer() {
    local step="$1"
    local start="${STEP_TIMERS[$step]:-0}"
    if (( start == 0 )); then
        log_warn "Timer not started for: ${step}"
        return
    fi
    local end
    end=$(date +%s)
    local duration=$((end - start))
    STEP_DURATIONS["$step"]=$duration
    log_debug "Timer stopped: ${step} (${duration}s)"
}

# Get duration for a step
get_duration() {
    local step="$1"
    echo "${STEP_DURATIONS[$step]:-0}"
}

# Save metrics as JSON
save_metrics() {
    local status="${1:-$PIPELINE_STATUS}"
    local total_duration="${2:-0}"
    local metrics_file="${RUN_DIR}/metrics.json"

    # Build steps JSON
    local steps_json="{"
    local first=true
    for step in "${!STEP_DURATIONS[@]}"; do
        if [[ "$first" == "true" ]]; then
            first=false
        else
            steps_json+=","
        fi
        steps_json+="\"${step}\": ${STEP_DURATIONS[$step]}"
    done
    steps_json+="}"

    # Build full metrics JSON
    cat > "$metrics_file" <<METRICS_EOF
{
  "timestamp": "$(date -u '+%Y-%m-%dT%H:%M:%SZ')",
  "pipeline_mode": "${PIPELINE_MODE}",
  "status": "${status}",
  "total_duration_seconds": ${total_duration},
  "iterations": ${CURRENT_ITERATION:-1},
  "feedback_strategy": "${FEEDBACK_STRATEGY}",
  "config": {
    "model": "${MODEL}",
    "review_model": "${REVIEW_MODEL}",
    "language": "${LANGUAGE}",
    "e2e_enabled": ${E2E_ENABLED},
    "max_iterations": ${MAX_ITERATIONS},
    "max_fix_iterations": ${MAX_FIX_ITERATIONS}
  },
  "steps": ${steps_json}
}
METRICS_EOF

    log_debug "Metrics saved to ${metrics_file}"
}

# Print timing summary
print_timing_summary() {
    echo ""
    log_info "Timing summary:"
    for step in "${!STEP_DURATIONS[@]}"; do
        local dur="${STEP_DURATIONS[$step]}"
        local mins=$((dur / 60))
        local secs=$((dur % 60))
        if (( mins > 0 )); then
            echo -e "  ${CLR_GRAY}${step}: ${mins}m ${secs}s${CLR_RESET}"
        else
            echo -e "  ${CLR_GRAY}${step}: ${secs}s${CLR_RESET}"
        fi
    done
}
