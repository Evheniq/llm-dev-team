#!/usr/bin/env bash
# =============================================================================
# git_ops.sh — Git branch preparation and commit operations
# =============================================================================

LAST_BRANCH_NAME=""

# Build git prepare prompt from task metadata
# $1 = task_context, $2 = optional base_branch
build_git_prepare_prompt() {
    local task_context="$1"
    local base_branch="${2:-}"
    local git_prompt
    git_prompt=$(load_agent_prompt "git") || return 1

    local prompt="${git_prompt}\n\n---\n\n"
    prompt+="MODE: prepare\n\n"
    prompt+="Read the task metadata below and create a git branch for this work.\n\n"
    prompt+="Branch prefix: ${BRANCH_PREFIX}\n\n"
    if [[ -n "$base_branch" ]]; then
        prompt+="Base branch: ${base_branch}\n\n"
    fi
    prompt+="<task>\n${task_context}\n</task>\n"

    echo -e "$prompt"
}

# Build git commit prompt
build_git_commit_prompt() {
    local task_context="$1"
    local changes="$2"
    local git_prompt
    git_prompt=$(load_agent_prompt "git") || return 1

    local prompt="${git_prompt}\n\n---\n\n"
    prompt+="MODE: commit\n\n"
    prompt+="Commit the changes, create appropriate commit message from task metadata.\n\n"
    prompt+="IMPORTANT: Do NOT add Co-Authored-By or any AI attribution lines to the commit message.\n"
    prompt+="Do NOT mention AI, Claude, or any tool in the commit message.\n\n"
    prompt+="<task>\n${task_context}\n</task>\n\n"
    prompt+="<changes>\n${changes}\n</changes>\n"

    echo -e "$prompt"
}

# Run git prepare stage
run_git_prepare() {
    local task_context="$1"
    next_artifact "git_prepare"
    local output_file="$NEXT_ARTIFACT"

    local prompt
    prompt=$(build_git_prepare_prompt "$task_context")

    if run_agent "git-prepare" "git" "$MODEL" "$output_file" "$prompt"; then
        local verdict
        verdict=$(extract_verdict "$output_file")
        if [[ "$verdict" == "SUCCESS" ]]; then
            log_ok "Git branch prepared"
            GIT_PREPARE_OUTPUT="$output_file"
            LAST_BRANCH_NAME=$(extract_branch_name "$output_file")
            return 0
        else
            log_err "Git prepare failed"
            return 1
        fi
    fi
    return 1
}

# Run git commit stage
run_git_commit() {
    local task_context="$1"
    local changes="$2"
    next_artifact "git_commit"
    local output_file="$NEXT_ARTIFACT"

    local prompt
    prompt=$(build_git_commit_prompt "$task_context" "$changes")

    if run_agent "git-commit" "git" "$MODEL" "$output_file" "$prompt"; then
        local verdict
        verdict=$(extract_verdict "$output_file")
        if [[ "$verdict" == "SUCCESS" ]]; then
            log_ok "Changes committed and pushed"
            return 0
        else
            log_warn "Git commit had issues (check output)"
            return 1
        fi
    fi
    return 1
}

# Extract branch name from git agent output (parses BRANCH=xxx line)
extract_branch_name() {
    local output_file="$1"
    grep 'BRANCH=' "$output_file" 2>/dev/null | head -1 | sed 's/.*BRANCH=//;s/[[:space:]].*//'
}

# Run git prepare for staircase mode (with explicit base branch)
run_git_prepare_staircase() {
    local task_context="$1"
    local base_branch="$2"
    next_artifact "git_prepare"
    local output_file="$NEXT_ARTIFACT"

    local prompt
    prompt=$(build_git_prepare_prompt "$task_context" "$base_branch")

    if run_agent "git-prepare" "git" "$MODEL" "$output_file" "$prompt"; then
        local verdict
        verdict=$(extract_verdict "$output_file")
        if [[ "$verdict" == "SUCCESS" ]]; then
            log_ok "Git branch prepared (staircase from ${base_branch})"
            GIT_PREPARE_OUTPUT="$output_file"
            LAST_BRANCH_NAME=$(extract_branch_name "$output_file")
            log_info "Branch: ${LAST_BRANCH_NAME}"
            return 0
        else
            log_err "Git prepare failed (staircase)"
            return 1
        fi
    fi
    return 1
}
