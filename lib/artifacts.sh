#!/usr/bin/env bash
# =============================================================================
# artifacts.sh — Artifact sequencing, run directory management
# =============================================================================

SEQ=0

# Initialize run directory
# Task modes:    tasks/HAP-625/runs/<timestamp>/
# No-task modes: pipeline_template/runs/<timestamp>/
init_run_dir() {
    local timestamp
    timestamp=$(date '+%Y-%m-%d_%H-%M-%S')

    if [[ -n "$TASK_DIR" ]]; then
        RUN_DIR="${TASK_DIR}/runs/${timestamp}"
    else
        RUN_DIR="${PIPELINE_DIR}/runs/${timestamp}"
    fi

    mkdir -p "$RUN_DIR"
    log_info "Run directory: ${RUN_DIR}"

    # Start pipeline log
    echo "Pipeline started at $(date)" > "${RUN_DIR}/pipeline.log"
    echo "Mode: ${PIPELINE_MODE}" >> "${RUN_DIR}/pipeline.log"
    echo "Config: MODEL=${MODEL}, REVIEW_MODEL=${REVIEW_MODEL}, STRATEGY=${FEEDBACK_STRATEGY}" >> "${RUN_DIR}/pipeline.log"
    echo "---" >> "${RUN_DIR}/pipeline.log"
}

# Bump sequence counter and return formatted number
bump_seq() {
    SEQ=$((SEQ + 1))
    printf "%02d" "$SEQ"
}

# Get next artifact path
# Usage: next_artifact "plan" "md" → runs/.../01_plan.md
next_artifact() {
    local name="$1"
    local ext="${2:-md}"
    local num
    num=$(bump_seq)
    echo "${RUN_DIR}/${num}_${name}.${ext}"
}

# Save content to artifact (without bumping seq — use when path already obtained)
save_artifact() {
    local path="$1"
    local content="$2"
    echo "$content" > "$path"
    log_debug "Saved artifact: $(basename "$path") ($(wc -c < "$path" | tr -d ' ') bytes)"
}

# Check if artifact exists and is non-empty
check_artifact() {
    local path="$1"
    if [[ -f "$path" && -s "$path" ]]; then
        return 0
    fi
    return 1
}

# Collect task context from task.md + subtask files
# Outputs combined markdown to stdout
collect_task_context() {
    local task_dir="$1"
    local context=""

    # Main task.md
    if [[ -f "${task_dir}/task.md" ]]; then
        context+="# Main Task\n\n"
        context+=$(cat "${task_dir}/task.md")
        context+="\n\n"
    else
        log_err "No task.md found in ${task_dir}"
        return 1
    fi

    # Subtasks (one level deep)
    local subtask_count=0
    for subtask_dir in "${task_dir}"/*/; do
        if [[ -f "${subtask_dir}/task.md" ]]; then
            local subtask_name
            subtask_name=$(basename "$subtask_dir")
            context+="\n---\n\n# Subtask: ${subtask_name}\n\n"
            context+=$(cat "${subtask_dir}/task.md")
            context+="\n\n"
            subtask_count=$((subtask_count + 1))
        fi
    done

    if (( subtask_count > 0 )); then
        log_info "Found ${subtask_count} subtask(s)"
    fi

    echo -e "$context"
}

# Load history from ALL runs of a task
# - Collects SUMMARY.md from every run into PREV_RUNS_HISTORY (chronological)
# - Loads full artifacts from the LATEST run for detailed context
# Sets: PREV_RUNS_HISTORY, PREV_CODE_OUTPUT, PREV_REVIEW_OUTPUT
load_previous_runs() {
    local task_dir="$1"
    local task_name
    task_name=$(basename "$task_dir")
    local runs_base="${task_dir}/runs"

    if [[ ! -d "$runs_base" ]]; then
        log_err "No previous runs found for: ${task_name}"
        return 1
    fi

    # Collect all run directories sorted chronologically
    local run_dirs
    run_dirs=$(ls -1d "${runs_base}"/*/ 2>/dev/null | sort)

    if [[ -z "$run_dirs" ]]; then
        log_err "No run directories in: ${runs_base}"
        return 1
    fi

    # --- Collect SUMMARY.md from ALL runs ---
    PREV_RUNS_HISTORY=""
    local run_count=0
    while IFS= read -r run_dir; do
        local run_timestamp
        run_timestamp=$(basename "$run_dir")
        local summary_file="${run_dir}/SUMMARY.md"

        if [[ -f "$summary_file" ]]; then
            run_count=$((run_count + 1))
            PREV_RUNS_HISTORY+="---\n\n"
            PREV_RUNS_HISTORY+="## Run ${run_count}: ${run_timestamp}\n\n"
            PREV_RUNS_HISTORY+=$(cat "$summary_file")
            PREV_RUNS_HISTORY+="\n\n"
        fi
    done <<< "$run_dirs"

    log_info "Found ${run_count} run(s) with summaries"

    # --- Load full artifacts from the LATEST run ---
    local latest_run
    latest_run=$(echo "$run_dirs" | tail -1)
    log_info "Loading latest run details: $(basename "$latest_run")"

    PREV_CODE_OUTPUT=""
    PREV_REVIEW_OUTPUT=""

    # Last coder output or fix (the most recent state of the code)
    for f in "${latest_run}"/*coder_output* "${latest_run}"/*fix*; do
        [[ -f "$f" ]] && PREV_CODE_OUTPUT=$(cat "$f")
    done
    for f in "${latest_run}"/*reviewer_output*; do
        [[ -f "$f" ]] && PREV_REVIEW_OUTPUT=$(cat "$f") && break
    done

    local loaded=0
    [[ -n "$PREV_RUNS_HISTORY" ]] && loaded=$((loaded + 1))
    [[ -n "$PREV_CODE_OUTPUT" ]] && loaded=$((loaded + 1))
    [[ -n "$PREV_REVIEW_OUTPUT" ]] && loaded=$((loaded + 1))
    log_ok "Loaded context: ${run_count} summaries + latest run details"
}

# Generate a lightweight run summary from existing artifacts (no agent call)
save_run_summary() {
    local status="$1"
    local duration="$2"
    local summary_file="${RUN_DIR}/SUMMARY.md"

    local mins=$((duration / 60))
    local secs=$((duration % 60))

    {
        echo "# Run Summary"
        echo ""
        echo "- **Status:** ${status}"
        echo "- **Mode:** ${PIPELINE_MODE}"
        echo "- **Duration:** ${mins}m ${secs}s"
        echo "- **Iterations:** ${CURRENT_ITERATION:-1}"
        echo "- **Strategy:** ${FEEDBACK_STRATEGY}"
        echo "- **Model:** ${MODEL} | Review: ${REVIEW_MODEL}"
        echo ""

        # Plan summary (first 10 meaningful lines)
        if [[ -n "${PLAN_OUTPUT:-}" ]]; then
            echo "## Plan"
            echo ""
            echo "$PLAN_OUTPUT" | grep -E '^(##|[0-9]+\.|-.+CREATE|-.+MODIFY|\|.+\|)' | head -15
            echo ""
        fi

        # Changes summary (files created/modified)
        if [[ -n "${CODE_OUTPUT:-}" ]]; then
            echo "## Changes"
            echo ""
            echo "$CODE_OUTPUT" | grep -iE '^\s*[-*] \`' | head -20
            echo ""
            # Build status
            local build_line
            build_line=$(echo "$CODE_OUTPUT" | grep -i 'build:' | head -1)
            if [[ -n "$build_line" ]]; then
                echo "- ${build_line}"
                echo ""
            fi
        fi

        # Test results
        if [[ -n "${TEST_OUTPUT:-}" ]]; then
            echo "## Tests"
            echo ""
            echo "- **Verdict:** ${TEST_VERDICT:-unknown}"
            echo "$TEST_OUTPUT" | grep -iE '(tests passed|tests failed|coverage|PASS|FAIL):?' | head -5
            echo ""
        fi

        # E2E results
        if [[ "${E2E_ENABLED:-false}" == "true" && -n "${E2E_OUTPUT:-}" ]]; then
            echo "## E2E"
            echo ""
            echo "- **Verdict:** ${E2E_VERDICT:-unknown}"
            echo ""
        fi

        # Review verdict
        if [[ -n "${REVIEW_OUTPUT:-}" ]]; then
            echo "## Review"
            echo ""
            echo "- **Verdict:** ${REVIEW_VERDICT:-unknown}"
            # Extract summary line if present
            echo "$REVIEW_OUTPUT" | grep -A2 '## Summary' | tail -2
            echo ""
        fi

        # Timing
        if [[ ${#STEP_DURATIONS[@]} -gt 0 ]]; then
            echo "## Timing"
            echo ""
            for step in "${!STEP_DURATIONS[@]}"; do
                local d="${STEP_DURATIONS[$step]}"
                echo "- ${step}: ${d}s"
            done
            echo ""
        fi

    } > "$summary_file"

    log_ok "Run summary saved: SUMMARY.md"
}

