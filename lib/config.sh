#!/usr/bin/env bash
# =============================================================================
# config.sh — Configuration loading, argument parsing, defaults
# =============================================================================

# Defaults (overridden by config.env, then by CLI args)
MODEL="${MODEL:-opus}"
REVIEW_MODEL="${REVIEW_MODEL:-opus}"
REPORT_MODEL="${REPORT_MODEL:-opus}"
MAX_RETRIES="${MAX_RETRIES:-2}"
RETRY_DELAY="${RETRY_DELAY:-3}"
MAX_FIX_ITERATIONS="${MAX_FIX_ITERATIONS:-3}"
MAX_ITERATIONS="${MAX_ITERATIONS:-5}"
FEEDBACK_STRATEGY="${FEEDBACK_STRATEGY:-replan}"
LOG_LEVEL="${LOG_LEVEL:-info}"
AUTO_GIT="${AUTO_GIT:-false}"
AUTO_COMMIT="${AUTO_COMMIT:-false}"
BRANCH_PREFIX="${BRANCH_PREFIX:-pipeline}"
LANGUAGE="${LANGUAGE:-go}"
PROJECT_ROOT="${PROJECT_ROOT:-}"
PROJECT_CONTEXT="${PROJECT_CONTEXT:-}"
BUILD_CMD="${BUILD_CMD:-}"
TEST_CMD="${TEST_CMD:-}"
LINT_CMD="${LINT_CMD:-}"
VET_CMD="${VET_CMD:-}"
VERIFY_CMDS="${VERIFY_CMDS:-}"
E2E_ENABLED="${E2E_ENABLED:-false}"
E2E_BASE_URL="${E2E_BASE_URL:-http://localhost:8000}"
SERVER_START_CMD="${SERVER_START_CMD:-}"
SERVER_STOP_CMD="${SERVER_STOP_CMD:-}"
SERVER_HEALTH_URL="${SERVER_HEALTH_URL:-}"
SERVER_STARTUP_TIMEOUT="${SERVER_STARTUP_TIMEOUT:-60}"
QA_ENABLED="${QA_ENABLED:-true}"
REPORT_ENABLED="${REPORT_ENABLED:-true}"
REPORT_LANGUAGE="${REPORT_LANGUAGE:-ru}"
RETRO_ENABLED="${RETRO_ENABLED:-true}"
DRY_RUN="${DRY_RUN:-false}"
MIGRATIONS_REPO="${MIGRATIONS_REPO:-}"
BASE_BRANCH="${BASE_BRANCH:-}"
STAIRCASE_ON_FAILURE="${STAIRCASE_ON_FAILURE:-stop}"

# Pipeline state
STAIRCASE_MODE=false
PIPELINE_MODE=""
TASK_DIR=""
TASK_DESCRIPTION=""
FOLLOWUP_PROMPT=""
FEEDBACK_FILE=""
PIPELINE_STATUS="unknown"

load_config() {
    local config_file="${PIPELINE_DIR}/config.env"
    if [[ -f "$config_file" ]]; then
        log_debug "Loading config from $config_file"
        # shellcheck source=/dev/null
        source "$config_file"
    else
        log_debug "No config.env found, using defaults"
    fi

    # Auto-detect project root if not set
    if [[ -z "$PROJECT_ROOT" ]]; then
        if [[ -n "$TASK_DIR" && -f "${TASK_DIR}/task.md" ]]; then
            # Try to find git root from task dir
            PROJECT_ROOT=$(cd "$TASK_DIR" && git rev-parse --show-toplevel 2>/dev/null || echo "")
        fi
        if [[ -z "$PROJECT_ROOT" ]]; then
            PROJECT_ROOT=$(git rev-parse --show-toplevel 2>/dev/null || pwd)
        fi
    fi

    # Auto-detect project context file
    if [[ -z "$PROJECT_CONTEXT" && -f "${PROJECT_ROOT}/CLAUDE.md" ]]; then
        PROJECT_CONTEXT="${PROJECT_ROOT}/CLAUDE.md"
    fi
}

parse_args() {
    while [[ $# -gt 0 ]]; do
        case "$1" in
            task|feature|review|e2e)
                PIPELINE_MODE="$1"
                if [[ "${2:-}" && ! "${2:-}" == --* ]]; then
                    if [[ "$PIPELINE_MODE" == "feature" || "$PIPELINE_MODE" == "review" ]]; then
                        TASK_DESCRIPTION="$2"
                    else
                        TASK_DIR="$2"
                    fi
                    shift
                fi
                ;;
            followup)
                PIPELINE_MODE="followup"
                # followup <task-dir> "<prompt>"
                if [[ "${2:-}" && ! "${2:-}" == --* ]]; then
                    TASK_DIR="$2"
                    shift
                fi
                if [[ "${2:-}" && ! "${2:-}" == --* ]]; then
                    FOLLOWUP_PROMPT="$2"
                    shift
                fi
                ;;
            --task-dir)
                TASK_DIR="$2"; shift
                ;;
            --max-iter)
                MAX_ITERATIONS="$2"; shift
                ;;
            --max-fix-iter)
                MAX_FIX_ITERATIONS="$2"; shift
                ;;
            --feedback)
                FEEDBACK_FILE="$2"; shift
                ;;
            --dry-run)
                DRY_RUN=true
                ;;
            --model)
                MODEL="$2"; shift
                ;;
            --review-model)
                REVIEW_MODEL="$2"; shift
                ;;
            --strategy)
                FEEDBACK_STRATEGY="$2"; shift
                ;;
            --e2e)
                E2E_ENABLED=true
                ;;
            --no-e2e)
                E2E_ENABLED=false
                ;;
            --no-qa)
                QA_ENABLED=false
                ;;
            --no-report)
                REPORT_ENABLED=false
                ;;
            --no-retro)
                RETRO_ENABLED=false
                ;;
            --no-git)
                AUTO_GIT=false
                ;;
            --git)
                AUTO_GIT=true
                ;;
            --base-branch)
                BASE_BRANCH="$2"; shift
                ;;
            --on-failure)
                STAIRCASE_ON_FAILURE="$2"; shift
                ;;
            -h|--help)
                usage
                exit 0
                ;;
            *)
                log_err "Unknown argument: $1"
                usage
                exit 1
                ;;
        esac
        shift
    done

    # Validate required args
    if [[ -z "$PIPELINE_MODE" ]]; then
        log_err "Pipeline mode required: task, feature, review, or e2e"
        usage
        exit 1
    fi

    if [[ "$PIPELINE_MODE" == "task" || "$PIPELINE_MODE" == "e2e" || "$PIPELINE_MODE" == "followup" ]] && [[ -z "$TASK_DIR" ]]; then
        log_err "Task directory required for mode: $PIPELINE_MODE"
        usage
        exit 1
    fi

    if [[ "$PIPELINE_MODE" == "followup" && -z "$FOLLOWUP_PROMPT" ]]; then
        log_err "Followup prompt required: ./run.sh followup <task-dir> \"<what to fix or ask>\""
        usage
        exit 1
    fi

    # Resolve task dir to absolute path
    if [[ -n "$TASK_DIR" ]]; then
        TASK_DIR=$(cd "$TASK_DIR" 2>/dev/null && pwd || echo "$TASK_DIR")
    fi
}

usage() {
    cat <<'USAGE'
Usage: run.sh <mode> [target] [options]

Modes:
  task <task-dir>                       Full pipeline: git → plan → code → test → review → report
  feature "<description>"               Quick mode: plan → code → test → review (no git, no task.md)
  review "<scope>"                      Review-only: analyze existing code
  e2e <task-dir>                        Run E2E tests only
  followup <task-dir> "<instruction>"   Fix/adjust a completed task using its full context

Options:
  --task-dir <dir>         Task directory (alternative to positional)
  --max-iter <N>           Max iterations for replan strategy (default: 5)
  --max-fix-iter <N>       Max fix cycles for direct strategy (default: 3)
  --feedback <file>        Resume from a feedback file
  --dry-run                Show pipeline flow without calling claude
  --model <name>           Override MODEL (sonnet, opus, haiku)
  --review-model <name>    Override REVIEW_MODEL
  --strategy <s>           Override FEEDBACK_STRATEGY (direct, replan)
  --e2e / --no-e2e         Enable/disable E2E testing
  --no-qa                  Skip QA test-case generation
  --no-report              Skip report generation
  --no-retro               Skip retrospective analysis
  --git / --no-git         Enable/disable git operations
  --base-branch <branch>   Base branch for staircase mode (default: auto-detect)
  --on-failure <action>    Staircase failure action: stop or skip (default: stop)
  -h, --help               Show this help

Examples:
  ./run.sh task tasks/HAP-625-image-search
  ./run.sh task tasks/CD-24368 --strategy direct --git
  ./run.sh feature "Add user authentication endpoint"
  ./run.sh review "src/services/"
  ./run.sh e2e tasks/HAP-625-image-search
  ./run.sh task tasks/HAP-625 --feedback runs/HAP-625/.../05_feedback.md
  ./run.sh followup tasks/HAP-625 "MIME validation should use http.DetectContentType"
  ./run.sh followup tasks/CD-24368 "Add support for description_orderid flag"
USAGE
}

# Print resolved config for debugging
print_config() {
    log_debug "=== Resolved Configuration ==="
    log_debug "MODE=$PIPELINE_MODE"
    log_debug "TASK_DIR=$TASK_DIR"
    log_debug "MODEL=$MODEL | REVIEW_MODEL=$REVIEW_MODEL"
    log_debug "STRATEGY=$FEEDBACK_STRATEGY"
    log_debug "MAX_ITERATIONS=$MAX_ITERATIONS | MAX_FIX_ITERATIONS=$MAX_FIX_ITERATIONS"
    log_debug "E2E_ENABLED=$E2E_ENABLED | QA=$QA_ENABLED | REPORT=$REPORT_ENABLED | RETRO=$RETRO_ENABLED"
    log_debug "GIT=$AUTO_GIT | DRY_RUN=$DRY_RUN | STAIRCASE_ON_FAILURE=$STAIRCASE_ON_FAILURE"
    log_debug "BASE_BRANCH=$BASE_BRANCH"
    log_debug "MIGRATIONS_REPO=$MIGRATIONS_REPO"
    log_debug "PROJECT_ROOT=$PROJECT_ROOT"
    log_debug "LANGUAGE=$LANGUAGE"
}
