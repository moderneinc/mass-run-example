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
#   REPO_ORIGIN - Origin hostname from repos.csv (e.g., "bitbucket.example.com")
#   REPO_PATH - Repository path from repos.csv (e.g., "PROJECT/repo")

ORIGIN_URL="$1"
TARGET_BRANCH="$2"

BB_HOST=""
BB_PROJECT=""
BB_REPO=""

# Prefer repos.csv path column (set by pull-requests.sh from repos.csv)
# This avoids fragile URL parsing across SSH, HTTPS, SCP, and /scm/ variants
if [ -n "${REPO_PATH:-}" ] && [ -n "${REPO_ORIGIN:-}" ]; then
    BB_HOST="https://$REPO_ORIGIN"
    BB_PROJECT=$(echo "$REPO_PATH" | cut -d'/' -f1)
    BB_REPO=$(echo "$REPO_PATH" | cut -d'/' -f2)
fi

if [ -z "$BB_HOST" ] || [ -z "$BB_PROJECT" ] || [ -z "$BB_REPO" ]; then
    echo "  ERROR: Could not determine Bitbucket project/repo"
    echo "  Ensure repos.csv has 'path' column with PROJECT/repo (e.g., FOO/bar)"
    echo "  Origin URL: $ORIGIN_URL"
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
