# 2-observability

Docker Compose setup with Grafana and Prometheus for monitoring mass-run recipe executions. Ideal for production single-host deployments.

## Prerequisites

- Docker and Docker Compose
- Pre-built LSTs from mass-ingest (stored in S3 or accessible via `publishUri` in repos.csv)
- Git credentials for repositories (if creating PRs)

## Quick Start

### 1. Copy configuration files

```bash
# Copy environment template
cp .env.example .env

# Copy your repos.csv to this directory
cp /path/to/your/repos.csv ./repos.csv

# Copy scm-mapping.csv (required for PR creation)
cp /path/to/your/scm-mapping.csv ./scm-mapping.csv
```

### 2. Edit the .env file

Edit `.env` with your configuration:

```bash
# Required
RECIPE=org.openrewrite.java.search.FindTypes
OUTPUT_LOCATION=s3://your-bucket/mass-run-output
REPOS_CSV_LOCATION=/app/repos.csv

# Optional - License
MODERNE_LICENSE_KEY=your-license-key

# Optional - PR creation
CREATE_PRS=true
SCM_MAPPING_CSV=/app/scm-mapping.csv
```

### 3. Mount credentials (if needed)

For private repositories or PR creation, uncomment the volume mounts in `docker-compose.yml`:

```yaml
volumes:
  # Mount git credentials
  - ./.git-credentials:/root/.git-credentials:ro
  # Or mount SSH keys
  # - ./.ssh:/root/.ssh:ro
```

### 4. Start the services

```bash
docker compose up -d
```

### 5. Access the dashboards

- **Grafana**: http://localhost:3000 (admin/admin)
- **Prometheus** (optional): http://localhost:9090 (uncomment ports in docker-compose.yml)

## Architecture

```
                    ┌─────────────────┐
                    │     Grafana     │
                    │   (port 3000)   │
                    └────────┬────────┘
                             │
                             ▼
                    ┌─────────────────┐
                    │   Prometheus    │
                    │   (port 9090)   │
                    └────────┬────────┘
                             │
                             ▼
                    ┌─────────────────┐
                    │    mass-run     │
                    │   (port 8080)   │
                    └─────────────────┘
```

## Configuration

### Environment Variables

See [1-quickstart README](../1-quickstart/README.md#environment-variables) for the full list of environment variables.

### Docker Compose Services

| Service      | Port | Description                              |
|--------------|------|------------------------------------------|
| `mass-run`   | 8080 | Moderne CLI with recipe execution        |
| `prometheus` | 9090 | Metrics collection (internal by default) |
| `grafana`    | 3000 | Dashboards and visualization             |

### Volume Mounts

| Mount                        | Container Path                    | Purpose                  |
|------------------------------|-----------------------------------|--------------------------|
| `./repos.csv`                | `/app/repos.csv`                  | Repository list          |
| `./scm-mapping.csv`          | `/app/scm-mapping.csv`            | SCM type mapping         |
| `./.git-credentials`         | `/root/.git-credentials`          | Git credentials          |
| `./observability/prometheus` | `/etc/prometheus`                 | Prometheus configuration |
| `./observability/grafana`    | `/etc/grafana/provisioning`       | Grafana configuration    |

## Dashboards

Two pre-configured Grafana dashboards are included:

### Build Dashboard
Metrics for LST build operations (from mass-ingest):
- Build success/failure rates
- Build duration
- Repository processing status

### Run Dashboard
Metrics for recipe execution (from mass-run):
- Recipe execution progress
- Repositories processed
- Errors and warnings

## Monitoring Metrics

The Moderne CLI exposes Prometheus metrics at `/prometheus` on port 8080:

- Recipe execution progress
- Repository sync status
- Build/run success rates
- Processing times

## Commands

```bash
# Start all services
docker compose up -d

# View logs
docker compose logs -f mass-run

# Stop all services
docker compose down

# Rebuild after changes
docker compose build
docker compose up -d

# Clean up (including volumes)
docker compose down -v
```

## Customization

### Using a specific CLI version

In your `.env` file:

```bash
MODERNE_CLI_VERSION=3.50.0
```

Or for staging builds:

```bash
MODERNE_CLI_STAGE=staging
```

### Adding more dashboards

Place additional Grafana dashboard JSON files in:
```
./observability/grafana/dashboards/
```

They will be automatically provisioned on restart.
