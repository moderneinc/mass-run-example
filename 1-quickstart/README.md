# 1-quickstart

A simple, single-container setup for running OpenRewrite recipes against pre-built LSTs (Lossless Semantic Trees). Ideal for development, testing, and smaller deployments.

## Prerequisites

- Docker
- Pre-built LSTs from mass-ingest (stored in S3 or accessible via `publishUri` in repos.csv)
- Git credentials for repositories (if creating PRs)

## Quick Start

### 1. Build the Docker image

```bash
docker build -t mass-run:quickstart ..
```

To use a specific CLI version or staging builds:

```bash
# Specific version
docker build --build-arg MODERNE_CLI_VERSION=3.50.0 -t mass-run:quickstart ..

# Latest staging (pre-release) version
docker build --build-arg MODERNE_CLI_STAGE=staging -t mass-run:quickstart ..
```

### 2. Prepare your configuration files

**repos.csv** - List of repositories with their LST locations:
```csv
cloneUrl,branch,origin,path,publishUri
https://github.com/org/repo1.git,main,github.com,org/repo1,s3://lst-bucket/org/repo1
https://github.com/org/repo2.git,main,github.com,org/repo2,s3://lst-bucket/org/repo2
```

The `origin` and `path` columns are required for PR creation (used to identify the project/repo on the SCM host).

**scm-mapping.csv** - Required for PR creation, maps hosts to SCM types:
```csv
origin,scmType
github.com,GitHub
bitbucket.example.com,BitbucketDataCenter
gitlab.example.com,GitLab
```

**.git-credentials** - For private repositories and PR creation:
```
https://username:token@github.com
https://username:token@bitbucket.example.com
https://oauth2:glpat-token@gitlab.example.com
```

> **Note:** PR creation requires HTTPS credentials in `.git-credentials` even if you use SSH keys for git operations. The PR scripts use REST API calls that need a token for authentication.

### 3. Run the container

**Basic recipe execution (no PRs):**

```bash
docker run --rm \
  -e REPOS_CSV_LOCATION=/app/repos.csv \
  -e RECIPE=org.openrewrite.java.search.FindTypes \
  -e OUTPUT_LOCATION=s3://your-bucket/output \
  -e LST_BUCKET=s3://your-lst-bucket \
  -e MODERNE_LICENSE_KEY="your-license-key" \
  -v $(pwd)/repos.csv:/app/repos.csv:ro \
  -v ~/.aws:/root/.aws:ro \
  mass-run:quickstart
```

**With PR creation:**

```bash
docker run --rm \
  -e REPOS_CSV_LOCATION=/app/repos.csv \
  -e RECIPE=org.openrewrite.java.migrate.UpgradeToJava17 \
  -e OUTPUT_LOCATION=s3://your-bucket/output \
  -e LST_BUCKET=s3://your-lst-bucket \
  -e MODERNE_LICENSE_KEY="your-license-key" \
  -e CREATE_PRS=true \
  -e SCM_MAPPING_CSV=/app/scm-mapping.csv \
  -e PR_TITLE="Upgrade to Java 17" \
  -e PR_BODY="Automated upgrade using OpenRewrite" \
  -v $(pwd)/repos.csv:/app/repos.csv:ro \
  -v $(pwd)/scm-mapping.csv:/app/scm-mapping.csv:ro \
  -v $(pwd)/.git-credentials:/root/.git-credentials:ro \
  -v ~/.aws:/root/.aws:ro \
  mass-run:quickstart
```

## Environment Variables

### Required

| Variable            | Description                                       |
|---------------------|---------------------------------------------------|
| `REPOS_CSV_LOCATION`| Path or S3 URL to repos.csv                       |
| `RECIPE`            | Recipe ID to run                                  |
| `OUTPUT_LOCATION`   | S3 path for output artifacts                      |

### Required for PR Creation

| Variable           | Description                                        |
|--------------------|----------------------------------------------------|
| `CREATE_PRS`       | Set to `true` to enable PR creation                |
| `SCM_MAPPING_CSV`  | Path to scm-mapping.csv                            |

### Optional - License & Platform

| Variable              | Description                                    |
|-----------------------|------------------------------------------------|
| `MODERNE_LICENSE_KEY` | License key (configured at runtime)            |
| `MODERNE_TOKEN`       | Moderne platform API token                     |
| `MODERNE_TENANT`      | Moderne tenant URL (default: app.moderne.io)   |

### Optional - Recipe Execution

| Variable               | Description                                   |
|------------------------|-----------------------------------------------|
| `RECIPES_CSV_LOCATION` | Path or S3 URL to recipes catalog             |
| `ORGANIZATION`         | Organization name for repo syncing            |
| `RECIPE_OPTIONS`       | Recipe options (e.g., `-Pfoo=bar`)            |
| `RECIPE_TIMEOUT`       | Timeout in seconds (0 = no timeout)           |
| `LST_BUCKET`           | S3 bucket for pre-built LSTs                  |

### Optional - PR Settings

| Variable         | Description                                        |
|------------------|----------------------------------------------------|
| `PR_TITLE`       | PR title (default: Automated changes from RECIPE)  |
| `PR_BODY`        | PR description                                     |
| `BRANCH_NAME`    | Branch name (default: moderne/<recipe-suffix>)     |
| `COMMIT_MESSAGE` | Commit message                                     |

### Optional - S3 Configuration

| Variable      | Description                                  |
|---------------|----------------------------------------------|
| `S3_ENDPOINT` | S3-compatible endpoint (e.g., MinIO)         |
| `S3_REGION`   | AWS region                                   |
| `S3_PROFILE`  | AWS profile name                             |

## Output Artifacts

After execution, the following artifacts are uploaded to `OUTPUT_LOCATION`:

| Artifact           | Description                                  |
|--------------------|----------------------------------------------|
| `data-tables.zip`  | CSV data tables from recipe execution        |
| `patches.zip`      | Patch files for each repository with changes |
| `runs.zip`         | Recipe execution logs                        |
| `cli-output.txt`   | Full CLI command output                      |
| `pr-logs.zip`      | PR creation logs (if PRs were created)       |
| `summary.txt`      | Execution summary                            |

## Monitoring

The Moderne CLI exposes metrics at `http://localhost:8080/prometheus`. For a full monitoring setup with Grafana dashboards, see [2-observability](../2-observability/).
