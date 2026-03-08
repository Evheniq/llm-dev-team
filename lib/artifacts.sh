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

# Get next artifact path (sets global NEXT_ARTIFACT)
# IMPORTANT: Do NOT call via $(...) — SEQ must increment in the current shell.
# Usage: next_artifact "plan" "md"  →  use $NEXT_ARTIFACT after call
NEXT_ARTIFACT=""
next_artifact() {
    local name="$1"
    local ext="${2:-md}"
    SEQ=$((SEQ + 1))
    NEXT_ARTIFACT="${RUN_DIR}/$(printf "%02d" "$SEQ")_${name}.${ext}"
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

# Find the latest artifact matching a name pattern in the current run dir
# Usage: latest_artifact "planner_output" → path to the most recent matching file
latest_artifact() {
    local name_pattern="$1"
    ls -1 "${RUN_DIR}"/*"${name_pattern}"*.md 2>/dev/null | tail -1
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

# =============================================================================
# Subtask detection, dependency parsing, ordering (for staircase mode)
# =============================================================================

# Detect subtask directories containing task.md
# Usage: detect_subtasks <task_dir>
# Outputs: newline-separated list of subtask dir names
detect_subtasks() {
    local task_dir="$1"
    local subtasks=()

    for d in "${task_dir}"/*/; do
        [[ -d "$d" && -f "${d}/task.md" ]] && subtasks+=("$(basename "$d")")
    done

    # Sort alphabetically for deterministic default order
    printf '%s\n' "${subtasks[@]}" | sort
}

# Parse dependencies from a subtask's task.md
# Looks for: "Залежність від BT-XXXX" and "- requires: BT-XXXX" under ## Dependencies
# Usage: parse_subtask_dependencies <task_dir>
# Outputs: lines of "subtask_name:dep1,dep2" (or "subtask_name:" if no deps)
parse_subtask_dependencies() {
    local task_dir="$1"

    for d in "${task_dir}"/*/; do
        [[ -d "$d" && -f "${d}/task.md" ]] || continue
        local subtask_name
        subtask_name=$(basename "$d")
        local task_file="${d}/task.md"
        local deps=()

        # Pattern 1: "Залежність від BT-XXXX" (Ukrainian dependency notation)
        # macOS grep doesn't support -P, use grep + sed instead
        while IFS= read -r match; do
            [[ -n "$match" ]] && deps+=("$match")
        done < <(grep -o 'Залежність від BT-[0-9]*' "$task_file" 2>/dev/null | sed 's/.*\(BT-[0-9]*\)/\1/' || true)

        # Pattern 2: "- requires: BT-XXXX" lines (under ## Dependencies or anywhere)
        while IFS= read -r match; do
            [[ -n "$match" ]] && deps+=("$match")
        done < <(grep -E '^\s*-\s*requires:' "$task_file" 2>/dev/null | grep -oE 'BT-[0-9]+' || true)

        # Deduplicate
        local unique_deps
        unique_deps=$(printf '%s\n' "${deps[@]}" 2>/dev/null | sort -u | tr '\n' ',' | sed 's/,$//')

        echo "${subtask_name}:${unique_deps}"
    done
}

# Topological sort of subtasks based on dependencies (Kahn's algorithm)
# Usage: resolve_subtask_order <task_dir>
# Outputs: ordered subtask dir names (one per line)
# Errors on cycles
resolve_subtask_order() {
    local task_dir="$1"

    # Get all subtask names
    local -a all_subtasks
    while IFS= read -r name; do
        [[ -n "$name" ]] && all_subtasks+=("$name")
    done < <(detect_subtasks "$task_dir")

    if (( ${#all_subtasks[@]} == 0 )); then
        return 0
    fi

    # Build subtask ID → name mapping (extract BT-XXXX from dir name)
    local -A id_to_name  # BT-1234 → full dir name
    local -A name_to_id  # full dir name → BT-1234
    for name in "${all_subtasks[@]}"; do
        local task_id
        task_id=$(echo "$name" | grep -oE 'BT-[0-9]+' | head -1 || echo "")
        if [[ -n "$task_id" ]]; then
            id_to_name["$task_id"]="$name"
            name_to_id["$name"]="$task_id"
        fi
    done

    # Parse dependencies
    local -A deps_map  # subtask_name → "dep1,dep2"
    local -A in_degree # subtask_name → count
    for name in "${all_subtasks[@]}"; do
        deps_map["$name"]=""
        in_degree["$name"]=0
    done

    while IFS= read -r line; do
        local name="${line%%:*}"
        local dep_str="${line#*:}"
        [[ -z "$dep_str" ]] && continue

        IFS=',' read -ra dep_ids <<< "$dep_str"
        local resolved_deps=()
        for dep_id in "${dep_ids[@]}"; do
            [[ -z "$dep_id" ]] && continue
            local dep_name="${id_to_name[$dep_id]:-}"
            if [[ -n "$dep_name" ]]; then
                resolved_deps+=("$dep_name")
                in_degree["$name"]=$(( ${in_degree["$name"]} + 1 ))
            fi
        done
        deps_map["$name"]=$(printf '%s,' "${resolved_deps[@]}" | sed 's/,$//')
    done < <(parse_subtask_dependencies "$task_dir")

    # Kahn's algorithm
    local -a queue=()
    local -a result=()

    # Seed queue with zero in-degree nodes (sorted for determinism)
    for name in "${all_subtasks[@]}"; do
        if (( ${in_degree["$name"]} == 0 )); then
            queue+=("$name")
        fi
    done

    while (( ${#queue[@]} > 0 )); do
        # Take first from queue
        local current="${queue[0]}"
        queue=("${queue[@]:1}")
        result+=("$current")

        # For each subtask that depends on current, reduce in-degree
        for name in "${all_subtasks[@]}"; do
            local dep_list="${deps_map[$name]}"
            [[ -z "$dep_list" ]] && continue

            IFS=',' read -ra dep_names <<< "$dep_list"
            for dep_name in "${dep_names[@]}"; do
                if [[ "$dep_name" == "$current" ]]; then
                    in_degree["$name"]=$(( ${in_degree["$name"]} - 1 ))
                    if (( ${in_degree["$name"]} == 0 )); then
                        queue+=("$name")
                    fi
                fi
            done
        done
    done

    # Check for cycles
    if (( ${#result[@]} != ${#all_subtasks[@]} )); then
        log_err "Dependency cycle detected among subtasks!"
        log_err "Resolved ${#result[@]} of ${#all_subtasks[@]} subtasks"
        return 1
    fi

    printf '%s\n' "${result[@]}"
}

# Collect context for a single subtask in staircase mode
# Includes parent task.md (as overview), parent docs/, and only this subtask's task.md
# Usage: collect_subtask_context <parent_dir> <subtask_dir>
# Outputs: combined markdown to stdout
collect_subtask_context() {
    local parent_dir="$1"
    local subtask_dir="$2"
    local context=""

    # Parent task.md as overview/reference
    if [[ -f "${parent_dir}/task.md" ]]; then
        context+="# Parent Task (overview/reference)\n\n"
        context+=$(cat "${parent_dir}/task.md")
        context+="\n\n"
    fi

    # Parent docs/ directory (all .md files)
    if [[ -d "${parent_dir}/docs" ]]; then
        for doc in "${parent_dir}/docs"/*.md; do
            [[ -f "$doc" ]] || continue
            local doc_name
            doc_name=$(basename "$doc")
            context+="\n---\n\n# Documentation: ${doc_name}\n\n"
            context+=$(cat "$doc")
            context+="\n\n"
        done
    fi

    # This subtask's task.md
    local subtask_path="${parent_dir}/${subtask_dir}"
    if [[ -f "${subtask_path}/task.md" ]]; then
        context+="\n---\n\n# Current Subtask: ${subtask_dir}\n\n"
        context+=$(cat "${subtask_path}/task.md")
        context+="\n\n"
    else
        log_err "No task.md found in subtask: ${subtask_path}"
        return 1
    fi

    echo -e "$context"
}

# =============================================================================
# Run history
# =============================================================================

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
    PREV_TEST_OUTPUT=""

    # Last coder output or fix (the most recent state of the code)
    for f in "${latest_run}"/*coder_output* "${latest_run}"/*fix*; do
        [[ -f "$f" ]] && PREV_CODE_OUTPUT=$(cat "$f")
    done
    for f in "${latest_run}"/*reviewer_output*; do
        [[ -f "$f" ]] && PREV_REVIEW_OUTPUT=$(cat "$f") && break
    done
    # Last test report (to show what failed)
    for f in "${latest_run}"/*test_report*; do
        [[ -f "$f" ]] && PREV_TEST_OUTPUT=$(cat "$f") && break
    done

    local loaded=0
    [[ -n "$PREV_RUNS_HISTORY" ]] && loaded=$((loaded + 1))
    [[ -n "$PREV_CODE_OUTPUT" ]] && loaded=$((loaded + 1))
    [[ -n "$PREV_REVIEW_OUTPUT" ]] && loaded=$((loaded + 1))
    [[ -n "$PREV_TEST_OUTPUT" ]] && loaded=$((loaded + 1))
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
        if [[ "${#STEP_DURATIONS[@]:-0}" -gt 0 ]] 2>/dev/null; then
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

