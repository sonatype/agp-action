#!/bin/bash
#
# Copyright (c) 2011-present Sonatype, Inc. All rights reserved.
# Includes the third-party code listed at http://links.sonatype.com/products/clm/attributions.
# "Sonatype" is a trademark of Sonatype, Inc.
#

set -e

# ============================================================================
# AGP GitHub Action Entrypoint
# Orchestrates the AGP CLI execution with GitHub Actions integration
# ============================================================================

# Initialize output file for GitHub Actions
OUTPUT_FILE="${GITHUB_OUTPUT:-/dev/null}"

# Helper function to set GitHub Actions output
set_output() {
    local name="$1"
    local value="$2"
    echo "${name}=${value}" >> "$OUTPUT_FILE"
}

# Helper function for logging
log_info() {
    echo "[AGP] $1"
}

log_error() {
    echo "[AGP] ERROR: $1" >&2
}

log_debug() {
    if [ "$INPUT_VERBOSE" = "true" ]; then
        echo "[AGP] DEBUG: $1"
    fi
}

# ============================================================================
# Setup Node.js Version
# ============================================================================

log_info "Setting up Node.js environment..."

# Source nvm
export NVM_DIR="/usr/local/nvm"
if [ -s "$NVM_DIR/nvm.sh" ]; then
    . "$NVM_DIR/nvm.sh"
else
    log_error "nvm not found at $NVM_DIR"
    exit 1
fi

# Select Node version (default: 22)
NODE_VERSION="${INPUT_NODE_VERSION:-22}"
log_info "Using Node.js version: $NODE_VERSION"

if ! nvm use "$NODE_VERSION" > /dev/null 2>&1; then
    log_error "Failed to switch to Node.js $NODE_VERSION"
    exit 1
fi

node --version
npm --version

# ============================================================================
# Setup .npmrc (if provided)
# ============================================================================

CLEANUP_NPMRC=false

if [ -n "$INPUT_NPMRC_CONTENT" ]; then
    log_info "Setting up .npmrc from provided content..."

    # Decode base64 .npmrc content
    if ! echo "$INPUT_NPMRC_CONTENT" | base64 -d > "$HOME/.npmrc" 2>/dev/null; then
        log_error "Failed to decode .npmrc content (invalid base64)"
        exit 1
    fi

    CLEANUP_NPMRC=true
    log_debug ".npmrc configured successfully"
fi

# ============================================================================
# Setup agp.yml Config (if validation commands provided)
# ============================================================================

WORKING_DIR="${INPUT_WORKING_DIRECTORY:-.}"

if [ -n "$INPUT_VALIDATION_COMMANDS" ]; then
    log_info "Creating agp.yml with validation commands..."

    # Create agp.yml in the working directory
    AGP_CONFIG_FILE="$WORKING_DIR/agp.yml"

    # Check if agp.yml already exists
    if [ -f "$AGP_CONFIG_FILE" ]; then
        log_info "agp.yml already exists, validation commands from input will be ignored"
        log_info "To use custom validation commands, remove agp.yml or update it directly"
    else
        # Parse newline-separated commands into YAML array
        cat > "$AGP_CONFIG_FILE" << 'AGPEOF'
version: "1"
validation:
  enabled: true
  commands:
AGPEOF

        # Add each command as a YAML array item
        echo "$INPUT_VALIDATION_COMMANDS" | while IFS= read -r cmd; do
            if [ -n "$cmd" ]; then
                echo "    - \"$cmd\"" >> "$AGP_CONFIG_FILE"
            fi
        done

        log_debug "Generated agp.yml:"
        if [ "$INPUT_VERBOSE" = "true" ]; then
            cat "$AGP_CONFIG_FILE"
        fi
    fi
fi

# ============================================================================
# Build AGP Command
# ============================================================================

log_info "Building AGP command..."

AGP_ARGS=("run" "$WORKING_DIR")

# Add flags based on inputs
if [ "$INPUT_CREATE_PR" = "true" ]; then
    AGP_ARGS+=("--pr")
    log_debug "PR creation enabled"
fi

if [ "$INPUT_DRAFT_PR" = "true" ]; then
    AGP_ARGS+=("--draft")
    log_debug "Draft PR mode enabled"
fi

if [ "$INPUT_DRY_RUN" = "true" ]; then
    AGP_ARGS+=("--dry-run")
    log_debug "Dry run mode enabled"
fi

if [ "$INPUT_ENABLE_AGENT" = "false" ]; then
    AGP_ARGS+=("--no-agent")
    log_debug "Agent disabled"
fi

if [ -n "$INPUT_GROUP" ]; then
    AGP_ARGS+=("--group" "$INPUT_GROUP")
    log_debug "Filtering to group: $INPUT_GROUP"
fi

if [ -n "$INPUT_MAX_FIX_ATTEMPTS" ]; then
    AGP_ARGS+=("--max-fix-attempts" "$INPUT_MAX_FIX_ATTEMPTS")
    log_debug "Max fix attempts: $INPUT_MAX_FIX_ATTEMPTS"
fi

if [ "$INPUT_VERBOSE" = "true" ]; then
    AGP_ARGS+=("--verbose")
    log_debug "Verbose mode enabled"
fi

# ============================================================================
# Set Environment Variables
# ============================================================================

# Pass through Anthropic base URL if provided
if [ -n "$INPUT_ANTHROPIC_BASE_URL" ]; then
    export ANTHROPIC_BASE_URL="$INPUT_ANTHROPIC_BASE_URL"
    log_debug "Using custom Anthropic base URL"
fi

# ============================================================================
# Execute AGP
# ============================================================================

log_info "Running AGP..."
log_info "Command: agp ${AGP_ARGS[*]}"

# Create temp file for output capture
AGP_OUTPUT_FILE=$(mktemp)

# Run AGP and capture output while also displaying it
set +e
agp "${AGP_ARGS[@]}" 2>&1 | tee "$AGP_OUTPUT_FILE"
AGP_EXIT_CODE=${PIPESTATUS[0]}
set -e

# ============================================================================
# Parse Output and Set GitHub Actions Outputs
# ============================================================================

log_info "Parsing AGP output..."

# Initialize counters
GROUPS_UPGRADED=0
GROUPS_FAILED=0
PR_URLS="[]"
RUN_ID=""

# Extract run ID from output (format: "Run ID: xxx")
if grep -q "Run ID:" "$AGP_OUTPUT_FILE"; then
    RUN_ID=$(grep "Run ID:" "$AGP_OUTPUT_FILE" | head -1 | sed 's/.*Run ID: //' | tr -d ' ')
fi

# Count success/failure from progress lines
# Format: "[1/3] package-name... ✓" or "[1/3] package-name... ✗"
GROUPS_UPGRADED=$(grep -c '✓$\|✓ \|success' "$AGP_OUTPUT_FILE" 2>/dev/null || echo "0")
GROUPS_FAILED=$(grep -c '✗$\|✗ \|failed' "$AGP_OUTPUT_FILE" 2>/dev/null || echo "0")

# Extract PR URLs (format: "PR: https://github.com/...")
PR_URLS_RAW=$(grep -oE 'PR: https://[^ ]+' "$AGP_OUTPUT_FILE" 2>/dev/null | sed 's/PR: //' || true)
if [ -n "$PR_URLS_RAW" ]; then
    # Convert to JSON array
    PR_URLS=$(echo "$PR_URLS_RAW" | jq -R -s -c 'split("\n") | map(select(length > 0))')
fi

# Set outputs
set_output "run-id" "$RUN_ID"
set_output "groups-upgraded" "$GROUPS_UPGRADED"
set_output "groups-failed" "$GROUPS_FAILED"
set_output "pr-urls" "$PR_URLS"

log_info "Results:"
log_info "  Run ID: ${RUN_ID:-N/A}"
log_info "  Groups upgraded: $GROUPS_UPGRADED"
log_info "  Groups failed: $GROUPS_FAILED"
log_info "  PR URLs: $PR_URLS"

# ============================================================================
# Cleanup
# ============================================================================

log_debug "Cleaning up..."

# Remove .npmrc if we created it
if [ "$CLEANUP_NPMRC" = "true" ] && [ -f "$HOME/.npmrc" ]; then
    rm -f "$HOME/.npmrc"
    log_debug "Removed .npmrc"
fi

# Remove temp output file
rm -f "$AGP_OUTPUT_FILE"

# ============================================================================
# Exit with AGP's exit code
# ============================================================================

if [ $AGP_EXIT_CODE -ne 0 ]; then
    log_error "AGP exited with code $AGP_EXIT_CODE"
fi

exit $AGP_EXIT_CODE
