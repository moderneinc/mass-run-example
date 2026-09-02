#!/bin/bash
# gitlab-pr.sh - Create a merge request on GitLab using REST API
#
# Arguments:
#   $1 - Origin URL
#   $2 - Target branch
#
# Environment variables (from pull-requests.sh):
#   PR_TITLE - Title for the merge request
#   PR_BODY - Body/description for the merge request
#   BRANCH_NAME - The source branch with changes
#   CRED_USER - Username from .git-credentials (optional)
#   CRED_PASS - Token from .git-credentials
#   REPO_ORIGIN - Origin hostname from repos.csv (e.g., "gitlab.com")
#   REPO_PATH - Repository path from repos.csv (e.g., "group/subgroup/repo")

ORIGIN_URL="$1"
TARGET_BRANCH="$2"

if [ -z "$CRED_PASS" ]; then
    echo "  ERROR: No GitLab token available"
    echo "  Ensure .git-credentials contains credentials for this host"
    exit 1
fi

GL_HOST=""
GL_PROJECT=""

# Prefer repos.csv path column (set by pull-requests.sh from repos.csv)
# This avoids fragile URL parsing across SSH, HTTPS, and SCP variants.
# GitLab supports nested subgroups, so the whole path is the project identifier.
if [ -n "${REPO_PATH:-}" ] && [ -n "${REPO_ORIGIN:-}" ]; then
    GL_HOST="$REPO_ORIGIN"
    GL_PROJECT="${REPO_PATH%.git}"
fi

if [ -z "$GL_HOST" ] || [ -z "$GL_PROJECT" ]; then
    echo "  ERROR: Could not determine GitLab project path"
    echo "  Ensure repos.csv has 'path' column with group/repo (e.g., my-group/my-repo)"
    echo "  Origin URL: $ORIGIN_URL"
    exit 1
fi

echo "  Parsed: host=$GL_HOST project=$GL_PROJECT"

# GitLab identifies projects by URL-encoded full path (slashes become %2F)
GL_PROJECT_ID=$(jq -rn --arg p "$GL_PROJECT" '$p|@uri')

# Both gitlab.com and self-managed GitLab expose the API at https://<host>/api/v4
API_BASE="https://$GL_HOST/api/v4"

echo "  API: $API_BASE"

# Personal/project/group access tokens use the PRIVATE-TOKEN header.
# OAuth tokens (prefixed with the standard OAuth "oauth2:" user in
# .git-credentials) must use the Authorization: Bearer header instead.
if [ "${CRED_USER:-}" = "oauth2" ]; then
    AUTH_HEADER="Authorization: Bearer $CRED_PASS"
    echo "  Auth: Using .git-credentials (bearer token)"
else
    AUTH_HEADER="PRIVATE-TOKEN: $CRED_PASS"
    echo "  Auth: Using .git-credentials (private token)"
fi

# Build MR payload using jq for proper JSON escaping
# This handles special characters, quotes, newlines safely
PR_PAYLOAD=$(jq -n \
    --arg title "${PR_TITLE:-Automated changes}" \
    --arg description "${PR_BODY:-This PR was created automatically.}" \
    --arg source_branch "$BRANCH_NAME" \
    --arg target_branch "$TARGET_BRANCH" \
    '{
        title: $title,
        description: $description,
        source_branch: $source_branch,
        target_branch: $target_branch
    }')

echo "  Creating GitLab merge request..."

# Make API request
# shellcheck disable=SC2086
PR_RESPONSE=$(curl -s --connect-timeout 10 --max-time 30 ${CURL_SSL_OPTS:-} -X POST \
    -H "$AUTH_HEADER" \
    -H "Content-Type: application/json" \
    -d "$PR_PAYLOAD" \
    "${API_BASE}/projects/${GL_PROJECT_ID}/merge_requests")

# Check response
if echo "$PR_RESPONSE" | jq -e '.iid' > /dev/null 2>&1; then
    PR_IID=$(echo "$PR_RESPONSE" | jq -r '.iid')
    PR_URL=$(echo "$PR_RESPONSE" | jq -r '.web_url')
    echo "  SUCCESS: Created merge request !$PR_IID"
    echo "  URL: $PR_URL"
else
    # GitLab reports errors as either .message (string or array) or .error
    ERROR_MSG=$(echo "$PR_RESPONSE" | jq -r '
        if (.message | type) == "array" then (.message | join("; "))
        elif (.message | type) == "object" then (.message | to_entries | map("\(.key): \(.value | if type == "array" then join(", ") else . end)") | join("; "))
        else (.message // .error // "Unknown error") end' 2>/dev/null || echo "Unknown error")
    # Check if MR already exists
    if echo "$ERROR_MSG" | grep -qi "already exists"; then
        echo "  INFO: Merge request already exists"
    else
        echo "  ERROR: $ERROR_MSG"
        echo "  Response: $PR_RESPONSE"
        exit 1
    fi
fi
