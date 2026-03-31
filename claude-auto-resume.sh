#!/bin/bash

# Auto-resume script for Claude CLI tasks
# Depends only on standard shell commands and claude CLI

# Version information
VERSION="1.5.1"

# Default prompt to use when resuming
DEFAULT_PROMPT="continue"
# Default is to start new session (no -c flag)
USE_CONTINUE_FLAG=false
# Custom command execution mode
EXECUTE_MODE=false
CUSTOM_COMMAND=""
# Test mode for simulating usage limits
TEST_MODE=false
TEST_WAIT_SECONDS=0
TEST_MESSAGE_TYPE="old"  # "old" for timestamp format, "new" for time format

# Cleanup function for graceful termination
cleanup_on_exit() {
    local exit_code=$?
    
    # Always perform cleanup, regardless of exit code
    cleanup_resources
    
    if [ $exit_code -ne 0 ]; then
        echo ""
        echo "[INFO] Script terminated (exit code: $exit_code)"
        echo "[HINT] Use --help to see usage examples"
    fi
}

# Interrupt handler for SIGINT (Ctrl+C)
interrupt_handler() {
    echo ""
    echo "[INFO] Script interrupted by user (Ctrl+C)"
    echo "[INFO] Cleaning up and exiting gracefully..."
    
    # Perform cleanup
    cleanup_resources
    
    # Exit with appropriate code for interrupted processes
    exit 130
}

# Global flag to prevent double cleanup
CLEANUP_DONE=false

# Cleanup resources and temporary state
cleanup_resources() {
    # Prevent double cleanup
    if [ "$CLEANUP_DONE" = true ]; then
        return
    fi
    
    # Kill any background processes if they exist
    if [ -n "$CLAUDE_PID" ]; then
        echo "[INFO] Terminating Claude CLI process (PID: $CLAUDE_PID)..."
        kill $CLAUDE_PID 2>/dev/null
        # Wait a bit for graceful termination
        sleep 1
        # Force kill if still running
        kill -9 $CLAUDE_PID 2>/dev/null
    fi
    
    # Kill any other potential background processes started by this script
    pkill -f "timeout.*claude" 2>/dev/null
    
    # Reset variables
    CLAUDE_PID=""
    
    # Mark cleanup as done
    CLEANUP_DONE=true
}

# Set up signal handlers for graceful cleanup
trap cleanup_on_exit EXIT
trap interrupt_handler INT TERM

# Function to execute custom commands with proper error handling
execute_custom_command() {
    local command="$1"
    local start_time=$(date +%s)
    
    echo "⚠️  WARNING: About to execute custom command: '$command'"
    echo "⚠️  This command will be executed with full shell privileges."
    echo "⚠️  Press Ctrl+C within 5 seconds to cancel..."
    
    # 5-second countdown for user to cancel
    for i in 5 4 3 2 1; do
        printf "\rExecuting in %d seconds... " $i
        sleep 1
    done
    printf "\rExecuting custom command...                    \n"
    
    echo "Executing: $command"
    echo "===================="
    
    # Execute the command with proper error handling
    eval "$command"
    local exit_code=$?
    
    local end_time=$(date +%s)
    local duration=$((end_time - start_time))
    
    echo "===================="
    echo "Command completed with exit code: $exit_code"
    echo "Execution time: ${duration} seconds"
    
    if [ $exit_code -eq 0 ]; then
        echo "✓ Custom command executed successfully."
    else
        echo "✗ Custom command failed with exit code: $exit_code"
    fi
    
    return $exit_code
}

# Unified function to parse limit message and return resume timestamp
parse_limit_message() {
    local claude_output="$1"
    local resume_timestamp
    
    # Check for old format: Claude AI usage limit reached|<timestamp>
    if echo "$claude_output" | grep -q "Claude AI usage limit reached|"; then
        resume_timestamp=$(echo "$claude_output" | awk -F'|' '{print $2}')
        echo "$resume_timestamp"
        return
    fi
    
    # Check for new format (v2026): limit reached/hit your limit resets Xam/pm
    if echo "$claude_output" | grep -qE "(limit reached|hit your limit).*resets"; then
        local reset_time reset_hour reset_minute reset_period reset_hour_24
        local now_timestamp today_reset
        
        # Verbeterde extractie: pakt tijd (bijv 1am of 12:30pm) en negeert de rest
        reset_time=$(echo "$claude_output" | grep -oE "[0-9]+(:[0-9]+)?[ap]m" | head -n 1)
        
        if [ -z "$reset_time" ]; then
            echo "[ERROR] Failed to extract reset time from Claude output."
            exit 2
        fi
        
        # Convert reset time to timestamp
        reset_period=$(echo "$reset_time" | grep -oE "[ap]m")
        
        if echo "$reset_time" | grep -q ":"; then
            reset_hour=$(echo "$reset_time" | cut -d: -f1)
            reset_minute=$(echo "$reset_time" | sed 's/[ap]m//' | cut -d: -f2)
        else
            reset_hour=$(echo "$reset_time" | sed 's/[ap]m//')
            reset_minute=0
        fi
        
        if [ "$reset_period" = "am" ]; then
            [ "$reset_hour" = "12" ] && reset_hour_24=0 || reset_hour_24=$reset_hour
        else
            [ "$reset_hour" = "12" ] && reset_hour_24=12 || reset_hour_24=$((reset_hour + 12))
        fi
        
        now_timestamp=$(date +%s)
        if date --version >/dev/null 2>&1; then
            today_reset=$(date -d "today ${reset_hour_24}:${reset_minute}:00" +%s)
        else
            today_reset=$(date -j -f "%Y-%m-%d %H:%M:%S" "$(date +%Y-%m-%d) ${reset_hour_24}:${reset_minute}:00" +%s)
        fi
        
        if [ $now_timestamp -gt $today_reset ]; then
            if date --version >/dev/null 2>&1; then
                resume_timestamp=$(date -d "tomorrow ${reset_hour_24}:${reset_minute}:00" +%s)
            else
                local tomorrow=$(date -j -v+1d +%Y-%m-%d)
                resume_timestamp=$(date -j -f "%Y-%m-%d %H:%M:%S" "${tomorrow} ${reset_hour_24}:${reset_minute}:00" +%s)
            fi
        else
            resume_timestamp=$today_reset
        fi
        
        echo "$resume_timestamp"
        return
    fi
    
    echo "[ERROR] Unrecognized format: $claude_output"
    exit 2
}

# Function to check network connectivity
check_network_connectivity() {
    local connectivity_failed=true
    if ping -c 1 -W 3 8.8.8.8 >/dev/null 2>&1 || curl -s --max-time 5 https://www.google.com >/dev/null 2>&1; then
        connectivity_failed=false
    fi
    
    if [ "$connectivity_failed" = true ]; then
        echo "[ERROR] Network connectivity check failed."
        return 3
    fi
    return 0
}

# Function to validate Claude CLI environment
validate_claude_cli() {
    if ! command -v claude &> /dev/null; then
        echo "[ERROR] Claude CLI not found."
        exit 1
    fi
}

# Function to show help
show_help() {
    cat << EOF
Usage: claude-auto-resume [OPTIONS] [PROMPT]

Automatically resume Claude CLI tasks after usage limits are lifted.

OPTIONS:
    -p, --prompt PROMPT    Custom prompt (default: "continue")
    -c, --continue        Continue previous conversation
    -e, --execute COMMAND  Execute custom command after usage limit wait period
    --cmd COMMAND         Execute custom command after usage limit wait period (alias for -e)
    -h, --help           Show this help
    -v, --version        Show version information
    --check              Show system check information
    --test-mode SECONDS   [DEV] Simulate usage limit with specified wait time in seconds

EOF
}

# Parse command line arguments
CUSTOM_PROMPT="$DEFAULT_PROMPT"

while [[ $# -gt 0 ]]; do
    case $1 in
        -p|--prompt) CUSTOM_PROMPT="$2"; shift 2 ;;
        -c|--continue) USE_CONTINUE_FLAG=true; shift ;;
        -e|--execute|--cmd) EXECUTE_MODE=true; CUSTOM_COMMAND="$2"; shift 2 ;;
        -h|--help) show_help; exit 0 ;;
        -v|--version) echo "claude-auto-resume v${VERSION}"; exit 0 ;;
        --test-mode) TEST_MODE=true; TEST_WAIT_SECONDS="$2"; shift 2 ;;
        --check)
            echo "System Check for v${VERSION}"
            validate_claude_cli && echo "Claude CLI: ✓"
            check_network_connectivity && echo "Network: ✓"
            exit 0
            ;;
        *) CUSTOM_PROMPT="$1"; shift ;;
    esac
done

# Main Logic
validate_claude_cli
check_network_connectivity || exit 3

echo "Executing Claude CLI command..."
CLAUDE_OUTPUT=$(timeout 300s claude -p 'check' 2>&1)
RET_CODE=$?

# De cruciale check die nu beide formaten pakt
LIMIT_MSG=$(echo "$CLAUDE_OUTPUT" | grep -E "(hit your limit|limit reached).*resets")

# Test mode override
if [ "$TEST_MODE" = true ]; then
    LIMIT_MSG="Simulated limit"
    CLAUDE_OUTPUT="Claude AI usage limit reached|$(($(date +%s) + TEST_WAIT_SECONDS))"
fi

if [ -n "$LIMIT_MSG" ]; then
    RESUME_TIMESTAMP=$(parse_limit_message "$CLAUDE_OUTPUT")
    NOW_TIMESTAMP=$(date +%s)
    WAIT_SECONDS=$((RESUME_TIMESTAMP - NOW_TIMESTAMP))

    if [ $WAIT_SECONDS -gt 0 ]; then
        if date --version >/dev/null 2>&1; then
            RESUME_TIME_FMT=$(date -d "@$RESUME_TIMESTAMP" "+%Y-%m-%d %H:%M:%S")
        else
            RESUME_TIME_FMT=$(date -r $RESUME_TIMESTAMP "+%Y-%m-%d %H:%M:%S")
        fi
        echo "Claude usage limit detected. Waiting until $RESUME_TIME_FMT..."
        
        while [ $WAIT_SECONDS -gt 0 ]; do
            printf "\rResuming in %02d:%02d:%02d..." $((WAIT_SECONDS/3600)) $(( (WAIT_SECONDS%3600)/60 )) $((WAIT_SECONDS%60))
            sleep 1
            NOW_TIMESTAMP=$(date +%s)
            WAIT_SECONDS=$((RESUME_TIMESTAMP - NOW_TIMESTAMP))
        done
        printf "\rResume time has arrived. Retrying now.           \n"
    fi

    sleep 10
    
    if [ "$EXECUTE_MODE" = true ]; then
        execute_custom_command "$CUSTOM_COMMAND"
    else
        echo "Resuming Claude..."
        if [ "$USE_CONTINUE_FLAG" = true ]; then
            claude -c --dangerously-skip-permissions -p "$CUSTOM_PROMPT"
        else
            claude --dangerously-skip-permissions -p "$CUSTOM_PROMPT"
        fi
    fi
    exit 0
fi

# Fallback error handling
if [ $RET_CODE -ne 0 ] && [ "$EXECUTE_MODE" = false ]; then
    echo "[ERROR] Claude CLI execution failed."
    echo "[DEBUG] Output: $CLAUDE_OUTPUT"
    exit 1
fi

echo "No waiting required. Task completed."
exit 0
