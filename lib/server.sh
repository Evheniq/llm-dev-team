#!/usr/bin/env bash
# =============================================================================
# server.sh — Server lifecycle for E2E testing
# =============================================================================

SERVER_PID=""

# Start server for E2E testing
start_server() {
    if [[ -z "$SERVER_START_CMD" ]]; then
        log_debug "No SERVER_START_CMD configured, skipping server start"
        return 0
    fi

    log_info "Starting server..."

    # Start server in background
    eval "$SERVER_START_CMD" > "${RUN_DIR}/server.log" 2>&1 &
    SERVER_PID=$!
    log_debug "Server started with PID: ${SERVER_PID}"

    # Wait for health check
    if [[ -n "$SERVER_HEALTH_URL" ]]; then
        log_info "Waiting for server to be healthy (${SERVER_HEALTH_URL})..."
        local elapsed=0
        while (( elapsed < SERVER_STARTUP_TIMEOUT )); do
            if curl -sf "$SERVER_HEALTH_URL" > /dev/null 2>&1; then
                log_ok "Server is healthy (${elapsed}s)"
                return 0
            fi
            sleep 2
            elapsed=$((elapsed + 2))
        done
        log_err "Server failed to become healthy within ${SERVER_STARTUP_TIMEOUT}s"
        stop_server
        return 1
    else
        # No health check, just wait a few seconds
        sleep 3
        if kill -0 "$SERVER_PID" 2>/dev/null; then
            log_ok "Server started (PID: ${SERVER_PID})"
            return 0
        else
            log_err "Server process exited immediately"
            return 1
        fi
    fi
}

# Stop server
stop_server() {
    if [[ -n "$SERVER_PID" ]] && kill -0 "$SERVER_PID" 2>/dev/null; then
        log_info "Stopping server (PID: ${SERVER_PID})..."
        kill "$SERVER_PID" 2>/dev/null || true
        wait "$SERVER_PID" 2>/dev/null || true
        SERVER_PID=""
    fi

    if [[ -n "$SERVER_STOP_CMD" ]]; then
        eval "$SERVER_STOP_CMD" 2>/dev/null || true
    fi
}
