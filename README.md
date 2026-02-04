# Mass Run

Run [OpenRewrite](https://docs.openrewrite.org/) recipes across repositories at scale using the [Moderne CLI](https://docs.moderne.io/user-documentation/moderne-cli/getting-started/cli-intro).

## Overview

Mass-run executes recipes against pre-built LSTs (Lossless Semantic Trees) from [mass-ingest](https://github.com/moderneinc/mass-ingest-example) and produces:
- **Data tables** - Structured analysis results from the recipe
- **Patches** - Code changes that can be applied to repositories
- **Logs** - Detailed execution logs for debugging
- **Pull requests** - Optionally create PRs for code changes

## Deployment Options

Choose the deployment option that fits your needs:

| Option | Description | Best For |
|--------|-------------|----------|
| [1-quickstart](./1-quickstart/) | Single container, no monitoring | Development, testing, small deployments |
| [2-observability](./2-observability/) | Docker Compose with Grafana/Prometheus | Production single-host deployments |

## Quick Start

### 1-quickstart

```bash
# Build
docker build -t mass-run:quickstart .

# Run a search recipe
docker run --rm \
  -e REPOS_CSV_LOCATION=/app/repos.csv \
  -e RECIPE=org.openrewrite.java.search.FindTypes \
  -e OUTPUT_LOCATION=s3://your-bucket/output \
  -e MODERNE_LICENSE_KEY="your-license-key" \
  -v $(pwd)/repos.csv:/app/repos.csv:ro \
  -v ~/.aws:/root/.aws:ro \
  mass-run:quickstart
```

### 2-observability

```bash
cd 2-observability

# Configure
cp .env.example .env
# Edit .env with your settings

# Copy your repos.csv
cp /path/to/repos.csv ./repos.csv

# Start
docker compose up -d

# Access dashboards at http://localhost:3000 (admin/admin)
```

## Configuration Files

### repos.csv

Defines the repositories to run recipes against. See the [repos.csv documentation](https://docs.moderne.io/user-documentation/moderne-cli/references/repos-csv/).

```csv
cloneUrl,branch,publishUri
https://github.com/org/repo1.git,main,s3://lst-bucket/org/repo1
https://github.com/org/repo2.git,main,s3://lst-bucket/org/repo2
```

The `publishUri` column points to where the pre-built LST is stored (from mass-ingest).

### scm-mapping.csv

**Required for PR creation.** Maps repository hosts to their SCM types:

```csv
origin,scmType
github.com,GitHub
bitbucket.example.com,BitbucketDataCenter
github.mycompany.com,GitHub
```

Supported SCM types:
- `GitHub` - GitHub.com and GitHub Enterprise
- `BitbucketDataCenter` - Bitbucket Server/Data Center

### .git-credentials

For private repositories and PR creation, mount a `.git-credentials` file:

```
https://username:token@github.com
https://username:token@bitbucket.example.com
```

## Environment Variables

### Required

| Variable             | Description                                      |
|----------------------|--------------------------------------------------|
| `REPOS_CSV_LOCATION` | Path or S3 URL to repos.csv                      |
| `RECIPE`             | Recipe ID to run                                 |
| `OUTPUT_LOCATION`    | S3 path for output artifacts                     |

### License (Runtime Configuration)

| Variable              | Description                                     |
|-----------------------|-------------------------------------------------|
| `MODERNE_LICENSE_KEY` | License key (passed at runtime, not build time) |

### Moderne Tenant

| Variable          | Description                                         |
|-------------------|-----------------------------------------------------|
| `MODERNE_TOKEN`   | Moderne API token                                   |
| `MODERNE_TENANT`  | Moderne tenant URL (default: https://app.moderne.io)|

### Recipe Execution

| Variable          | Description                                         |
|-------------------|-----------------------------------------------------|
| `RECIPE_OPTIONS`  | Recipe options (e.g., `-Pfoo=bar -Pbaz=bop`)        |
| `RECIPE_TIMEOUT`  | Timeout in seconds for recipe execution (0 = none)  |
| `ORGANIZATION`    | Organization name for syncing repos                 |

### PR Creation

| Variable          | Description                                         |
|-------------------|-----------------------------------------------------|
| `CREATE_PRS`      | Set to `true` to create PRs                         |
| `SCM_MAPPING_CSV` | Path to scm-mapping.csv (required for PR creation)  |
| `PR_TITLE`        | PR title                                            |
| `PR_BODY`         | PR description                                      |
| `BRANCH_NAME`     | Branch name (default: `moderne/<recipe-suffix>`)    |
| `COMMIT_MESSAGE`  | Commit message                                      |

### S3 Configuration

| Variable      | Description                             |
|---------------|-----------------------------------------|
| `LST_BUCKET`  | S3 bucket for pre-built LSTs            |
| `S3_ENDPOINT` | S3-compatible endpoint (e.g., MinIO)    |
| `S3_REGION`   | AWS region                              |
| `S3_PROFILE`  | AWS profile name                        |

## Output Artifacts

After execution, these artifacts are uploaded to `OUTPUT_LOCATION/<timestamp>/`:

| Artifact          | Description                                  |
|-------------------|----------------------------------------------|
| `data-tables.zip` | CSV data tables from recipe execution        |
| `patches.zip`     | Patch files for each repository with changes |
| `runs.zip`        | Recipe execution logs                        |
| `cli-output.txt`  | Full CLI command output                      |
| `pr-logs.zip`     | PR creation logs (if PRs were created)       |
| `summary.txt`     | Execution summary                            |

## Build Arguments

| Argument               | Default  | Description                              |
|------------------------|----------|------------------------------------------|
| `MODERNE_CLI_VERSION`  | (latest) | Pin to specific CLI version              |
| `MODERNE_CLI_STAGE`    | `stable` | `stable` or `staging` (for pre-releases) |

Example:
```bash
# Specific version
docker build --build-arg MODERNE_CLI_VERSION=3.50.0 -t mass-run:quickstart .

# Staging builds
docker build --build-arg MODERNE_CLI_STAGE=staging -t mass-run:quickstart .
```

## Related Projects

- [mass-ingest-example](https://github.com/moderneinc/mass-ingest-example) - Build LSTs at scale
- [Moderne CLI](https://docs.moderne.io/user-documentation/moderne-cli/getting-started/cli-intro) - Command-line interface
- [OpenRewrite](https://docs.openrewrite.org/) - Recipe ecosystem
