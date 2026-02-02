#!/bin/bash
# pull-requests.sh - Called via 'mod exec' for each repository
# This script determines the SCM type and calls the appropriate PR creation script
#
# Environment variables expected:
#   PR_TITLE - Title for the pull request
#   PR_BODY - Body/description for the pull request
#   BRANCH_NAME - The source branch with changes
#
# Credentials are extracted from ~/.git-credentials (mounted at runtime)

# =============================================================================
# Debug logging - output everything to help diagnose issues
# =============================================================================
echo "=========================================="
echo "pull-requests.sh starting"
echo "=========================================="
echo "Date: $(date)"
echo "PWD: $(pwd)"
echo "User: $(whoami)"
echo "Shell: $SHELL"
echo ""
echo "Environment variables:"
echo "  BRANCH_NAME=$BRANCH_NAME"
echo "  PR_TITLE=$PR_TITLE"
echo "  PR_BODY=${PR_BODY:0:50}..."
echo "  HOME=$HOME"
echo ""
echo "Checking prerequisites..."
echo "  git version: $(git --version 2>&1 || echo 'NOT FOUND')"
echo "  curl version: $(curl --version 2>&1 | head -1 || echo 'NOT FOUND')"
echo ""

# Trap errors to help debug
trap 'echo "ERROR: Script failed at line $LINENO with exit code $?"' ERR

# Get the origin URL
echo "Getting origin URL..."
ORIGIN_URL=$(git config --get remote.origin.url 2>&1)
ORIGIN_EXIT=$?
echo "  git config exit code: $ORIGIN_EXIT"
echo "  ORIGIN_URL: $ORIGIN_URL"

if [ $ORIGIN_EXIT -ne 0 ] || [ -z "$ORIGIN_URL" ]; then
    echo "ERROR: No origin URL configured for this repository"
    echo "  git config output: $ORIGIN_URL"
    echo "  Listing remotes:"
    git remote -v 2>&1 || echo "  (git remote failed)"
    exit 1
fi

# Get target branch - this is the branch we want to merge INTO (not the current branch)
# Since we're already on the recipe branch, we need to find the original default branch
# Try multiple methods:
#   1. Check origin/HEAD symbolic ref
#   2. Look for common default branches (main, master)
#   3. Fall back to 'main'
get_target_branch() {
    # Method 1: Check origin/HEAD
    local target=$(git symbolic-ref refs/remotes/origin/HEAD 2>/dev/null | sed 's|refs/remotes/origin/||')
    if [ -n "$target" ]; then
        echo "$target"
        return
    fi

    # Method 2: Check if common default branches exist on remote
    if git show-ref --verify --quiet refs/remotes/origin/main 2>/dev/null; then
        echo "main"
        return
    fi
    if git show-ref --verify --quiet refs/remotes/origin/master 2>/dev/null; then
        echo "master"
        return
    fi

    # Method 3: Fall back to main
    echo "main"
}

TARGET_BRANCH=$(get_target_branch)

echo "Creating PR for: $(pwd)"
echo "  Origin: $ORIGIN_URL"
echo "  Source branch: $BRANCH_NAME"
echo "  Target branch: $TARGET_BRANCH"

# Extract hostname from origin URL for credential lookup
# Handle various URL formats:
#   https://github.com/org/repo.git
#   git@github.com:org/repo.git
#   ssh://git@bitbucket.example.com/project/repo.git
#   https://bitbucket.example.com/scm/project/repo.git
extract_host() {
    local url="$1"
    if echo "$url" | grep -q "^https\?://"; then
        echo "$url" | sed -E 's|^https?://([^/@]+@)?([^/:]+).*|\2|'
    elif echo "$url" | grep -q "^ssh://"; then
        echo "$url" | sed -E 's|^ssh://([^@]+@)?([^/:]+).*|\2|'
    elif echo "$url" | grep -q "@.*:"; then
        echo "$url" | sed -E 's|^[^@]+@([^:]+):.*|\1|'
    else
        echo ""
    fi
}

HOST=$(extract_host "$ORIGIN_URL")
echo "  Host: $HOST"

# Look up credentials from .git-credentials
# Format: https://username:password@hostname or https://token@hostname
GIT_CREDENTIALS_FILE="${HOME}/.git-credentials"
CRED_USER=""
CRED_PASS=""

# URL-decode function (handles %XX encoding used in .git-credentials)
urldecode() {
    printf '%b' "${1//%/\\x}"
}

if [ -f "$GIT_CREDENTIALS_FILE" ] && [ -n "$HOST" ]; then
    # Find the line matching this host
    CRED_LINE=$(grep -i "$HOST" "$GIT_CREDENTIALS_FILE" | head -1)
    if [ -n "$CRED_LINE" ]; then
        # Extract username and password/token
        # Format: https://user:pass@host or https://token@host
        if echo "$CRED_LINE" | grep -q "://[^:@]*:[^@]*@"; then
            # Has username:password format
            CRED_USER_RAW=$(echo "$CRED_LINE" | sed -E 's|^[^:]+://([^:]+):.*|\1|')
            CRED_PASS_RAW=$(echo "$CRED_LINE" | sed -E 's|^[^:]+://[^:]+:([^@]+)@.*|\1|')
            # URL-decode credentials (git-credentials stores them URL-encoded)
            CRED_USER=$(urldecode "$CRED_USER_RAW")
            CRED_PASS=$(urldecode "$CRED_PASS_RAW")
        elif echo "$CRED_LINE" | grep -q "://[^@]*@"; then
            # Has token-only format (token@host)
            CRED_PASS_RAW=$(echo "$CRED_LINE" | sed -E 's|^[^:]+://([^@]+)@.*|\1|')
            CRED_PASS=$(urldecode "$CRED_PASS_RAW")
        fi
        echo "  Credentials: Found in .git-credentials"
    else
        echo "  Credentials: Not found for host $HOST"
    fi
else
    echo "  Credentials: .git-credentials not available"
fi

# Export credentials for sub-scripts
export CRED_USER
export CRED_PASS
export TARGET_BRANCH

# Determine SCM type and call appropriate script
# Detection logic:
#   1. URL contains "github" -> GitHub
#   2. URL contains "bitbucket" or "/scm/" -> Bitbucket Data Center
#   3. Probe the server API to detect type
SCRIPT_DIR="$(dirname "$0")"

# Function to detect SCM type by probing server APIs
detect_scm_type() {
    local host="$1"

    # Build base URL for API probing
    local base_url="https://$host"
    # Handle hosts with ports (e.g., host.docker.internal:7990)
    if echo "$host" | grep -q ":"; then
        # Check if it's likely HTTP (common Bitbucket ports)
        if echo "$host" | grep -qE ":(7990|8080|80)$"; then
            base_url="http://$host"
        fi
    fi

    # Try Bitbucket Data Center endpoint
    # GET /rest/api/1.0/application-properties returns server info
    local bb_response=$(curl -s -o /dev/null -w "%{http_code}" \
        --connect-timeout 5 \
        "$base_url/rest/api/1.0/application-properties" 2>/dev/null)

    if [ "$bb_response" = "200" ] || [ "$bb_response" = "401" ]; then
        # 200 = success, 401 = auth required but endpoint exists
        echo "bitbucket"
        return
    fi

    # Try GitHub API endpoint
    local gh_response=$(curl -s -o /dev/null -w "%{http_code}" \
        --connect-timeout 5 \
        "$base_url/api/v3" 2>/dev/null)

    if [ "$gh_response" = "200" ] || [ "$gh_response" = "401" ]; then
        echo "github"
        return
    fi

    # Unknown
    echo "unknown"
}

# First try pattern matching (fast)
SCM_TYPE=""
if echo "$ORIGIN_URL" | grep -qiE "github\.com|github\."; then
    SCM_TYPE="github"
elif echo "$ORIGIN_URL" | grep -qiE "bitbucket|/scm/"; then
    SCM_TYPE="bitbucket"
fi

# If pattern matching didn't work, probe the server
if [ -z "$SCM_TYPE" ]; then
    echo "  Detecting SCM type by probing server..."
    SCM_TYPE=$(detect_scm_type "$HOST")
fi

case "$SCM_TYPE" in
    github)
        echo "  SCM: GitHub"
        "$SCRIPT_DIR/github-pr.sh" "$ORIGIN_URL" "$TARGET_BRANCH"
        ;;
    bitbucket)
        echo "  SCM: Bitbucket Data Center"
        "$SCRIPT_DIR/bitbucket-data-center-pr.sh" "$ORIGIN_URL" "$TARGET_BRANCH"
        ;;
    *)
        echo "  WARNING: Unknown SCM type for URL: $ORIGIN_URL"
        echo "  Host: $HOST"
        echo "  Skipping PR creation"
        exit 0
        ;;
esac
