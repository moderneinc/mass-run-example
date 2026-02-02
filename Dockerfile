FROM eclipse-temurin:8-jdk AS jdk8
FROM eclipse-temurin:11-jdk AS jdk11
FROM eclipse-temurin:17-jdk AS jdk17
FROM eclipse-temurin:21-jdk AS jdk21
FROM eclipse-temurin:25-jdk AS jdk25

# Import Grafana and Prometheus for monitoring
FROM grafana/grafana as grafana
FROM prom/prometheus as prometheus

# Install dependencies for the Moderne CLI
FROM jdk25 AS dependencies
RUN apt-get update && apt-get install -y git build-essential maven curl unzip jq zip

# Install JDKs (multiple versions for mod exec compatibility)
COPY --from=jdk8 /opt/java/openjdk /usr/lib/jvm/temurin-8-jdk
COPY --from=jdk11 /opt/java/openjdk /usr/lib/jvm/temurin-11-jdk
COPY --from=jdk17 /opt/java/openjdk /usr/lib/jvm/temurin-17-jdk
COPY --from=jdk21 /opt/java/openjdk /usr/lib/jvm/temurin-21-jdk
COPY --from=jdk25 /opt/java/openjdk /usr/lib/jvm/temurin-25-jdk

# Import Grafana and Prometheus into the image
COPY --from=grafana /usr/share/grafana /usr/share/grafana
COPY --from=grafana /etc/grafana /etc/grafana
COPY --from=prometheus /bin/prometheus /bin/prometheus
COPY --from=prometheus /etc/prometheus /etc/prometheus

# Copy configs for prometheus and grafana
ADD grafana-datasource.yml /etc/grafana/provisioning/datasources/grafana-datasource.yml
ADD grafana-dashboard.yml /etc/grafana/provisioning/dashboards/grafana-dashboard.yml
ADD grafana-build-dashboard.json /etc/grafana/dashboards/build.json
ADD grafana-run-dashboard.json /etc/grafana/dashboards/run.json
ADD prometheus.yml /etc/prometheus/prometheus.yml

FROM dependencies AS modcli

# =============================================================================
# BUILD ARGUMENTS
# =============================================================================
ARG MODERNE_CLI_VERSION=LATEST

# License key for the Moderne CLI
ARG MODERNE_LICENSE_KEY

# GitHub Enterprise host (for gh CLI, if not using github.com)
ARG GH_HOST

WORKDIR /app

# Download the Moderne CLI
RUN mvn dependency:get -Dartifact=io.moderne:moderne-cli:$MODERNE_CLI_VERSION \
    && mvn dependency:copy -Dartifact=io.moderne:moderne-cli:$MODERNE_CLI_VERSION -DoutputDirectory=. \
    && mv moderne-cli*.jar mod.jar

# Warm up the CLI by running a version check (downloads lazy-loaded components)
RUN java -jar mod.jar --version

# Configure license key
RUN if [ -n "$MODERNE_LICENSE_KEY" ]; then java -jar mod.jar config license edit ${MODERNE_LICENSE_KEY}; fi

# Configure git to use credential store
# Mount .git-credentials at runtime: -v /path/to/.git-credentials:/root/.git-credentials:ro
RUN git config --global credential.helper store --file=/root/.git-credentials
RUN git config --global http.sslVerify false

# Install GitHub CLI for PR creation
# See: https://github.com/cli/cli/blob/trunk/docs/install_linux.md
RUN curl -fsSL https://cli.github.com/packages/githubcli-archive-keyring.gpg | dd of=/usr/share/keyrings/githubcli-archive-keyring.gpg \
    && chmod go+r /usr/share/keyrings/githubcli-archive-keyring.gpg \
    && echo "deb [arch=$(dpkg --print-architecture) signed-by=/usr/share/keyrings/githubcli-archive-keyring.gpg] https://cli.github.com/packages stable main" | tee /etc/apt/sources.list.d/github-cli.list > /dev/null \
    && apt-get update && apt-get install -y gh

# Install AWS CLI for S3 access (architecture-aware)
# See: https://docs.aws.amazon.com/cli/latest/userguide/getting-started-install.html
RUN ARCH=$(uname -m) && \
    if [ "$ARCH" = "aarch64" ]; then \
        AWS_CLI_URL="https://awscli.amazonaws.com/awscli-exe-linux-aarch64.zip"; \
    else \
        AWS_CLI_URL="https://awscli.amazonaws.com/awscli-exe-linux-x86_64.zip"; \
    fi && \
    curl "$AWS_CLI_URL" -o "awscliv2.zip" \
    && unzip awscliv2.zip \
    && ./aws/install \
    && rm -rf awscliv2.zip aws

# Set GitHub Enterprise host if provided
ENV GH_HOST=${GH_HOST}

FROM modcli AS runner

# Expose ports: 8080 for mod monitor metrics, 3000 for Grafana, 9090 for Prometheus
EXPOSE 8080 3000 9090

WORKDIR /app
ADD run.sh run.sh
ADD entrypoint.sh entrypoint.sh
ADD pr-scripts/ pr-scripts/
RUN chmod +x run.sh entrypoint.sh pr-scripts/*.sh

# =============================================================================
# RUNTIME ENVIRONMENT VARIABLES
# =============================================================================
# Required:
#   REPOS_CSV_LOCATION  - Path or S3 URL to repos.csv
#   RECIPE              - Recipe ID to run (e.g., org.openrewrite.java.search.FindTypes)
#   OUTPUT_LOCATION     - S3 path for output (e.g., s3://bucket/output)
#
# Optional:
#   RECIPES_CSV_LOCATION - Path or S3 URL to recipes.csv (defines available recipes)
#   ORGANIZATION         - Organization name for syncing repos
#   RECIPE_OPTIONS       - Recipe options (e.g., "-Pfoo=bar -Pbaz=bop")
#   CREATE_PRS           - Set to "true" to create PRs (default: false)
#   PR_TITLE             - Title for created PRs
#   PR_BODY              - Body text for created PRs
#   BRANCH_NAME          - Branch name for changes (default: moderne/<recipe-suffix>)
#   COMMIT_MESSAGE       - Commit message for changes
#
# S3/LST Configuration:
#   LST_BUCKET            - S3 bucket URL for pre-built LSTs (e.g., s3://my-lst-bucket)
#   AWS_ACCESS_KEY_ID     - AWS access key (or Minio access key)
#   AWS_SECRET_ACCESS_KEY - AWS secret key (or Minio secret key)
#   S3_ENDPOINT           - S3-compatible endpoint URL (e.g., http://localhost:9000 for Minio)
#   S3_REGION             - AWS region (optional, for cross-region access)
#   S3_PROFILE            - AWS profile name (optional, for named profiles)
#
# Monitoring:
#   - mod monitor metrics: http://localhost:8080/prometheus
#   - Grafana dashboards:  http://localhost:3000
#   - Prometheus:          http://localhost:9090

CMD ["/app/entrypoint.sh"]
