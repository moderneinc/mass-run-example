#!/bin/bash
# bitbucket-data-center-pr.sh - Create a PR on Bitbucket Data Center using REST API
#
# Arguments:
#   $1 - Origin URL
#   $2 - Target branch
#
# Environment variables (from pull-requests.sh):
#   PR_TITLE - Title for the pull request
#   PR_BODY - Body/description for the pull request
#   BRANCH_NAME - The source branch with changes
#   CRED_USER - Username from .git-credentials
#   CRED_PASS - Password/token from .git-credentials

ORIGIN_URL="$1"
TARGET_BRANCH="$2"

# Parse Bitbucket URL to extract host, project, and repo
# Formats supported:
#   https://bitbucket.example.com/scm/PROJECT/repo.git
#   ssh://git@bitbucket.example.com/PROJECT/repo.git
#   ssh://git@bitbucket.example.com:7999/PROJECT/repo.git
#   https://bitbucket.example.com/projects/PROJECT/repos/repo
#   git@bitbucket.example.com:PROJECT/repo.git

BB_HOST=""
BB_PROJECT=""
BB_REPO=""

# Try each URL format in order of specificity
if echo "$ORIGIN_URL" | grep -qE "^https?://[^/]+/scm/[^/]+/"; then
    # Format: https://host/scm/PROJECT/repo.git
    BB_HOST=$(echo "$ORIGIN_URL" | sed -E 's|^(https?://[^/]+)/.*|\1|')
    BB_PROJECT=$(echo "$ORIGIN_URL" | sed -E 's|^https?://[^/]+/scm/([^/]+)/.*|\1|')
    BB_REPO=$(echo "$ORIGIN_URL" | sed -E 's|^https?://[^/]+/scm/[^/]+/([^/]+)(\.git)?$|\1|')
elif echo "$ORIGIN_URL" | grep -qE "^https?://[^/]+/projects/[^/]+/repos/"; then
    # Format: https://host/projects/PROJECT/repos/repo
    BB_HOST=$(echo "$ORIGIN_URL" | sed -E 's|^(https?://[^/]+)/.*|\1|')
    BB_PROJECT=$(echo "$ORIGIN_URL" | sed -E 's|^https?://[^/]+/projects/([^/]+)/.*|\1|')
    BB_REPO=$(echo "$ORIGIN_URL" | sed -E 's|^https?://[^/]+/projects/[^/]+/repos/([^/]+).*|\1|')
elif echo "$ORIGIN_URL" | grep -qE "^ssh://[^@]+@[^/]+/[^/]+/"; then
    # SSH format: ssh://git@host/PROJECT/repo.git or ssh://git@host:port/PROJECT/repo.git
    # Also handles: ssh://git@host:port/scm/PROJECT/repo.git
    # Extract host (may include port), then remove port for API URL
    host_with_port=$(echo "$ORIGIN_URL" | sed -E 's|^ssh://[^@]+@([^/]+)/.*|\1|')
    host_only=$(echo "$host_with_port" | sed -E 's|:.*||')
    BB_HOST="https://$host_only"
    # Strip /scm/ prefix from path if present (some BB installations include it in SSH URLs)
    ssh_path=$(echo "$ORIGIN_URL" | sed -E 's|^ssh://[^@]+@[^/]+/||')
    ssh_path=$(echo "$ssh_path" | sed -E 's|^scm/||')
    BB_PROJECT=$(echo "$ssh_path" | sed -E 's|([^/]+)/.*|\1|')
    BB_REPO=$(echo "$ssh_path" | sed -E 's|[^/]+/([^/]+)(\.git)?$|\1|')
elif echo "$ORIGIN_URL" | grep -qE "^[^@]+@[^:]+:[^/]+/"; then
    # Git format: git@host:PROJECT/repo.git
    BB_HOST=$(echo "$ORIGIN_URL" | sed -E 's|^[^@]+@([^:]+):.*|https://\1|')
    BB_PROJECT=$(echo "$ORIGIN_URL" | sed -E 's|^[^@]+@[^:]+:([^/]+)/.*|\1|')
    BB_REPO=$(echo "$ORIGIN_URL" | sed -E 's|^[^@]+@[^:]+:[^/]+/([^/]+)(\.git)?$|\1|')
fi

# Remove .git suffix if present
BB_REPO="${BB_REPO%.git}"

if [ -z "$BB_HOST" ] || [ -z "$BB_PROJECT" ] || [ -z "$BB_REPO" ]; then
    echo "  ERROR: Could not parse Bitbucket URL: $ORIGIN_URL"
    echo "  Expected formats:"
    echo "    https://host/scm/PROJECT/repo.git"
    echo "    https://host/projects/PROJECT/repos/repo"
    echo "    ssh://git@host/PROJECT/repo.git"
    echo "    git@host:PROJECT/repo.git"
    exit 1
fi

echo "  Parsed: host=$BB_HOST project=$BB_PROJECT repo=$BB_REPO"

# Build authentication header from .git-credentials
AUTH_HEADER=""

if [ -n "$CRED_PASS" ]; then
    if [ -n "$CRED_USER" ]; then
        # Username:password format - use basic auth
        AUTH_HEADER="Authorization: Basic $(echo -n "$CRED_USER:$CRED_PASS" | base64 | tr -d '\n')"
        echo "  Auth: Using .git-credentials (basic auth)"
    else
        # Token-only format - try as bearer token
        AUTH_HEADER="Authorization: Bearer $CRED_PASS"
        echo "  Auth: Using .git-credentials (bearer token)"
    fi
else
    echo "  ERROR: No Bitbucket credentials configured"
    echo "  Ensure .git-credentials contains credentials for this host"
    exit 1
fi

# Build PR payload using jq for proper JSON escaping
# This handles special characters, quotes, newlines safely
PR_PAYLOAD=$(jq -n \
    --arg title "${PR_TITLE:-Automated changes}" \
    --arg description "${PR_BODY:-This PR was created automatically.}" \
    --arg fromRef "refs/heads/$BRANCH_NAME" \
    --arg toRef "refs/heads/$TARGET_BRANCH" \
    '{
        title: $title,
        description: $description,
        fromRef: { id: $fromRef },
        toRef: { id: $toRef }
    }')

echo "  Creating Bitbucket PR..."
# shellcheck disable=SC2086
PR_RESPONSE=$(curl -s --connect-timeout 10 --max-time 30 ${CURL_SSL_OPTS:-} -X POST \
    -H "$AUTH_HEADER" \
    -H "Content-Type: application/json" \
    -d "$PR_PAYLOAD" \
    "${BB_HOST}/rest/api/1.0/projects/${BB_PROJECT}/repos/${BB_REPO}/pull-requests")

# Check if PR was created successfully
if echo "$PR_RESPONSE" | jq -e '.id' > /dev/null 2>&1; then
    PR_ID=$(echo "$PR_RESPONSE" | jq -r '.id')
    PR_LINK=$(echo "$PR_RESPONSE" | jq -r '.links.self[0].href // empty')
    echo "  SUCCESS: Created PR #$PR_ID"
    if [ -n "$PR_LINK" ]; then
        echo "  URL: $PR_LINK"
    fi
else
    ERROR_MSG=$(echo "$PR_RESPONSE" | jq -r '.errors[0].message // .message // "Unknown error"' 2>/dev/null)
    # Check if PR already exists
    if echo "$ERROR_MSG" | grep -qi "already exists\|duplicate"; then
        echo "  INFO: PR already exists"
    else
        echo "  ERROR: $ERROR_MSG"
        echo "  Response: $PR_RESPONSE"
        exit 1
    fi
fi
