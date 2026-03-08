#!/usr/bin/env bash
# =============================================================================
# agent.sh — Claude agent runner with retry logic and tool permissions
# =============================================================================

# Tool permission sets for each agent role
declare -A AGENT_TOOLS
AGENT_TOOLS[planner]="Read,Glob,Grep,Bash"
AGENT_TOOLS[coder]="Read,Write,Edit,Bash,Grep,Glob,MultiEdit"
AGENT_TOOLS[tester]="Read,Write,Edit,Bash,Grep,Glob"
AGENT_TOOLS[tester_e2e]="Read,Bash,Grep,Glob"
AGENT_TOOLS[tester_qa]="Read,Grep,Glob"
AGENT_TOOLS[reviewer]="Read,Grep,Glob,Bash"
AGENT_TOOLS[report]="Read,Grep,Glob,Bash"
AGENT_TOOLS[git]="Read,Bash,Grep,Glob"
AGENT_TOOLS[retrospective]="Read,Grep,Glob"

# Run a Claude agent with retry logic
# Usage: run_agent <step_name> <agent_role> <model> <output_file> <prompt>
run_agent() {
    local step_name="$1"
    local agent_role="$2"
    local model="$3"
    local output_file="$4"
    local prompt="$5"
    local tools="${AGENT_TOOLS[$agent_role]:-Read,Grep,Glob,Bash}"

    log_info "${ICON_AGENT} Running ${agent_role} agent (model: ${model})..."
    start_timer "$step_name"

    if [[ "$DRY_RUN" == "true" ]]; then
        log_info "[DRY RUN] Would run ${agent_role} with ${model}"
        echo "[DRY RUN] ${agent_role} output would be here" > "$output_file"
        stop_timer "$step_name"
        return 0
    fi

    local attempt=0
    local max_attempts=$((MAX_RETRIES + 1))
    local agent_log="${output_file%.md}.log"

    while (( attempt < max_attempts )); do
        attempt=$((attempt + 1))

        if (( attempt > 1 )); then
            log_warn "Retry ${attempt}/${max_attempts} for ${step_name}..."
            sleep "$RETRY_DELAY"
        fi

        log_debug "Agent call: claude -p '...' --model ${model} --allowedTools '${tools}'"

        # Run claude and capture output
        if claude -p "$prompt" \
            --model "$model" \
            --allowedTools "$tools" \
            > "$output_file" \
            2>> "$agent_log"; then

            # Verify output is non-empty
            if check_artifact "$output_file"; then
                local size
                size=$(wc -c < "$output_file" | tr -d ' ')
                stop_timer "$step_name"
                log_ok "${step_name} completed (${size} bytes)"
                return 0
            else
                log_warn "${step_name}: output file empty, retrying..."
            fi
        else
            log_warn "${step_name}: agent exited with error (attempt ${attempt})"
        fi
    done

    stop_timer "$step_name"
    log_err "${step_name}: failed after ${max_attempts} attempts"
    return 1
}

# Load agent prompt template and substitute placeholders
# Usage: load_agent_prompt <agent_name> → outputs processed template
load_agent_prompt() {
    local agent_name="$1"
    local prompt_file="${PIPELINE_DIR}/agents/${agent_name}.md"

    if [[ ! -f "$prompt_file" ]]; then
        log_err "Agent prompt not found: ${prompt_file}"
        return 1
    fi

    local template
    template=$(cat "$prompt_file")

    # Substitute common placeholders
    template="${template//\{\{LANGUAGE\}\}/${LANGUAGE}}"
    template="${template//\{\{BUILD_CMD\}\}/${BUILD_CMD}}"
    template="${template//\{\{TEST_CMD\}\}/${TEST_CMD}}"
    template="${template//\{\{LINT_CMD\}\}/${LINT_CMD}}"
    template="${template//\{\{VET_CMD\}\}/${VET_CMD}}"
    template="${template//\{\{VERIFY_CMDS\}\}/${VERIFY_CMDS}}"
    template="${template//\{\{E2E_BASE_URL\}\}/${E2E_BASE_URL}}"
    template="${template//\{\{PROJECT_NAME\}\}/${PROJECT_NAME:-}}"
    template="${template//\{\{REPORT_LANGUAGE\}\}/${REPORT_LANGUAGE}}"

    echo "$template"
}

# Load context files matching an agent role from context/ folder
# Files with no agent suffix → all agents
# Files with .agentname. in name → only matching agents
# Usage: load_context_files <agent_name> → outputs combined content
load_context_files() {
    local agent_name="$1"
    local context_dir="${PIPELINE_DIR}/context"
    local result=""

    if [[ ! -d "$context_dir" ]]; then
        return
    fi

    for f in "${context_dir}"/*.md; do
        [[ -f "$f" ]] || continue

        local basename
        basename=$(basename "$f")

        # Skip README
        [[ "$basename" == "README.md" ]] && continue

        # Check if file has agent targets in name
        # e.g. "codestyle.coder.reviewer.md" → targets are "coder" and "reviewer"
        local name_no_ext="${basename%.md}"
        local parts
        IFS='.' read -ra parts <<< "$name_no_ext"

        if (( ${#parts[@]} <= 1 )); then
            # No dots (besides .md) → for all agents
            result+="\n---\n\n## Context: ${basename}\n\n"
            result+=$(cat "$f")
            result+="\n\n"
        else
            # Has dot-separated parts → check if agent_name is among them
            local matched=false
            for part in "${parts[@]:1}"; do  # skip first part (the name)
                if [[ "$part" == "$agent_name" ]]; then
                    matched=true
                    break
                fi
            done
            if [[ "$matched" == "true" ]]; then
                result+="\n---\n\n## Context: ${basename}\n\n"
                result+=$(cat "$f")
                result+="\n\n"
            fi
        fi
    done

    echo -e "$result"
}

# Build prompt by combining agent template + context files + dynamic sections
# Usage: build_prompt <agent_name> <context_sections...>
# Context sections are passed as "TAG:content" pairs
build_prompt() {
    local agent_name="$1"
    shift

    local prompt
    prompt=$(load_agent_prompt "$agent_name") || return 1

    # Inject matching context files
    local context_files
    context_files=$(load_context_files "$agent_name")
    if [[ -n "$context_files" ]]; then
        prompt+="\n\n# Project Context\n${context_files}"
    fi

    prompt+="\n\n---\n\n"

    # Append each dynamic section wrapped in XML tags
    for section in "$@"; do
        local tag="${section%%:*}"
        local content="${section#*:}"
        prompt+="<${tag}>\n${content}\n</${tag}>\n\n"
    done

    echo -e "$prompt"
}
