#!/usr/bin/env bash
# =============================================================================
# logging.sh — Colors, log levels, structured logging
# =============================================================================

# Colors
readonly CLR_RESET='\033[0m'
readonly CLR_RED='\033[0;31m'
readonly CLR_GREEN='\033[0;32m'
readonly CLR_YELLOW='\033[0;33m'
readonly CLR_BLUE='\033[0;34m'
readonly CLR_CYAN='\033[0;36m'
readonly CLR_GRAY='\033[0;90m'
readonly CLR_BOLD='\033[1m'

# Icons
readonly ICON_OK="✅"
readonly ICON_FAIL="❌"
readonly ICON_WARN="⚠️"
readonly ICON_INFO="ℹ️"
readonly ICON_RUN="🚀"
readonly ICON_CLOCK="⏱️"
readonly ICON_AGENT="🤖"
readonly ICON_GIT="📦"

# Log level mapping: debug=0, info=1, warn=2, error=3
_log_level_num() {
    case "${1:-info}" in
        debug) echo 0 ;;
        info)  echo 1 ;;
        warn)  echo 2 ;;
        error) echo 3 ;;
        *)     echo 1 ;;
    esac
}

# Strip ANSI codes for log files
strip_ansi() {
    sed 's/\x1b\[[0-9;]*m//g'
}

# Core log function
# Usage: _log <level> <color> <icon> <message>
_log() {
    local level="$1" color="$2" icon="$3"
    shift 3
    local message="$*"
    local current_level
    current_level=$(_log_level_num "${LOG_LEVEL:-info}")
    local msg_level
    msg_level=$(_log_level_num "$level")

    if (( msg_level < current_level )); then
        return
    fi

    local timestamp
    timestamp=$(date '+%H:%M:%S')
    local formatted="${CLR_GRAY}[${timestamp}]${CLR_RESET} ${color}${icon} ${message}${CLR_RESET}"

    echo -e "$formatted"

    # Also write to pipeline.log if RUN_DIR is set
    if [[ -n "${RUN_DIR:-}" ]]; then
        echo -e "$formatted" | strip_ansi >> "${RUN_DIR}/pipeline.log"
    fi
}

log_debug() { _log debug "$CLR_GRAY"   "🔍" "$@"; }
log_info()  { _log info  "$CLR_BLUE"   "$ICON_INFO" "$@"; }
log_ok()    { _log info  "$CLR_GREEN"  "$ICON_OK" "$@"; }
log_warn()  { _log warn  "$CLR_YELLOW" "$ICON_WARN" "$@"; }
log_err()   { _log error "$CLR_RED"    "$ICON_FAIL" "$@"; }

# Section headers
header() {
    local title="$1"
    echo ""
    echo -e "${CLR_BOLD}${CLR_CYAN}════════════════════════════════════════════════════════════${CLR_RESET}"
    echo -e "${CLR_BOLD}${CLR_CYAN}  ${title}${CLR_RESET}"
    echo -e "${CLR_BOLD}${CLR_CYAN}════════════════════════════════════════════════════════════${CLR_RESET}"
    echo ""
    if [[ -n "${RUN_DIR:-}" ]]; then
        {
            echo ""
            echo "============================================================"
            echo "  ${title}"
            echo "============================================================"
            echo ""
        } >> "${RUN_DIR}/pipeline.log"
    fi
}

step_header() {
    local step_num="$1" step_name="$2"
    echo ""
    echo -e "${CLR_BOLD}${CLR_BLUE}── Step ${step_num}: ${step_name} ──${CLR_RESET}"
    if [[ -n "${RUN_DIR:-}" ]]; then
        echo "── Step ${step_num}: ${step_name} ──" >> "${RUN_DIR}/pipeline.log"
    fi
}

# =============================================================================
# Progress Tracker — live STATUS.md in run directory
# =============================================================================

# Stage tracking arrays
declare -a PROGRESS_STAGES=()    # stage names in order
declare -A PROGRESS_STATUS=()    # stage → status icon
declare -A PROGRESS_DETAIL=()    # stage → short result text
declare -A PROGRESS_TIME=()      # stage → start timestamp

# Register a new stage as running
progress_start() {
    local stage="$1"
    PROGRESS_STAGES+=("$stage")
    PROGRESS_STATUS["$stage"]="⏳"
    PROGRESS_DETAIL["$stage"]="running..."
    PROGRESS_TIME["$stage"]=$(date +%s)
    _write_status_file
}

# Mark stage as completed
progress_done() {
    local stage="$1"
    local detail="${2:-done}"
    local start="${PROGRESS_TIME[$stage]:-$(date +%s)}"
    local elapsed=$(( $(date +%s) - start ))
    PROGRESS_STATUS["$stage"]="✅"
    PROGRESS_DETAIL["$stage"]="${detail} (${elapsed}s)"
    _write_status_file
}

# Mark stage as failed
progress_fail() {
    local stage="$1"
    local detail="${2:-failed}"
    local start="${PROGRESS_TIME[$stage]:-$(date +%s)}"
    local elapsed=$(( $(date +%s) - start ))
    PROGRESS_STATUS["$stage"]="❌"
    PROGRESS_DETAIL["$stage"]="${detail} (${elapsed}s)"
    _write_status_file
}

# Mark stage as warning (partial success)
progress_warn() {
    local stage="$1"
    local detail="${2:-issues found}"
    local start="${PROGRESS_TIME[$stage]:-$(date +%s)}"
    local elapsed=$(( $(date +%s) - start ))
    PROGRESS_STATUS["$stage"]="⚠️"
    PROGRESS_DETAIL["$stage"]="${detail} (${elapsed}s)"
    _write_status_file
}

# Mark stage as skipped
progress_skip() {
    local stage="$1"
    local detail="${2:-skipped}"
    PROGRESS_STATUS["$stage"]="⏭️"
    PROGRESS_DETAIL["$stage"]="$detail"
    _write_status_file
}

# Write STATUS.md to run directory
_write_status_file() {
    [[ -n "${RUN_DIR:-}" ]] || return

    local status_file="${RUN_DIR}/STATUS.md"
    local now
    now=$(date '+%H:%M:%S')
    local elapsed=$(( $(date +%s) - PIPELINE_START_TIME ))
    local mins=$((elapsed / 60))
    local secs=$((elapsed % 60))

    {
        echo "# Pipeline Progress"
        echo ""
        echo "**Mode:** ${PIPELINE_MODE} | **Iteration:** ${CURRENT_ITERATION:-1} | **Elapsed:** ${mins}m ${secs}s | **Updated:** ${now}"
        echo ""
        echo "| # | Stage | Status | Result |"
        echo "|---|-------|--------|--------|"

        local i=1
        for stage in "${PROGRESS_STAGES[@]}"; do
            local status="${PROGRESS_STATUS[$stage]}"
            local detail="${PROGRESS_DETAIL[$stage]}"
            echo "| ${i} | ${stage} | ${status} | ${detail} |"
            i=$((i + 1))
        done

        echo ""

        # Show what's currently running
        local running=""
        for stage in "${PROGRESS_STAGES[@]}"; do
            if [[ "${PROGRESS_STATUS[$stage]}" == "⏳" ]]; then
                running+="${stage}, "
            fi
        done
        if [[ -n "$running" ]]; then
            echo "> **Now running:** ${running%, }"
        fi
    } > "$status_file"
}

# Final status banner
print_status_banner() {
    local status="$1" duration="$2"
    echo ""
    if [[ "$status" == "approved" || "$status" == "success" ]]; then
        echo -e "${CLR_BOLD}${CLR_GREEN}╔══════════════════════════════════════╗${CLR_RESET}"
        echo -e "${CLR_BOLD}${CLR_GREEN}║  ${ICON_OK}  PIPELINE COMPLETED: ${status^^}     ║${CLR_RESET}"
        echo -e "${CLR_BOLD}${CLR_GREEN}║  ${ICON_CLOCK}  Duration: ${duration}s              ║${CLR_RESET}"
        echo -e "${CLR_BOLD}${CLR_GREEN}╚══════════════════════════════════════╝${CLR_RESET}"
    else
        echo -e "${CLR_BOLD}${CLR_RED}╔══════════════════════════════════════╗${CLR_RESET}"
        echo -e "${CLR_BOLD}${CLR_RED}║  ${ICON_FAIL}  PIPELINE FINISHED: ${status^^}      ║${CLR_RESET}"
        echo -e "${CLR_BOLD}${CLR_RED}║  ${ICON_CLOCK}  Duration: ${duration}s              ║${CLR_RESET}"
        echo -e "${CLR_BOLD}${CLR_RED}╚══════════════════════════════════════╝${CLR_RESET}"
    fi
}
