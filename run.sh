#!/bin/bash
# Note: We intentionally do NOT use 'set -e' here because the Moderne CLI returns:
#   - Exit code 0:  MOD SUCCEEDED
#   - Exit code -1: MOD FAILED
#   - Exit code -2: MOD PARTIALLY SUCCEEDED
# We want the script to continue through partial successes and only report errors at the end.

# Track errors for final summary
ERRORS=()

# Determine mod command - use system mod if available, otherwise use local jar
mod_command=$(command -v mod || true)
if [ -z "$mod_command" ]; then
    mod_command="java -jar mod.jar"
fi

# =============================================================================
# CLI Output Logging
# =============================================================================
# Log all CLI commands and their output to a single file
CLI_OUTPUT_FILE="./cli-output.txt"
> "$CLI_OUTPUT_FILE"  # Initialize empty file

# Helper function to run a command and log its output
# Always returns 0 to ensure script continues; errors are tracked in ERRORS array
run_and_log() {
    local cmd="$1"
    local description="${2:-$cmd}"  # Optional description for error tracking
    echo "===============================================================================" >> "$CLI_OUTPUT_FILE"
    echo "COMMAND: $cmd" >> "$CLI_OUTPUT_FILE"
    echo "TIME: $(date -Iseconds)" >> "$CLI_OUTPUT_FILE"
    echo "===============================================================================" >> "$CLI_OUTPUT_FILE"
    # Run command and capture output, also display to stdout
    eval "$cmd" 2>&1 | tee -a "$CLI_OUTPUT_FILE"
    local exit_code=${PIPESTATUS[0]}
    echo "" >> "$CLI_OUTPUT_FILE"

    # Log exit code interpretation
    if [ $exit_code -eq 0 ]; then
        echo "  -> Exit code: 0 (SUCCESS)" >> "$CLI_OUTPUT_FILE"
    elif [ $exit_code -eq 254 ] || [ $exit_code -eq -2 ]; then
        echo "  -> Exit code: $exit_code (PARTIAL SUCCESS)" >> "$CLI_OUTPUT_FILE"
    else
        echo "  -> Exit code: $exit_code (FAILED)" >> "$CLI_OUTPUT_FILE"
        ERRORS+=("$description: exit code $exit_code")
    fi

    # Always return 0 to ensure script continues
    # Errors are tracked in ERRORS array for the summary
    return 0
}

echo "=== Mass Run Starting ==="

# =============================================================================
# Reset trust store config if it points to a non-existent path
# =============================================================================
echo "=== Clearing trust store config ==="
$mod_command config http trust-store delete || true

# =============================================================================
# Configure license if provided at runtime
# =============================================================================
if [ -n "$MODERNE_LICENSE_KEY" ]; then
    echo "=== Configuring Moderne license ==="
    $mod_command config license edit "$MODERNE_LICENSE_KEY"
fi

# =============================================================================
# Configure Moderne tenant if token provided
# =============================================================================
if [ -n "$MODERNE_TOKEN" ]; then
    echo "=== Configuring Moderne tenant ==="
    MODERNE_HOST="${MODERNE_HOST:-https://app.moderne.io}"
    $mod_command config moderne edit "$MODERNE_HOST" --token "$MODERNE_TOKEN"
fi

# =============================================================================
# Required environment variables
# =============================================================================
: "${REPOS_CSV_LOCATION:?REPOS_CSV_LOCATION is required}"
: "${OUTPUT_LOCATION:?OUTPUT_LOCATION is required}"

# Recipe to run
: "${RECIPE:?RECIPE is required}"

# Optional - recipes.csv defines available recipes (the recipe catalog)
# See: https://docs.moderne.io/user-documentation/moderne-cli/references/recipes-csv/
RECIPES_CSV_LOCATION="${RECIPES_CSV_LOCATION:-}"

# Optional - Organization name for syncing repos
ORGANIZATION="${ORGANIZATION:-}"

# Optional - Recipe options (e.g., "-Pfoo=bar -Pbaz=bop")
RECIPE_OPTIONS="${RECIPE_OPTIONS:-}"

# Optional - S3 bucket for pre-built LSTs
LST_BUCKET="${LST_BUCKET:-}"

# Optional - S3 authentication (for Minio or S3-compatible storage)
S3_ENDPOINT="${S3_ENDPOINT:-}"
S3_REGION="${S3_REGION:-}"
S3_PROFILE="${S3_PROFILE:-}"

# Build AWS CLI args for S3 operations
build_aws_args() {
    local args=""
    if [ -n "$S3_ENDPOINT" ]; then
        args="$args --endpoint-url $S3_ENDPOINT"
    fi
    if [ -n "$S3_REGION" ]; then
        args="$args --region $S3_REGION"
    fi
    if [ -n "$S3_PROFILE" ]; then
        args="$args --profile $S3_PROFILE"
    fi
    echo "$args"
}
AWS_S3_ARGS=$(build_aws_args)

# Optional - PR creation settings
CREATE_PRS="${CREATE_PRS:-false}"
PR_TITLE="${PR_TITLE:-Automated changes from $RECIPE}"
PR_BODY="${PR_BODY:-}"
BRANCH_NAME="${BRANCH_NAME:-moderne/$(echo $RECIPE | sed 's/.*\.//')}"
COMMIT_MESSAGE="${COMMIT_MESSAGE:-Apply $RECIPE}"
# Note: TARGET_BRANCH is read from repos.csv for each repo (the branch column)

# Create timestamp for output directory
TIMESTAMP=$(date +%Y%m%d-%H%M%S)
OUTPUT_DIR="${OUTPUT_LOCATION}/${TIMESTAMP}"

echo "Recipe: $RECIPE"
echo "Output: $OUTPUT_DIR"
echo "Create PRs: $CREATE_PRS"

# =============================================================================
# Step 0: Download CSV files from S3 if needed and configure recipes
# =============================================================================

# Download repos.csv from S3 if needed
if [[ "$REPOS_CSV_LOCATION" == s3://* ]]; then
    echo "=== Downloading repos.csv from S3 ==="
    LOCAL_REPOS_CSV_LOCATION="./repos.csv"
    aws s3 cp $AWS_S3_ARGS "$REPOS_CSV_LOCATION" "$LOCAL_REPOS_CSV_LOCATION"
    REPOS_CSV_LOCATION="$LOCAL_REPOS_CSV_LOCATION"
    echo "  -> Downloaded to $LOCAL_REPOS_CSV_LOCATION"
fi

# Copy recipes-v5.csv to .moderne directory if provided
# The CLI automatically finds recipes-v5.csv when placed in ~/.moderne/cli/
if [ -n "$RECIPES_CSV_LOCATION" ]; then
    echo "=== Setting up recipes-v5.csv ==="
    MODERNE_CLI_DIR="/root/.moderne/cli"
    mkdir -p "$MODERNE_CLI_DIR"

    if [[ "$RECIPES_CSV_LOCATION" == s3://* ]]; then
        echo "  -> Downloading recipes-v5.csv from S3..."
        aws s3 cp $AWS_S3_ARGS "$RECIPES_CSV_LOCATION" "$MODERNE_CLI_DIR/recipes-v5.csv"
        echo "  -> Downloaded to $MODERNE_CLI_DIR/recipes-v5.csv"
    else
        echo "  -> Copying recipes-v5.csv to $MODERNE_CLI_DIR/..."
        cp "$RECIPES_CSV_LOCATION" "$MODERNE_CLI_DIR/recipes-v5.csv"
        echo "  -> Copied to $MODERNE_CLI_DIR/recipes-v5.csv"
    fi
else
    echo "=== No recipes-v5.csv configured ==="
    echo "  -> Recipes will be loaded from Moderne tenant (if configured)"
fi

# =============================================================================
# Step 0.5: Configure S3 access for LSTs
# =============================================================================
if [ -n "$LST_BUCKET" ]; then
    echo "=== Configuring S3 access for LSTs ==="
    S3_CONFIG_CMD=($mod_command config lsts artifacts s3 edit "$LST_BUCKET")
    if [ -n "$S3_ENDPOINT" ]; then
        S3_CONFIG_CMD+=(--endpoint "$S3_ENDPOINT")
    fi
    if [ -n "$S3_REGION" ]; then
        S3_CONFIG_CMD+=(--region "$S3_REGION")
    fi
    if [ -n "$S3_PROFILE" ]; then
        S3_CONFIG_CMD+=(--profile "$S3_PROFILE")
    fi
    echo "  -> Running: ${S3_CONFIG_CMD[*]}"
    "${S3_CONFIG_CMD[@]}"
    echo "  -> LST bucket configured: $LST_BUCKET"
fi

# =============================================================================
# Step 1: Sync repositories from repos.csv
# =============================================================================
# Sets up repo metadata and optionally source code from the CSV
echo "=== Step 1: Syncing repositories ==="
SYNC_OPTS=""
if [ -n "$ORGANIZATION" ]; then
    SYNC_OPTS="$SYNC_OPTS --organization $ORGANIZATION"
fi

# Sync repos - LSTs will be pulled from S3 via publishUri in repos-lock.csv
# Mass-run only uses pre-built LSTs; building is done by mass-ingest
run_and_log "$mod_command git sync csv ./repos \"$REPOS_CSV_LOCATION\" $SYNC_OPTS" "git sync csv"
echo "  -> Repos synced. LSTs will be pulled from S3 via publishUri."

# =============================================================================
# Step 2: Run the recipe
# =============================================================================
# Executes the recipe against pre-built LSTs
echo "=== Step 2: Running recipe ==="
# Allow partial success (some repos may not have matching code)
run_and_log "$mod_command run ./repos --recipe \"$RECIPE\" $RECIPE_OPTIONS" "recipe run: $RECIPE"

# Collect run logs immediately after recipe run
echo "  -> Collecting run logs..."
run_and_log "$mod_command log runs add ./repos runs.zip --last-recipe-run" "log runs add"

# =============================================================================
# Step 3: Generate data tables
# =============================================================================
# Each recipe may produce multiple data tables; export each to CSV
echo "=== Step 3: Generating data tables ==="
mkdir -p ./data-tables

# Get list of available data tables from the recipe run
# Note: Data tables are stored in ./repos/*/.moderne/run/*/
for repo_moderne in ./repos/*/.moderne/run/*/; do
    if [ -d "$repo_moderne" ]; then
        # Find all .tsv data table files and copy them
        find "$repo_moderne" -name "*.tsv" -exec cp {} ./data-tables/ \; 2>/dev/null || true
    fi
done

# Run mod study for common data table types and extract the actual data table file path
run_mod_study() {
    local data_table_name="$1"
    local cmd="$mod_command study ./repos --last-recipe-run --data-table \"$data_table_name\""

    # Log the command
    echo "===============================================================================" >> "$CLI_OUTPUT_FILE"
    echo "COMMAND: $cmd" >> "$CLI_OUTPUT_FILE"
    echo "TIME: $(date -Iseconds)" >> "$CLI_OUTPUT_FILE"
    echo "===============================================================================" >> "$CLI_OUTPUT_FILE"

    local output
    output=$(eval "$cmd" 2>&1) || true
    echo "$output" >> "$CLI_OUTPUT_FILE"
    echo "" >> "$CLI_OUTPUT_FILE"

    # Extract the data table file path from the output
    # mod study outputs the CSV path - find it in the output
    local data_table_path
    data_table_path=$(echo "$output" | grep -oE "/[^ ]+\.csv" | head -1)

    if [ -n "$data_table_path" ] && [ -f "$data_table_path" ]; then
        cp "$data_table_path" "./data-tables/${data_table_name}.csv"
        echo "  -> Collected $data_table_name"
    else
        echo "  -> No data table found for $data_table_name"
    fi
}

run_mod_study "SourcesFileResults"
run_mod_study "RecipeRunStats"

# Zip all data tables
zip -r data-tables.zip ./data-tables/ 2>/dev/null || echo "No data tables found"

# =============================================================================
# Step 4: Collect patches (if any)
# =============================================================================
# Patches are stored in ./repos/<org>/<repo>/.moderne/run/<timestamp>/fix.patch
# Rename each patch to include repo name to avoid overwriting
echo "=== Step 4: Collecting patches ==="
mkdir -p ./patches
for patch_file in $(find ./repos -path "*/.moderne/run/*/fix.patch" 2>/dev/null); do
    # Extract repo path from the patch file path
    # e.g., ./repos/ALL/kmccarp/hotsliggityprotocol/.moderne/run/xxx/fix.patch -> kmccarp-hotsliggityprotocol
    repo_path=$(echo "$patch_file" | sed -E 's|^\./repos/([^/]+/)?([^/]+/[^/]+)/\.moderne/.*|\2|' | tr '/' '-')
    if [ -n "$repo_path" ] && [ -f "$patch_file" ]; then
        cp "$patch_file" "./patches/${repo_path}.patch"
        echo "  -> Collected patch: ${repo_path}.patch"
    fi
done
zip -r patches.zip ./patches/ 2>/dev/null || echo "No patches found"

# =============================================================================
# Step 5: Verify run logs collected
# =============================================================================
echo "=== Step 5: Verifying run logs ==="
if [ -f "runs.zip" ]; then
    echo "  -> runs.zip collected ($(du -h runs.zip | cut -f1))"
else
    echo "  -> Warning: runs.zip not found"
fi

# =============================================================================
# Step 6: Create PRs (if enabled)
# =============================================================================
if [ "$CREATE_PRS" = "true" ]; then
    echo "=== Step 6: Creating PRs ==="

    # Re-sync to get full source access for git operations
    # NOTE: --last-recipe-run is NOT supported with 'mod git sync csv' (only works with 'mod git sync moderne')
    # Workaround: Filter the repos.csv to only include repos that have patch files from the recipe run
    echo "  -> Identifying repos with changes..."
    FILTERED_REPOS_CSV_LOCATION="./repos-with-changes.csv"

    # Copy header from original CSV
    head -1 "$REPOS_CSV_LOCATION" > "$FILTERED_REPOS_CSV_LOCATION"

    # Find repos that have patch files and add them to filtered CSV
    for repo_dir in ./repos/*/; do
        if ls "$repo_dir"/.moderne/run/*/fix.patch 2>/dev/null | head -1 > /dev/null; then
            REPO_NAME=$(basename "$repo_dir")
            # Find the matching line in the original CSV (match on repo name/path)
            grep -E "(^|,)$REPO_NAME(,|$)" "$REPOS_CSV_LOCATION" >> "$FILTERED_REPOS_CSV_LOCATION" 2>/dev/null || \
            grep "$REPO_NAME" "$REPOS_CSV_LOCATION" >> "$FILTERED_REPOS_CSV_LOCATION" 2>/dev/null || true
        fi
    done

    REPOS_WITH_CHANGES=$(tail -n +2 "$FILTERED_REPOS_CSV_LOCATION" | wc -l | tr -d ' ')
    echo "  -> Found $REPOS_WITH_CHANGES repos with changes"

    if [ "$REPOS_WITH_CHANGES" -eq 0 ]; then
        echo "  -> No repos have changes, skipping PR creation"
    else
        # Sync only repos with changes, now with full sources
        # Note: This may partially succeed if some repos can't be synced
        run_and_log "$mod_command git sync csv ./repos \"$FILTERED_REPOS_CSV_LOCATION\" --refresh-organization --with-sources" "git sync csv (with sources)"

        # Create branch for changes (--last-recipe-run works for mod git commands after sync)
        run_and_log "$mod_command git checkout ./repos -b \"$BRANCH_NAME\" --last-recipe-run" "git checkout"

        # Apply the recipe changes to working tree
        run_and_log "$mod_command git apply ./repos --last-recipe-run" "git apply"

        # Stage changes
        run_and_log "$mod_command git add ./repos --last-recipe-run" "git add"

        # Commit changes
        run_and_log "$mod_command git commit ./repos -m \"$COMMIT_MESSAGE\" --last-recipe-run" "git commit"

        # Push to remote
        run_and_log "$mod_command git push ./repos --last-recipe-run origin \"$BRANCH_NAME\"" "git push"

        # Create PRs using mod exec to properly handle nested org structure
        echo "=== Creating PRs for each repository ==="

        # Export environment variables for the PR scripts
        export PR_TITLE="${PR_TITLE:-Automated changes from $RECIPE}"
        export PR_BODY="${PR_BODY:-}"
        export BRANCH_NAME

        # Use mod exec to run pull-requests.sh in each repo that had changes
        # This properly handles the nested org structure (./repos/ALL/kmccarp/repo-name)
        run_and_log "$mod_command exec ./repos --last-recipe-run -- /app/pr-scripts/pull-requests.sh" "create PRs"

        # Collect PR creation logs (exec.log files)
        echo "  -> Collecting PR creation logs..."
        mkdir -p ./pr-logs
        for exec_log in $(find ./repos -path "*/.moderne/exec/*/exec.log" 2>/dev/null); do
            # Extract repo path from the exec.log path
            # e.g., ./repos/ALL/kmccarp/deep-learning-model/.moderne/exec/xxx/exec.log -> kmccarp-deep-learning-model
            repo_path=$(echo "$exec_log" | sed -E 's|^\./repos/(ALL/)?([^/]+/)?([^/]+/[^/]+)/\.moderne/.*|\3|' | tr '/' '-')
            if [ -n "$repo_path" ] && [ -f "$exec_log" ]; then
                cp "$exec_log" "./pr-logs/${repo_path}-pr.log"
                echo "  -> Collected: ${repo_path}-pr.log"
            fi
        done
        zip -r pr-logs.zip ./pr-logs/ 2>/dev/null || echo "No PR logs found"
    fi
fi

# =============================================================================
# Step 7: Upload results to S3
# =============================================================================
echo "=== Step 7: Uploading results ==="
aws s3 cp $AWS_S3_ARGS data-tables.zip "${OUTPUT_DIR}/data-tables.zip" || echo "Failed to upload data-tables.zip"
aws s3 cp $AWS_S3_ARGS patches.zip "${OUTPUT_DIR}/patches.zip" || echo "Failed to upload patches.zip"
aws s3 cp $AWS_S3_ARGS runs.zip "${OUTPUT_DIR}/runs.zip" || echo "Failed to upload runs.zip"
aws s3 cp $AWS_S3_ARGS "$CLI_OUTPUT_FILE" "${OUTPUT_DIR}/cli-output.txt" || echo "Failed to upload cli-output.txt"
if [ -f "pr-logs.zip" ]; then
    aws s3 cp $AWS_S3_ARGS pr-logs.zip "${OUTPUT_DIR}/pr-logs.zip" || echo "Failed to upload pr-logs.zip"
fi

# Write summary
echo "=== Summary ==="
{
    echo "Recipe: $RECIPE"
    echo "Recipe Options: $RECIPE_OPTIONS"
    echo "Timestamp: $TIMESTAMP"
    echo "Repos CSV: $REPOS_CSV_LOCATION"
    echo "Create PRs: $CREATE_PRS"
    echo "Branch: $BRANCH_NAME"
    echo "Repos processed: $(find ./repos -maxdepth 1 -type d | wc -l)"
    echo ""
    if [ ${#ERRORS[@]} -gt 0 ]; then
        echo "Errors encountered: ${#ERRORS[@]}"
        for err in "${ERRORS[@]}"; do
            echo "  - $err"
        done
    else
        echo "Errors encountered: 0"
    fi
} > summary.txt
cat summary.txt
aws s3 cp $AWS_S3_ARGS summary.txt "${OUTPUT_DIR}/summary.txt"

echo "=== Mass Run Complete ==="
echo "Results at: $OUTPUT_DIR"
echo "Artifacts:"
echo "  - data-tables.zip"
echo "  - patches.zip"
echo "  - runs.zip"
echo "  - cli-output.txt"
echo "  - pr-logs.zip (if PRs were created)"
echo "  - summary.txt"

# Exit with error if there were critical failures (exit code 255/-1)
# Note: Partial successes (exit code 254/-2) are not considered failures
if [ ${#ERRORS[@]} -gt 0 ]; then
    echo ""
    echo "WARNING: ${#ERRORS[@]} error(s) occurred during execution (see summary.txt)"
fi
