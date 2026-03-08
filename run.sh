#!/opt/homebrew/bin/bash
# =============================================================================
# Universal Task Pipeline — Main Orchestrator
# =============================================================================
set -euo pipefail

PIPELINE_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
CURRENT_ITERATION=0

# Source all libraries
source "${PIPELINE_DIR}/lib/logging.sh"
source "${PIPELINE_DIR}/lib/config.sh"
source "${PIPELINE_DIR}/lib/artifacts.sh"
source "${PIPELINE_DIR}/lib/metrics.sh"
source "${PIPELINE_DIR}/lib/agent.sh"
source "${PIPELINE_DIR}/lib/feedback.sh"
source "${PIPELINE_DIR}/lib/git_ops.sh"
source "${PIPELINE_DIR}/lib/server.sh"

# =============================================================================
# Hooks
# =============================================================================

run_hook() {
    local hook_name="$1"
    local hook_file="${PIPELINE_DIR}/hooks/${hook_name}.sh"
    if [[ -f "$hook_file" ]]; then
        log_debug "Running hook: ${hook_name}"
        # shellcheck source=/dev/null
        source "$hook_file"
    fi
}

# =============================================================================
# Finalization (runs on EXIT)
# =============================================================================

finalize() {
    local exit_code=$?

    # Stop server if running
    stop_server

    # Calculate total duration
    local end_time
    end_time=$(date +%s)
    local total_duration=$((end_time - PIPELINE_START_TIME))

    # Save metrics and run summary
    if [[ -n "${RUN_DIR:-}" ]]; then
        if [[ "$STAIRCASE_MODE" != "true" ]]; then
            # Single task: save metrics/summary to run dir
            save_metrics "$PIPELINE_STATUS" "$total_duration"
            save_run_summary "$PIPELINE_STATUS" "$total_duration"
            print_timing_summary
        else
            # Staircase mode: summary was already saved per-subtask + parent summary
            log_info "Staircase pipeline completed in ${total_duration}s"
        fi
    fi

    # Run post hook
    run_hook "post_pipeline"

    # Print final status
    print_status_banner "$PIPELINE_STATUS" "$total_duration"

    exit "${exit_code}"
}

# =============================================================================
# State Reset (for staircase mode — fresh state per subtask)
# =============================================================================

reset_pipeline_state() {
    SEQ=0
    CURRENT_ITERATION=0
    PIPELINE_STATUS="unknown"
    PLAN_OUTPUT=""
    CODE_OUTPUT=""
    TEST_OUTPUT=""
    REVIEW_OUTPUT=""
    E2E_OUTPUT=""
    VALIDATION_FEEDBACK=""
    TEST_VERDICT=""
    E2E_VERDICT=""
    REVIEW_VERDICT=""
    GIT_PREPARE_OUTPUT=""

    # Reset progress tracker arrays
    PROGRESS_STAGES=()
    PROGRESS_STATUS=()
    PROGRESS_DETAIL=()
    PROGRESS_TIME=()

    # Reset step timers
    STEP_TIMERS=()
    STEP_DURATIONS=()
}

# =============================================================================
# Pipeline Stages
# =============================================================================

# Stage: Collect task context
stage_collect_context() {
    progress_start "Collect context"
    local task_context
    task_context=$(collect_task_context "$TASK_DIR")

    local output_file
    output_file=$(next_artifact "task_context")
    save_artifact "$output_file" "$task_context"

    TASK_CONTEXT="$task_context"
    progress_done "Collect context" "ready"
}

# Stage: Plan
stage_plan() {
    progress_start "Planner"
    local feedback="${1:-}"
    local output_file
    output_file=$(next_artifact "planner_output")

    local context_sections=("task:${TASK_CONTEXT}")
    if [[ -n "$feedback" ]]; then
        context_sections+=("feedback:${feedback}")
    fi
    if [[ -n "$PROJECT_CONTEXT" && -f "$PROJECT_CONTEXT" ]]; then
        context_sections+=("project_context:$(cat "$PROJECT_CONTEXT")")
    fi

    local prompt
    prompt=$(build_prompt "planner" "${context_sections[@]}")

    if ! run_agent "plan" "planner" "$MODEL" "$output_file" "$prompt"; then
        progress_fail "Planner"
        return 1
    fi
    PLAN_OUTPUT=$(cat "$output_file")

    # Extract file count from plan for progress display
    local file_count
    file_count=$(echo "$PLAN_OUTPUT" | grep -ciE 'CREATE|MODIFY' || echo "?")
    progress_done "Planner" "${file_count} files planned"
}

# Stage: Code (coder self-verifies build — tester reuses it)
stage_code() {
    progress_start "Coder + Build"
    local plan="${1:-$PLAN_OUTPUT}"
    local output_file
    output_file=$(next_artifact "coder_output")

    local prompt
    prompt=$(build_prompt "coder" \
        "task:${TASK_CONTEXT}" \
        "plan:${plan}")

    run_hook "pre_code"
    if ! run_agent "code" "coder" "$MODEL" "$output_file" "$prompt"; then
        progress_fail "Coder + Build"
        return 1
    fi
    CODE_OUTPUT=$(cat "$output_file")

    # Check if coder managed to build successfully
    local code_verdict
    code_verdict=$(extract_verdict "$output_file")
    if is_build_failure "$code_verdict"; then
        log_err "Coder could not produce a building code after 3 attempts"
        progress_fail "Coder + Build" "BUILD_FAIL"
        return 1
    fi

    # Extract change count for display
    local change_count
    change_count=$(echo "$CODE_OUTPUT" | grep -cE '^\s*[-*] \`' || echo "?")
    progress_done "Coder + Build" "BUILD_OK, ${change_count} changes"
}

# =============================================================================
# Parallel Validation: test + e2e + review run simultaneously
# =============================================================================

# Prepare output file paths for parallel stages (reserve sequence numbers upfront)
_prepare_parallel_files() {
    TEST_FILE=$(next_artifact "test_report")
    if [[ "$E2E_ENABLED" == "true" ]]; then
        E2E_FILE=$(next_artifact "tester_e2e")
    else
        E2E_FILE=""
    fi
    REVIEW_FILE=$(next_artifact "reviewer_output")
}

# Run test agent (designed to run in background)
_run_test_bg() {
    local output_file="$1"

    local prompt
    prompt=$(build_prompt "tester" \
        "task:${TASK_CONTEXT}" \
        "changes:${CODE_OUTPUT}")

    run_agent "test" "tester" "$MODEL" "$output_file" "$prompt"
}

# Run E2E agent (designed to run in background)
_run_e2e_bg() {
    local output_file="$1"

    start_server || return 1

    local prompt
    prompt=$(build_prompt "tester_e2e" \
        "task:${TASK_CONTEXT}" \
        "changes:${CODE_OUTPUT}")

    run_agent "e2e-test" "tester_e2e" "$MODEL" "$output_file" "$prompt"
    local rc=$?
    stop_server
    return $rc
}

# Run review agent (designed to run in background)
_run_review_bg() {
    local output_file="$1"

    local sections=("task:${TASK_CONTEXT}")
    [[ -n "${PLAN_OUTPUT:-}" ]] && sections+=("plan:${PLAN_OUTPUT}")
    [[ -n "${CODE_OUTPUT:-}" ]] && sections+=("changes:${CODE_OUTPUT}")

    local prompt
    prompt=$(build_prompt "reviewer" "${sections[@]}")

    run_agent "review" "reviewer" "$REVIEW_MODEL" "$output_file" "$prompt"
}

# Run all validation stages in parallel, collect combined feedback
# Sets: TEST_VERDICT, E2E_VERDICT, REVIEW_VERDICT, VALIDATION_FEEDBACK
# Returns: 0 if all passed/approved, 1 if any issues found
stage_validate_parallel() {
    step_header "${1:-.}" "Validation (test + review in parallel)"

    _prepare_parallel_files

    # Register parallel stages in progress
    progress_start "Unit tests"
    if [[ -n "$E2E_FILE" ]]; then
        progress_start "E2E tests"
    fi
    progress_start "Code review"

    local pids=()

    # Launch test in background
    log_info "${ICON_AGENT} Starting unit tests..."
    _run_test_bg "$TEST_FILE" &
    pids+=($!)

    # Launch E2E in background (if enabled)
    if [[ -n "$E2E_FILE" ]]; then
        log_info "${ICON_AGENT} Starting E2E tests..."
        _run_e2e_bg "$E2E_FILE" &
        pids+=($!)
    fi

    # Launch review in background
    log_info "${ICON_AGENT} Starting code review..."
    _run_review_bg "$REVIEW_FILE" &
    pids+=($!)

    # Wait for all to finish
    log_info "Waiting for all validators to complete..."
    local all_ok=true
    for pid in "${pids[@]}"; do
        if ! wait "$pid"; then
            all_ok=false
        fi
    done

    # --- Collect results ---
    VALIDATION_FEEDBACK=""

    # Test results
    TEST_VERDICT="UNKNOWN"
    if [[ -f "$TEST_FILE" && -s "$TEST_FILE" ]]; then
        TEST_OUTPUT=$(cat "$TEST_FILE")
        TEST_VERDICT=$(extract_verdict "$TEST_FILE")
        if ! is_passing_verdict "$TEST_VERDICT"; then
            log_warn "Tests: ${TEST_VERDICT}"
            progress_fail "Unit tests" "$TEST_VERDICT"
            VALIDATION_FEEDBACK+="## Unit Test Failures\n\n${TEST_OUTPUT}\n\n---\n\n"
        else
            log_ok "Tests: ${TEST_VERDICT}"
            progress_done "Unit tests" "$TEST_VERDICT"
        fi
    else
        log_err "Test agent produced no output"
        progress_fail "Unit tests" "no output"
        VALIDATION_FEEDBACK+="## Unit Tests\n\nAgent failed to produce output.\n\n---\n\n"
        all_ok=false
    fi

    # E2E results
    E2E_VERDICT="ALL_PASS"
    if [[ -n "$E2E_FILE" ]]; then
        if [[ -f "$E2E_FILE" && -s "$E2E_FILE" ]]; then
            E2E_OUTPUT=$(cat "$E2E_FILE")
            E2E_VERDICT=$(extract_verdict "$E2E_FILE")
            if ! is_passing_verdict "$E2E_VERDICT"; then
                log_warn "E2E: ${E2E_VERDICT}"
                progress_fail "E2E tests" "$E2E_VERDICT"
                VALIDATION_FEEDBACK+="## E2E Test Failures\n\n${E2E_OUTPUT}\n\n---\n\n"
            else
                log_ok "E2E: ${E2E_VERDICT}"
                progress_done "E2E tests" "PASSED"
            fi
        else
            log_err "E2E agent produced no output"
            progress_fail "E2E tests" "no output"
            VALIDATION_FEEDBACK+="## E2E Tests\n\nAgent failed to produce output.\n\n---\n\n"
            all_ok=false
        fi
    fi

    # Review results
    REVIEW_VERDICT="UNKNOWN"
    if [[ -f "$REVIEW_FILE" && -s "$REVIEW_FILE" ]]; then
        REVIEW_OUTPUT=$(cat "$REVIEW_FILE")
        REVIEW_VERDICT=$(extract_verdict "$REVIEW_FILE")
        case "$REVIEW_VERDICT" in
            APPROVE*)
                log_ok "Review: ${REVIEW_VERDICT}"
                progress_done "Code review" "$REVIEW_VERDICT"
                ;;
            REJECT*)
                log_err "Review: ${REVIEW_VERDICT}"
                progress_fail "Code review" "REJECTED"
                VALIDATION_FEEDBACK+="## Code Review (REJECTED)\n\n${REVIEW_OUTPUT}\n\n"
                ;;
            *)
                log_warn "Review: ${REVIEW_VERDICT}"
                progress_warn "Code review" "$REVIEW_VERDICT"
                VALIDATION_FEEDBACK+="## Code Review Issues\n\n${REVIEW_OUTPUT}\n\n"
                ;;
        esac
    else
        log_err "Review agent produced no output"
        progress_fail "Code review" "no output"
        VALIDATION_FEEDBACK+="## Code Review\n\nAgent failed to produce output.\n\n---\n\n"
        all_ok=false
    fi

    # --- Summary ---
    if [[ -z "$VALIDATION_FEEDBACK" ]]; then
        log_ok "All validators passed"
        return 0
    else
        local issue_count=0
        is_passing_verdict "$TEST_VERDICT" || issue_count=$((issue_count + 1))
        is_passing_verdict "$E2E_VERDICT" || issue_count=$((issue_count + 1))
        is_passing_verdict "$REVIEW_VERDICT" || issue_count=$((issue_count + 1))
        log_warn "Validation found issues from ${issue_count} source(s)"
        return 1
    fi
}

# Stage: Generate QA test cases
stage_qa() {
    if [[ "$QA_ENABLED" != "true" ]]; then
        progress_skip "QA cases"
        return 0
    fi

    progress_start "QA cases"
    local output_file
    output_file=$(next_artifact "tester_qa_cases")

    local prompt
    prompt=$(build_prompt "tester_qa" \
        "task:${TASK_CONTEXT}" \
        "changes:${CODE_OUTPUT}")

    if run_agent "qa-cases" "tester_qa" "$REPORT_MODEL" "$output_file" "$prompt"; then
        progress_done "QA cases" "generated"
    else
        progress_fail "QA cases"
    fi
}

# Stage: Generate report
stage_report() {
    if [[ "$REPORT_ENABLED" != "true" ]]; then
        progress_skip "Report"
        return 0
    fi

    progress_start "Report"
    local output_file
    output_file=$(next_artifact "report")

    local sections=("task:${TASK_CONTEXT}")
    [[ -n "${CODE_OUTPUT:-}" ]] && sections+=("changes:${CODE_OUTPUT}")
    [[ -n "${TEST_OUTPUT:-}" ]] && sections+=("test_results:${TEST_OUTPUT}")
    [[ -n "${REVIEW_OUTPUT:-}" ]] && sections+=("review:${REVIEW_OUTPUT}")

    local prompt
    prompt=$(build_prompt "report" "${sections[@]}")

    if run_agent "report" "report" "$REPORT_MODEL" "$output_file" "$prompt"; then
        progress_done "Report" "generated"
    else
        progress_fail "Report"
    fi
}

# Stage: Fix (apply combined feedback from all validators — coder self-verifies build)
stage_fix() {
    progress_start "Fix"
    local combined_feedback="$1"
    local output_file
    output_file=$(next_artifact "fix")

    local prompt
    prompt=$(build_prompt "coder" \
        "task:${TASK_CONTEXT}" \
        "plan:${PLAN_OUTPUT}" \
        "validation_feedback:${combined_feedback}")
    prompt+="\n\nFix ALL issues listed above. These come from unit tests, E2E tests, and code review — address everything.\n"
    prompt+="You MUST verify the build passes after your fixes.\n"

    if ! run_agent "fix" "coder" "$MODEL" "$output_file" "$prompt"; then
        progress_fail "Fix"
        return 1
    fi
    CODE_OUTPUT=$(cat "$output_file")

    # Verify coder's build
    local fix_verdict
    fix_verdict=$(extract_verdict "$output_file")
    if is_build_failure "$fix_verdict"; then
        log_err "Coder could not build after fixes"
        progress_fail "Fix" "BUILD_FAIL"
        return 1
    fi
    progress_done "Fix" "BUILD_OK"
}

# =============================================================================
# Pipeline Modes
# =============================================================================

# Stage: Collect subtask context (for staircase mode)
stage_collect_subtask_context() {
    local parent_dir="$1"
    local subtask_dir="$2"

    progress_start "Collect subtask context"
    local task_context
    task_context=$(collect_subtask_context "$parent_dir" "$subtask_dir")

    local output_file
    output_file=$(next_artifact "task_context")
    save_artifact "$output_file" "$task_context"

    TASK_CONTEXT="$task_context"
    progress_done "Collect subtask context" "${subtask_dir}"
}

# =============================================================================
# Staircase Pipeline (parent tasks with subtasks)
# =============================================================================

run_staircase_pipeline() {
    local parent_dir="$TASK_DIR"
    STAIRCASE_MODE=true

    header "Staircase Pipeline: $(basename "$parent_dir")"

    # 1. Detect subtasks
    local -a subtask_list=()
    while IFS= read -r name; do
        [[ -n "$name" ]] && subtask_list+=("$name")
    done < <(detect_subtasks "$parent_dir")

    log_info "Found ${#subtask_list[@]} subtask(s)"

    # 2. Resolve execution order (topological sort)
    local -a ordered_subtasks=()
    while IFS= read -r name; do
        [[ -n "$name" ]] && ordered_subtasks+=("$name")
    done < <(resolve_subtask_order "$parent_dir")

    if (( ${#ordered_subtasks[@]} == 0 )); then
        log_err "No subtasks resolved — aborting"
        PIPELINE_STATUS="staircase_failed"
        return 1
    fi

    # 3. Log execution plan
    log_info "Execution order:"
    local idx=0
    for subtask in "${ordered_subtasks[@]}"; do
        idx=$((idx + 1))
        log_info "  ${idx}. ${subtask}"
    done

    # Determine starting base branch
    local previous_branch="${BASE_BRANCH}"
    if [[ -z "$previous_branch" ]]; then
        # Auto-detect: prefer origin/dev, fallback to origin/main
        if git rev-parse --verify origin/dev &>/dev/null; then
            previous_branch="origin/dev"
        elif git rev-parse --verify origin/main &>/dev/null; then
            previous_branch="origin/main"
        else
            previous_branch="origin/master"
        fi
        log_info "Auto-detected base branch: ${previous_branch}"
    fi

    # 4. Track results for summary
    local -a staircase_results=()
    local staircase_ok=true

    # 5. Execute each subtask sequentially
    for subtask in "${ordered_subtasks[@]}"; do
        echo ""
        header "Subtask: ${subtask}"

        # a. Reset pipeline state for fresh run
        reset_pipeline_state

        # b. Set TASK_DIR to subtask dir (for artifact paths etc.)
        TASK_DIR="${parent_dir}/${subtask}"

        # c. Fresh run directory per subtask
        init_run_dir

        # d. Collect subtask-specific context
        step_header "1" "Collect subtask context"
        stage_collect_subtask_context "$parent_dir" "$subtask"

        # e. Git prepare (staircase branching)
        if [[ "$AUTO_GIT" == "true" ]]; then
            step_header "2" "Git prepare (from ${previous_branch})"
            if ! run_git_prepare_staircase "$TASK_CONTEXT" "$previous_branch"; then
                log_err "Git prepare failed for ${subtask}"
                staircase_results+=("${subtask}:FAIL:git_prepare_failed")
                if [[ "$STAIRCASE_ON_FAILURE" == "stop" ]]; then
                    staircase_ok=false
                    break
                else
                    log_warn "Skipping ${subtask} (--on-failure=skip)"
                    continue
                fi
            fi
        fi

        # f. Run pipeline loop (replan or direct)
        local feedback=""
        if [[ "$FEEDBACK_STRATEGY" == "replan" ]]; then
            run_replan_loop "$feedback"
        else
            run_direct_loop "$feedback"
        fi
        local subtask_status="$PIPELINE_STATUS"

        # g. Handle result
        if [[ "$subtask_status" == "approved" ]]; then
            log_ok "Subtask ${subtask}: APPROVED"

            # Force commit in staircase mode (implicit AUTO_COMMIT)
            if [[ "$AUTO_GIT" == "true" ]]; then
                step_header "+" "Git Commit (staircase)"
                run_git_commit "$TASK_CONTEXT" "$CODE_OUTPUT"
                # Update previous_branch for next subtask
                if [[ -n "$LAST_BRANCH_NAME" ]]; then
                    previous_branch="$LAST_BRANCH_NAME"
                    log_info "Next subtask will branch from: ${previous_branch}"
                fi
            fi

            staircase_results+=("${subtask}:APPROVED:${subtask_status}")
        else
            log_err "Subtask ${subtask}: FAILED (${subtask_status})"
            staircase_results+=("${subtask}:FAIL:${subtask_status}")

            if [[ "$STAIRCASE_ON_FAILURE" == "stop" ]]; then
                staircase_ok=false
                break
            else
                log_warn "Continuing to next subtask (--on-failure=skip)"
            fi
        fi
    done

    # 6. Restore parent TASK_DIR
    TASK_DIR="$parent_dir"

    # 7. Save staircase summary
    local summary_file="${parent_dir}/STAIRCASE_SUMMARY.md"
    {
        echo "# Staircase Pipeline Summary"
        echo ""
        echo "**Parent task:** $(basename "$parent_dir")"
        echo "**Date:** $(date '+%Y-%m-%d %H:%M:%S')"
        echo "**Base branch:** ${BASE_BRANCH:-auto-detected}"
        echo ""
        echo "| # | Subtask | Status | Details |"
        echo "|---|---------|--------|---------|"
        local i=0
        for result in "${staircase_results[@]}"; do
            i=$((i + 1))
            local name="${result%%:*}"
            local rest="${result#*:}"
            local status="${rest%%:*}"
            local detail="${rest#*:}"
            echo "| ${i} | ${name} | ${status} | ${detail} |"
        done
        echo ""
        if [[ "$staircase_ok" == "true" ]]; then
            echo "**Overall: ALL SUBTASKS APPROVED**"
        else
            echo "**Overall: PIPELINE STOPPED (failure encountered)**"
        fi
    } > "$summary_file"
    log_info "Staircase summary saved: ${summary_file}"

    if [[ "$staircase_ok" == "true" ]]; then
        PIPELINE_STATUS="approved"
        return 0
    else
        PIPELINE_STATUS="staircase_failed"
        return 1
    fi
}

# Full task pipeline: collect → [git] → plan → code → test → [e2e] → review → [qa] → [report]
run_task_pipeline() {
    # Detect parent task with subtasks → staircase mode
    local subtask_count=0
    for d in "${TASK_DIR}"/*/; do
        [[ -f "${d}/task.md" ]] && subtask_count=$((subtask_count + 1))
    done

    if (( subtask_count > 0 )); then
        log_info "Parent task with ${subtask_count} subtask(s) → staircase mode"
        run_staircase_pipeline
        return $?
    fi

    header "Task Pipeline: $(basename "$TASK_DIR")"

    # 1. Collect task context
    step_header "1" "Collect task context"
    stage_collect_context

    # 2. Git prepare (optional)
    if [[ "$AUTO_GIT" == "true" ]]; then
        step_header "2" "Git prepare"
        run_git_prepare "$TASK_CONTEXT"
    fi

    # 3. Main iteration loop
    local feedback=""
    if [[ -n "$FEEDBACK_FILE" && -f "$FEEDBACK_FILE" ]]; then
        feedback=$(cat "$FEEDBACK_FILE")
        log_info "Resuming from feedback file"
    fi

    if [[ "$FEEDBACK_STRATEGY" == "replan" ]]; then
        run_replan_loop "$feedback"
    else
        run_direct_loop "$feedback"
    fi
}

# Replan strategy: failure → combined feedback → planner → full cycle
run_replan_loop() {
    local feedback="${1:-}"

    for (( CURRENT_ITERATION=1; CURRENT_ITERATION<=MAX_ITERATIONS; CURRENT_ITERATION++ )); do
        header "Iteration ${CURRENT_ITERATION}/${MAX_ITERATIONS}"

        # Plan
        step_header "${CURRENT_ITERATION}.1" "Planning"
        stage_plan "$feedback" || { PIPELINE_STATUS="plan_failed"; return 1; }

        # Check if planner needs clarification
        local plan_verdict
        plan_verdict=$(extract_verdict "$(latest_artifact "planner_output")")
        if [[ "$plan_verdict" == "NEEDS_CLARIFICATION" ]]; then
            log_warn "Planner needs clarification — see planner output"
            PIPELINE_STATUS="needs_clarification"
            return 1
        fi

        # Code (coder self-verifies build)
        step_header "${CURRENT_ITERATION}.2" "Coding + Build"
        stage_code || { PIPELINE_STATUS="code_failed"; return 1; }

        # Validate: test + e2e + review — all in parallel
        if stage_validate_parallel "${CURRENT_ITERATION}.3"; then
            # All passed — check if reviewer approved
            if [[ "$REVIEW_VERDICT" == APPROVE* ]]; then
                log_ok "Code approved!"
                PIPELINE_STATUS="approved"
                run_post_approval
                return 0
            fi
        fi

        # REJECT is fatal
        if [[ "$REVIEW_VERDICT" == REJECT* ]]; then
            log_err "Code rejected by reviewer"
            PIPELINE_STATUS="rejected"
            return 1
        fi

        # Build combined feedback from ALL failed validators
        # Include previous CODE_OUTPUT so planner knows what was already tried
        local fb_file
        fb_file=$(next_artifact "feedback")
        feedback="# Combined feedback from iteration ${CURRENT_ITERATION}\n\n"
        feedback+="Fix ALL issues below in the next iteration.\n\n"
        feedback+="## What was tried in iteration ${CURRENT_ITERATION}\n\n"
        feedback+="The coder produced the following changes (summary):\n\n"
        feedback+="${CODE_OUTPUT}\n\n"
        feedback+="## Validation results\n\n"
        feedback+="${VALIDATION_FEEDBACK}"
        save_artifact "$fb_file" "$(echo -e "$feedback")"
        log_warn "Combined feedback (with previous code context) sent to planner for next iteration"
    done

    log_err "Max iterations (${MAX_ITERATIONS}) reached"
    PIPELINE_STATUS="max_iterations"
    return 1
}

# Direct strategy: plan once → code → validate parallel → fix cycle
run_direct_loop() {
    local feedback="${1:-}"
    CURRENT_ITERATION=1

    # Plan (once)
    step_header "1" "Planning"
    stage_plan "$feedback" || { PIPELINE_STATUS="plan_failed"; return 1; }

    # Check if planner needs clarification
    local plan_verdict
    plan_verdict=$(extract_verdict "$(latest_artifact "planner_output")")
    if [[ "$plan_verdict" == "NEEDS_CLARIFICATION" ]]; then
        log_warn "Planner needs clarification — see planner output"
        PIPELINE_STATUS="needs_clarification"
        return 1
    fi

    # Code (coder self-verifies build)
    step_header "2" "Coding + Build"
    stage_code || { PIPELINE_STATUS="code_failed"; return 1; }

    # Validate: test + e2e + review — all in parallel
    stage_validate_parallel "3"

    # REJECT is fatal
    if [[ "$REVIEW_VERDICT" == REJECT* ]]; then
        PIPELINE_STATUS="rejected"
        return 1
    fi

    # Fix cycle — coder gets combined feedback from all validators
    local fix_iter=0
    while [[ -n "$VALIDATION_FEEDBACK" ]] && (( fix_iter < MAX_FIX_ITERATIONS )); do
        fix_iter=$((fix_iter + 1))
        CURRENT_ITERATION=$((CURRENT_ITERATION + 1))

        step_header "4.${fix_iter}" "Fix cycle ${fix_iter}/${MAX_FIX_ITERATIONS}"

        # Fix — pass ALL feedback (tests + e2e + review) at once
        stage_fix "$(echo -e "$VALIDATION_FEEDBACK")" || { PIPELINE_STATUS="fix_failed"; return 1; }

        # Re-validate in parallel
        stage_validate_parallel "4.${fix_iter}"

        if [[ "$REVIEW_VERDICT" == REJECT* ]]; then
            PIPELINE_STATUS="rejected"
            return 1
        fi
    done

    if [[ "$REVIEW_VERDICT" == APPROVE* ]] && is_passing_verdict "$TEST_VERDICT"; then
        log_ok "Code approved!"
        PIPELINE_STATUS="approved"
        run_post_approval
        return 0
    fi

    if (( fix_iter >= MAX_FIX_ITERATIONS )) && [[ -n "$VALIDATION_FEEDBACK" ]]; then
        log_err "Max fix iterations reached"
        PIPELINE_STATUS="max_iterations"
        return 1
    fi
}

# =============================================================================
# Retrospective (Self-Improvement)
# =============================================================================

# Stage: Run retrospective analysis on multi-iteration runs
stage_retrospective() {
    # Only run when multiple iterations were needed and feature is enabled
    if [[ "$RETRO_ENABLED" != "true" ]]; then
        progress_skip "Retrospective" "disabled"
        return 0
    fi
    if (( CURRENT_ITERATION <= 3 )); then
        progress_skip "Retrospective" "${CURRENT_ITERATION} iteration(s) — not enough to analyze"
        return 0
    fi

    progress_start "Retrospective"
    local output_file
    output_file=$(next_artifact "retrospective")

    # Collect all .md artifacts from the run directory into one context block
    local all_artifacts=""
    local artifact_count=0
    for f in "${RUN_DIR}"/*.md; do
        [[ -f "$f" ]] || continue
        local basename
        basename=$(basename "$f")
        # Skip STATUS.md and the retrospective output itself
        [[ "$basename" == "STATUS.md" ]] && continue
        [[ "$basename" == *"retrospective"* ]] && continue
        all_artifacts+="\n---\n\n## Artifact: ${basename}\n\n"
        all_artifacts+=$(cat "$f")
        all_artifacts+="\n\n"
        artifact_count=$((artifact_count + 1))
    done

    # Load existing lessons learned for context
    local lessons_file="${PIPELINE_DIR}/data/lessons_learned.md"
    local existing_lessons=""
    if [[ -f "$lessons_file" && -s "$lessons_file" ]]; then
        existing_lessons=$(cat "$lessons_file")
    fi

    local prompt
    prompt=$(build_prompt "retrospective" \
        "run_summary:This pipeline run required ${CURRENT_ITERATION} iterations before approval." \
        "task:${TASK_CONTEXT}" \
        "artifacts:${all_artifacts}" \
        "existing_lessons:${existing_lessons}")

    if ! run_agent "retrospective" "retrospective" "$REVIEW_MODEL" "$output_file" "$prompt"; then
        progress_fail "Retrospective"
        log_warn "Retrospective failed — this is non-fatal, continuing"
        return 0
    fi

    local retro_verdict
    retro_verdict=$(extract_verdict "$output_file")

    if [[ "$retro_verdict" == "IMPROVEMENTS_FOUND" ]]; then
        progress_done "Retrospective" "improvements found"
        log_info "Retrospective found systemic improvements"
        _present_retrospective_changes "$output_file"
    else
        progress_done "Retrospective" "one-off issues only"
        log_ok "Retrospective: all issues were one-off, no changes needed"
    fi

    # Always append lessons learned
    _append_lessons_learned "$output_file"
}

# Present proposed changes interactively and save approved ones
_present_retrospective_changes() {
    local retro_file="$1"
    local retro_content
    retro_content=$(cat "$retro_file")

    # Extract Change sections using awk
    local changes
    changes=$(echo "$retro_content" | awk '/^### Change [0-9]+:/{found=1; buf=$0; next} found && /^### Change [0-9]+:/{print buf; buf=$0; next} found && /^## /{print buf; found=0; next} found{buf=buf"\n"$0} END{if(found) print buf}')

    if [[ -z "$changes" ]]; then
        log_info "No structured changes found in retrospective output"
        return 0
    fi

    echo ""
    echo -e "${CLR_BOLD}${CLR_CYAN}── Retrospective: Proposed Changes ──${CLR_RESET}"
    echo ""

    local pending_file="${RUN_DIR}/pending_changes.md"
    echo "# Pending Retrospective Changes" > "$pending_file"
    echo "" >> "$pending_file"
    echo "Generated: $(date '+%Y-%m-%d %H:%M:%S')" >> "$pending_file"
    echo "Task: $(basename "${TASK_DIR:-unknown}")" >> "$pending_file"
    echo "" >> "$pending_file"

    local change_num=0
    local approved_count=0
    local skip_all=false

    # Process each change block
    while IFS= read -r change_block; do
        [[ -z "$change_block" ]] && continue
        change_num=$((change_num + 1))

        if [[ "$skip_all" == "true" ]]; then
            continue
        fi

        echo ""
        echo -e "${CLR_BOLD}Change ${change_num}:${CLR_RESET}"
        echo -e "$change_block"
        echo ""

        _prompt_change_approval
        local response=$?

        case $response in
            0)  # approved
                echo -e "---\n" >> "$pending_file"
                echo -e "$change_block" >> "$pending_file"
                echo "" >> "$pending_file"
                approved_count=$((approved_count + 1))
                log_ok "Change ${change_num}: approved"
                ;;
            1)  # declined
                log_info "Change ${change_num}: declined"
                ;;
            2)  # skip all
                skip_all=true
                log_info "Skipping remaining changes"
                ;;
        esac
    done <<< "$changes"

    if (( approved_count > 0 )); then
        log_ok "Saved ${approved_count} approved change(s) to: ${pending_file}"
        echo ""
        echo -e "${CLR_YELLOW}${ICON_WARN} Changes are saved but NOT auto-applied.${CLR_RESET}"
        echo -e "${CLR_YELLOW}  Review and apply manually from: ${pending_file}${CLR_RESET}"
    else
        # Clean up empty pending file
        rm -f "$pending_file"
        log_info "No changes approved"
    fi
}

# Prompt user for change approval
# Returns: 0=approve, 1=decline, 2=skip all
_prompt_change_approval() {
    while true; do
        echo -ne "${CLR_BOLD}Apply this change? [y]es / [n]o / [s]kip all: ${CLR_RESET}"
        read -r answer < /dev/tty
        case "${answer,,}" in
            y|yes) return 0 ;;
            n|no)  return 1 ;;
            s|skip) return 2 ;;
            *) echo "Please answer y, n, or s" ;;
        esac
    done
}

# Extract and append lessons learned to persistent file
_append_lessons_learned() {
    local retro_file="$1"
    local lessons_file="${PIPELINE_DIR}/data/lessons_learned.md"

    # Extract the "## Lessons Learned" section
    local lessons_section
    lessons_section=$(awk '/^## Lessons Learned/{found=1; next} found && /^## /{found=0} found{print}' "$retro_file")

    if [[ -z "$lessons_section" ]]; then
        log_debug "No lessons learned section found in retrospective output"
        return 0
    fi

    # Append with metadata
    {
        echo "## $(date '+%Y-%m-%d %H:%M') — $(basename "${TASK_DIR:-unknown}")"
        echo ""
        echo "$lessons_section"
        echo ""
        echo "---"
        echo ""
    } >> "$lessons_file"

    log_ok "Lessons learned appended to data/lessons_learned.md"
}

# Post-approval stages
run_post_approval() {
    run_hook "post_approve"

    # QA test cases
    if [[ "$QA_ENABLED" == "true" ]]; then
        step_header "+" "QA Test Cases"
        stage_qa
    fi

    # Report
    if [[ "$REPORT_ENABLED" == "true" ]]; then
        step_header "+" "Report"
        stage_report
    fi

    # Retrospective (self-improvement)
    step_header "+" "Retrospective"
    stage_retrospective

    # Git commit (optional)
    if [[ "$AUTO_GIT" == "true" && "$AUTO_COMMIT" == "true" ]]; then
        step_header "+" "Git Commit"
        run_git_commit "$TASK_CONTEXT" "$CODE_OUTPUT"
    fi
}

# Feature pipeline (no task folder, description-based)
run_feature_pipeline() {
    header "Feature Pipeline"

    TASK_CONTEXT="$TASK_DESCRIPTION"
    local ctx_file
    ctx_file=$(next_artifact "task_context")
    save_artifact "$ctx_file" "$TASK_CONTEXT"

    if [[ "$FEEDBACK_STRATEGY" == "replan" ]]; then
        run_replan_loop ""
    else
        run_direct_loop ""
    fi
}

# Review-only pipeline
run_review_pipeline() {
    header "Review Pipeline: ${TASK_DESCRIPTION}"

    TASK_CONTEXT="Review the following code scope: ${TASK_DESCRIPTION}"
    CODE_OUTPUT="(see scope description in task)"
    TEST_OUTPUT=""
    PLAN_OUTPUT=""

    stage_review || { PIPELINE_STATUS="review_failed"; return 1; }

    case "$REVIEW_VERDICT" in
        APPROVE*)
            PIPELINE_STATUS="approved"
            log_ok "Code approved"
            ;;
        *)
            PIPELINE_STATUS="changes_requested"
            log_warn "Review verdict: ${REVIEW_VERDICT}"
            ;;
    esac
}

# Followup pipeline: reuse full task history, apply new instruction
run_followup_pipeline() {
    header "Followup: $(basename "$TASK_DIR")"

    # 1. Load ALL previous run summaries + latest run details
    step_header "1" "Load task history"
    load_previous_runs "$TASK_DIR" || { PIPELINE_STATUS="no_previous_run"; return 1; }

    # 2. Collect fresh task context (task.md + subtasks)
    step_header "2" "Collect task context"
    stage_collect_context

    # 3. Build combined context:
    #    - Original task definition
    #    - History of ALL runs (summaries)
    #    - Latest code changes (detailed, for coder to see what's already in codebase)
    #    - New instruction
    local followup_context=""
    followup_context+="# Original Task\n\n${TASK_CONTEXT}\n\n"

    if [[ -n "$PREV_RUNS_HISTORY" ]]; then
        followup_context+="---\n\n# History of Previous Runs\n\n"
        followup_context+="Below are summaries of all previous pipeline runs for this task, in chronological order.\n\n"
        followup_context+="${PREV_RUNS_HISTORY}\n\n"
    fi

    if [[ -n "$PREV_CODE_OUTPUT" ]]; then
        followup_context+="---\n\n# Latest Code Changes (already in codebase)\n\n${PREV_CODE_OUTPUT}\n\n"
    fi
    if [[ -n "$PREV_REVIEW_OUTPUT" ]]; then
        followup_context+="---\n\n# Latest Review\n\n${PREV_REVIEW_OUTPUT}\n\n"
    fi

    # Include test/validation feedback from latest run if available
    if [[ -n "${PREV_TEST_OUTPUT:-}" ]]; then
        followup_context+="---\n\n# Latest Test Results\n\n${PREV_TEST_OUTPUT}\n\n"
    fi

    followup_context+="---\n\n# New Instruction\n\n${FOLLOWUP_PROMPT}\n\n"
    followup_context+="Focus ONLY on the new instruction above. The previous changes are already in the codebase.\n"
    followup_context+="Use the run history above to understand what was already tried and what worked/failed.\n"
    followup_context+="Do NOT repeat approaches that already failed — adapt based on the feedback."

    # Override TASK_CONTEXT with enriched version
    TASK_CONTEXT=$(echo -e "$followup_context")
    local ctx_file
    ctx_file=$(next_artifact "followup_context")
    save_artifact "$ctx_file" "$TASK_CONTEXT"
    log_ok "Followup context built ($(echo "$PREV_RUNS_HISTORY" | grep -c '^## Run') previous runs)"

    # 4. Run through standard pipeline
    if [[ "$FEEDBACK_STRATEGY" == "replan" ]]; then
        run_replan_loop ""
    else
        run_direct_loop ""
    fi
}

# E2E-only pipeline
run_e2e_pipeline() {
    header "E2E Pipeline: $(basename "$TASK_DIR")"

    stage_collect_context
    E2E_ENABLED=true
    CODE_OUTPUT="(existing code, E2E re-verification)"
    stage_e2e

    if is_passing_verdict "$E2E_VERDICT"; then
        PIPELINE_STATUS="e2e_passed"
        log_ok "E2E tests passed"
    else
        PIPELINE_STATUS="e2e_failed"
        log_err "E2E tests failed"
    fi
}

# =============================================================================
# Main
# =============================================================================

main() {
    PIPELINE_START_TIME=$(date +%s)

    # Parse arguments and load config
    parse_args "$@"
    load_config
    print_config

    # Initialize run directory
    init_run_dir

    # Set up exit trap
    trap finalize EXIT

    # Run pre-pipeline hook
    run_hook "pre_pipeline"

    # Dispatch to pipeline mode
    case "$PIPELINE_MODE" in
        task)     run_task_pipeline ;;
        feature)  run_feature_pipeline ;;
        review)   run_review_pipeline ;;
        e2e)      run_e2e_pipeline ;;
        followup) run_followup_pipeline ;;
    esac
}

main "$@"
