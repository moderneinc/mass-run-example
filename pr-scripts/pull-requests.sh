#!/bin/bash
# pull-requests.sh - Called via 'mod exec' for each repository
# This script looks up the SCM type from scm-mapping.csv and calls the appropriate PR script
#
# Environment variables expected:
#   PR_TITLE - Title for the pull request
#   PR_BODY - Body/description for the pull request
#   BRANCH_NAME - The source branch with changes
#   SCM_MAPPING_CSV - Path to scm-mapping.csv (maps origins to SCM types)
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
echo ""
echo "Environment variables:"
echo "  BRANCH_NAME=$BRANCH_NAME"
echo "  PR_TITLE=$PR_TITLE"
echo "  PR_BODY=${PR_BODY:0:50}..."
echo "  SCM_MAPPING_CSV=$SCM_MAPPING_CSV"
echo ""
echo "Checking prerequisites..."
echo "  git version: $(git --version 2>&1 || echo 'NOT FOUND')"
echo "  curl version: $(curl --version 2>&1 | head -1 || echo 'NOT FOUND')"
echo ""

# Trap errors to help debug
trap 'echo "ERROR: Script failed at line $LINENO with exit code $?"' ERR

# =============================================================================
# Validate SCM mapping file
# =============================================================================
if [ -z "$SCM_MAPPING_CSV" ]; then
    echo "ERROR: SCM_MAPPING_CSV environment variable is not set"
    echo "  Please provide the path to scm-mapping.csv"
    exit 1
fi

if [ ! -f "$SCM_MAPPING_CSV" ]; then
    echo "ERROR: SCM mapping file not found: $SCM_MAPPING_CSV"
    echo "  Please create scm-mapping.csv with origin,scmType columns"
    exit 1
fi

echo "SCM mapping file: $SCM_MAPPING_CSV"

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

# Extract hostname from origin URL for credential lookup and SCM mapping
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

REPO_ORIGIN=$(extract_host "$ORIGIN_URL")
echo "  Origin: $REPO_ORIGIN"

if [ -z "$REPO_ORIGIN" ]; then
    echo "ERROR: Could not extract origin from URL: $ORIGIN_URL"
    exit 1
fi

# =============================================================================
# Look up repo path from repos.csv (avoids fragile URL parsing)
# =============================================================================
# repos.csv may have origin and path columns (e.g., origin=github.com, path=org/repo)
# The path column maps directly to owner/repo (GitHub) or project/repo (Bitbucket)
REPO_PATH=""
if [ -n "${REPOS_CSV_LOCATION:-}" ] && [ -f "${REPOS_CSV_LOCATION}" ]; then
    # Find the "path" column index from header
    PATH_COL=$(head -1 "$REPOS_CSV_LOCATION" | tr ',' '\n' | grep -n '^path$' | cut -d: -f1)
    if [ -n "$PATH_COL" ]; then
        REPO_PATH=$(awk -F',' -v url="$ORIGIN_URL" -v col="$PATH_COL" '$1 == url {print $col; exit}' "$REPOS_CSV_LOCATION")
        if [ -n "$REPO_PATH" ]; then
            echo "  Path: $REPO_PATH (from repos.csv)"
        fi
    fi
fi

# =============================================================================
# Look up SCM type from mapping file
# =============================================================================
# scm-mapping.csv format:
#   origin,scmType
#   github.com,GitHub
#   bitbucket.example.com,BitbucketDataCenter
lookup_scm_type() {
    local host="$1"
    local mapping_file="$2"

    # Skip comment lines (starting with #) and empty lines
    # Case-insensitive match on the origin column
    local scm_type=$(grep -v "^#" "$mapping_file" | grep -v "^$" | \
        awk -F',' -v host="$host" 'tolower($1) == tolower(host) { print $2; exit }')

    echo "$scm_type"
}

SCM_TYPE=$(lookup_scm_type "$REPO_ORIGIN" "$SCM_MAPPING_CSV")

if [ -z "$SCM_TYPE" ]; then
    echo "ERROR: No SCM type mapping found for origin: $REPO_ORIGIN"
    echo "  Please add an entry to $SCM_MAPPING_CSV:"
    echo "    $REPO_ORIGIN,<scmType>"
    echo ""
    echo "  Supported SCM types:"
    echo "    - GitHub"
    echo "    - GitLab"
    echo "    - BitbucketDataCenter"
    exit 1
fi

echo "  SCM Type: $SCM_TYPE (from mapping)"

# Look up credentials from .git-credentials
# Format: https://username:password@hostname or https://token@hostname
GIT_CREDENTIALS_FILE="${HOME}/.git-credentials"
CRED_USER=""
CRED_PASS=""

# URL-decode function (handles %XX encoding used in .git-credentials)
urldecode() {
    printf '%b' "${1//%/\\x}"
}

if [ -f "$GIT_CREDENTIALS_FILE" ] && [ -n "$REPO_ORIGIN" ]; then
    # Find the line matching this origin (anchored to avoid substring matches)
    # Escape dots in hostname for regex, then match after @ followed by port, path, or end-of-line
    ORIGIN_ESCAPED=$(echo "$REPO_ORIGIN" | sed 's/\./\\./g')
    CRED_LINE=$(grep -iE "@${ORIGIN_ESCAPED}([:/]|$)" "$GIT_CREDENTIALS_FILE" | head -1)
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
        echo "  Credentials: Not found for origin $REPO_ORIGIN"
    fi
else
    echo "  ERROR: .git-credentials file not found at $GIT_CREDENTIALS_FILE"
    echo "  PR creation requires HTTPS credentials even if you use SSH keys for git operations."
    echo "  Mount a .git-credentials file with: -v ./.git-credentials:/root/.git-credentials:ro"
    echo "  Format: https://username:token@$REPO_ORIGIN"
    exit 1
fi

# Detect SSL configuration for curl calls in sub-scripts
# If git is configured to skip SSL verification, pass that through to curl
CURL_SSL_OPTS=""
if [ "$(git config --get http.sslVerify 2>/dev/null)" = "false" ]; then
    CURL_SSL_OPTS="--insecure"
    echo "  SSL: Verification disabled (matching git http.sslVerify=false)"
fi

# Export credentials, path, and SSL config for sub-scripts
export CRED_USER
export CRED_PASS
export TARGET_BRANCH
export CURL_SSL_OPTS
export REPO_ORIGIN
export REPO_PATH

# Call appropriate PR script based on SCM type
SCRIPT_DIR="$(dirname "$0")"

case "$SCM_TYPE" in
    GitHub)
        echo "  Calling: github-pr.sh"
        "$SCRIPT_DIR/github-pr.sh" "$ORIGIN_URL" "$TARGET_BRANCH"
        ;;
    GitLab)
        echo "  Calling: gitlab-pr.sh"
        "$SCRIPT_DIR/gitlab-pr.sh" "$ORIGIN_URL" "$TARGET_BRANCH"
        ;;
    BitbucketDataCenter)
        echo "  Calling: bitbucket-data-center-pr.sh"
        "$SCRIPT_DIR/bitbucket-data-center-pr.sh" "$ORIGIN_URL" "$TARGET_BRANCH"
        ;;
    *)
        echo "ERROR: Unsupported SCM type: $SCM_TYPE"
        echo "  Supported types: GitHub, GitLab, BitbucketDataCenter"
        exit 1
        ;;
esac
