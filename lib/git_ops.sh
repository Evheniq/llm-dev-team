#!/usr/bin/env bash
# =============================================================================
# git_ops.sh — Git branch preparation and commit operations
# =============================================================================

# Build git prepare prompt from task metadata
build_git_prepare_prompt() {
    local task_context="$1"
    local git_prompt
    git_prompt=$(load_agent_prompt "git") || return 1

    local prompt="${git_prompt}\n\n---\n\n"
    prompt+="MODE: prepare\n\n"
    prompt+="Read the task metadata below and create a git branch for this work.\n\n"
    prompt+="Branch prefix: ${BRANCH_PREFIX}\n\n"
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
    prompt+="<task>\n${task_context}\n</task>\n\n"
    prompt+="<changes>\n${changes}\n</changes>\n"

    echo -e "$prompt"
}

# Run git prepare stage
run_git_prepare() {
    local task_context="$1"
    local output_file
    output_file=$(next_artifact "git_prepare")

    local prompt
    prompt=$(build_git_prepare_prompt "$task_context")

    if run_agent "git-prepare" "git" "$MODEL" "$output_file" "$prompt"; then
        local verdict
        verdict=$(extract_verdict "$output_file")
        if [[ "$verdict" == "SUCCESS" ]]; then
            log_ok "Git branch prepared"
            GIT_PREPARE_OUTPUT="$output_file"
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
    local output_file
    output_file=$(next_artifact "git_commit")

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
