#!/bin/bash
# github-pr.sh - Create a PR on GitHub using gh CLI
#
# Arguments:
#   $1 - Origin URL
#   $2 - Target branch
#
# Environment variables (from pull-requests.sh):
#   PR_TITLE - Title for the pull request
#   PR_BODY - Body/description for the pull request
#   BRANCH_NAME - The source branch with changes
#   CRED_PASS - Token from .git-credentials

ORIGIN_URL="$1"
TARGET_BRANCH="$2"

if [ -z "$CRED_PASS" ]; then
    echo "  ERROR: No GitHub token available"
    echo "  Ensure .git-credentials contains credentials for this host"
    exit 1
fi

# Export for gh CLI
export GH_TOKEN="$CRED_PASS"

# Use gh CLI to create PR
if ! command -v gh &> /dev/null; then
    echo "  ERROR: gh CLI not found"
    exit 1
fi

echo "  Creating GitHub PR..."
PR_RESULT=$(gh pr create \
    --title "${PR_TITLE:-Automated changes}" \
    --body "${PR_BODY:-This PR was created automatically.}" \
    --base "$TARGET_BRANCH" \
    --head "$BRANCH_NAME" \
    2>&1)

EXIT_CODE=$?
if [ $EXIT_CODE -eq 0 ]; then
    echo "  SUCCESS: $PR_RESULT"
else
    # Check if PR already exists
    if echo "$PR_RESULT" | grep -qi "already exists"; then
        echo "  INFO: PR already exists"
    else
        echo "  ERROR: $PR_RESULT"
        exit 1
    fi
fi
