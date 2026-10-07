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
#   CRED_PASS - Personal/project access token from .git-credentials
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
# GitLab supports nested groups, so the full path is used as the project identifier
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

# GitLab accepts a URL-encoded project path in place of the numeric project ID
GL_PROJECT_ENCODED=$(jq -rn --arg p "$GL_PROJECT" '$p | @uri')
API_BASE="https://$GL_HOST/api/v4"

echo "  API: $API_BASE"

# Build MR payload using jq for proper JSON escaping
# This handles special characters, quotes, newlines safely
MR_PAYLOAD=$(jq -n \
    --arg title "${PR_TITLE:-Automated changes}" \
    --arg description "${PR_BODY:-This merge request was created automatically.}" \
    --arg source "$BRANCH_NAME" \
    --arg target "$TARGET_BRANCH" \
    '{title: $title, description: $description, source_branch: $source, target_branch: $target}')

echo "  Creating GitLab merge request..."

# Make API request
# shellcheck disable=SC2086
MR_RESPONSE=$(curl -s --connect-timeout 10 --max-time 30 ${CURL_SSL_OPTS:-} -X POST \
    -H "PRIVATE-TOKEN: $CRED_PASS" \
    -H "Content-Type: application/json" \
    -d "$MR_PAYLOAD" \
    "${API_BASE}/projects/${GL_PROJECT_ENCODED}/merge_requests")

# Check response
if echo "$MR_RESPONSE" | jq -e '.iid' > /dev/null 2>&1; then
    MR_IID=$(echo "$MR_RESPONSE" | jq -r '.iid')
    MR_URL=$(echo "$MR_RESPONSE" | jq -r '.web_url // empty')
    echo "  SUCCESS: Created MR !$MR_IID"
    if [ -n "$MR_URL" ]; then
        echo "  URL: $MR_URL"
    fi
else
    # GitLab returns .message as a string or an array, or .error for some failures
    ERROR_MSG=$(echo "$MR_RESPONSE" | jq -r '
        if (.message | type) == "array" then .message | join("; ")
        elif (.message | type) == "object" then .message | tostring
        else .message // .error // "Unknown error" end' 2>/dev/null || echo "Unknown error")
    # Check if MR already exists
    if echo "$ERROR_MSG" | grep -qi "already exists"; then
        echo "  INFO: MR already exists"
    else
        echo "  ERROR: $ERROR_MSG"
        echo "  Response: $MR_RESPONSE"
        exit 1
    fi
fi
