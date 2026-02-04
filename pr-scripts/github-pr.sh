#!/bin/bash
# github-pr.sh - Create a PR on GitHub using REST API
#
# Arguments:
#   $1 - Origin URL
#   $2 - Target branch
#
# Environment variables (from pull-requests.sh):
#   PR_TITLE - Title for the pull request
#   PR_BODY - Body/description for the pull request
#   BRANCH_NAME - The source branch with changes
#   CRED_USER - Username from .git-credentials (optional)
#   CRED_PASS - Token from .git-credentials

ORIGIN_URL="$1"
TARGET_BRANCH="$2"

if [ -z "$CRED_PASS" ]; then
    echo "  ERROR: No GitHub token available"
    echo "  Ensure .git-credentials contains credentials for this host"
    exit 1
fi

# Parse GitHub URL to extract host, owner, and repo
# Formats supported:
#   https://github.com/owner/repo.git
#   https://github.com/owner/repo
#   ssh://git@github.com/owner/repo.git
#   git@github.com:owner/repo.git
#   https://github.example.com/owner/repo.git (GitHub Enterprise)

GH_HOST=""
GH_OWNER=""
GH_REPO=""

if echo "$ORIGIN_URL" | grep -qE "^ssh://"; then
    # SSH URL format: ssh://git@host/owner/repo.git or ssh://git@host:port/owner/repo.git
    GH_HOST=$(echo "$ORIGIN_URL" | sed -E 's|^ssh://[^@]+@([^/:]+).*|\1|')
    GH_OWNER=$(echo "$ORIGIN_URL" | sed -E 's|^ssh://[^@]+@[^/]+/([^/]+)/.*|\1|')
    GH_REPO=$(echo "$ORIGIN_URL" | sed -E 's|^ssh://[^@]+@[^/]+/[^/]+/([^/]+)(\.git)?$|\1|')
elif echo "$ORIGIN_URL" | grep -q "^https\?://"; then
    # HTTPS format: https://host/owner/repo.git
    GH_HOST=$(echo "$ORIGIN_URL" | sed -E 's|^https?://([^/]+)/.*|\1|')
    GH_OWNER=$(echo "$ORIGIN_URL" | sed -E 's|^https?://[^/]+/([^/]+)/.*|\1|')
    GH_REPO=$(echo "$ORIGIN_URL" | sed -E 's|^https?://[^/]+/[^/]+/([^/]+)(\.git)?$|\1|')
elif echo "$ORIGIN_URL" | grep -q "@.*:"; then
    # SCP format: git@host:owner/repo.git
    GH_HOST=$(echo "$ORIGIN_URL" | sed -E 's|^[^@]+@([^:]+):.*|\1|')
    GH_OWNER=$(echo "$ORIGIN_URL" | sed -E 's|^[^@]+@[^:]+:([^/]+)/.*|\1|')
    GH_REPO=$(echo "$ORIGIN_URL" | sed -E 's|^[^@]+@[^:]+:[^/]+/([^/]+)(\.git)?$|\1|')
fi

# Remove .git suffix if present
GH_REPO="${GH_REPO%.git}"

if [ -z "$GH_HOST" ] || [ -z "$GH_OWNER" ] || [ -z "$GH_REPO" ]; then
    echo "  ERROR: Could not parse GitHub URL: $ORIGIN_URL"
    exit 1
fi

echo "  Parsed: host=$GH_HOST owner=$GH_OWNER repo=$GH_REPO"

# Determine API base URL
# github.com uses api.github.com
# GitHub Enterprise uses https://<host>/api/v3
if [ "$GH_HOST" = "github.com" ]; then
    API_BASE="https://api.github.com"
else
    API_BASE="https://$GH_HOST/api/v3"
fi

echo "  API: $API_BASE"

# Build PR payload using jq for proper JSON escaping
# This handles special characters, quotes, newlines safely
PR_PAYLOAD=$(jq -n \
    --arg title "${PR_TITLE:-Automated changes}" \
    --arg body "${PR_BODY:-This PR was created automatically.}" \
    --arg head "$BRANCH_NAME" \
    --arg base "$TARGET_BRANCH" \
    '{title: $title, body: $body, head: $head, base: $base}')

echo "  Creating GitHub PR..."

# Make API request
# shellcheck disable=SC2086
PR_RESPONSE=$(curl -s --connect-timeout 10 --max-time 30 ${CURL_SSL_OPTS:-} -X POST \
    -H "Accept: application/vnd.github+json" \
    -H "Authorization: Bearer $CRED_PASS" \
    -H "X-GitHub-Api-Version: 2022-11-28" \
    -H "Content-Type: application/json" \
    -d "$PR_PAYLOAD" \
    "${API_BASE}/repos/${GH_OWNER}/${GH_REPO}/pulls")

# Check response
if echo "$PR_RESPONSE" | jq -e '.number' > /dev/null 2>&1; then
    PR_NUMBER=$(echo "$PR_RESPONSE" | jq -r '.number')
    PR_URL=$(echo "$PR_RESPONSE" | jq -r '.html_url')
    echo "  SUCCESS: Created PR #$PR_NUMBER"
    echo "  URL: $PR_URL"
elif echo "$PR_RESPONSE" | jq -e '.errors' > /dev/null 2>&1; then
    ERROR_MSG=$(echo "$PR_RESPONSE" | jq -r '.errors[0].message // .message // "Unknown error"')
    # Check if PR already exists
    if echo "$ERROR_MSG" | grep -qi "already exists\|pull request already exists"; then
        echo "  INFO: PR already exists"
    else
        echo "  ERROR: $ERROR_MSG"
        echo "  Response: $PR_RESPONSE"
        exit 1
    fi
else
    ERROR_MSG=$(echo "$PR_RESPONSE" | jq -r '.message // "Unknown error"' 2>/dev/null || echo "Unknown error")
    # Check for validation errors that indicate PR exists
    if echo "$ERROR_MSG" | grep -qi "already exists\|validation failed"; then
        VALIDATION_ERRORS=$(echo "$PR_RESPONSE" | jq -r '.errors[]?.message // empty' 2>/dev/null)
        if echo "$VALIDATION_ERRORS" | grep -qi "already exists"; then
            echo "  INFO: PR already exists"
        else
            echo "  ERROR: $ERROR_MSG"
            echo "  Details: $VALIDATION_ERRORS"
            echo "  Response: $PR_RESPONSE"
            exit 1
        fi
    else
        echo "  ERROR: $ERROR_MSG"
        echo "  Response: $PR_RESPONSE"
        exit 1
    fi
fi
