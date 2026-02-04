################################################################################
# CORE SETUP
################################################################################

FROM eclipse-temurin:8-jdk AS jdk8
FROM eclipse-temurin:11-jdk AS jdk11
FROM eclipse-temurin:17-jdk AS jdk17
FROM eclipse-temurin:21-jdk AS jdk21
FROM eclipse-temurin:25-jdk AS jdk25

# Install dependencies for the Moderne CLI
FROM jdk25 AS dependencies
RUN apt-get update && apt-get install -y curl git git-lfs jq libxml2-utils unzip wget zip vim && git lfs install

# Gather various JDK versions (for mod exec compatibility)
COPY --from=jdk8 /opt/java/openjdk /usr/lib/jvm/temurin-8-jdk
COPY --from=jdk11 /opt/java/openjdk /usr/lib/jvm/temurin-11-jdk
COPY --from=jdk17 /opt/java/openjdk /usr/lib/jvm/temurin-17-jdk
COPY --from=jdk21 /opt/java/openjdk /usr/lib/jvm/temurin-21-jdk
COPY --from=jdk25 /opt/java/openjdk /usr/lib/jvm/temurin-25-jdk

################################################################################
# MODERNE CLI SETUP
################################################################################

FROM dependencies AS modcli

# Build arguments for CLI version selection
# MODERNE_CLI_STAGE: "stable" (default) or "staging"
# MODERNE_CLI_VERSION: specific version (e.g., "3.50.0"), overrides MODERNE_CLI_STAGE
ARG MODERNE_CLI_STAGE=stable
ARG MODERNE_CLI_VERSION
ENV MODERNE_CLI_VERSION=${MODERNE_CLI_VERSION}

WORKDIR /app

# Download the Moderne CLI
# Priority: MODERNE_CLI_VERSION > MODERNE_CLI_STAGE
# Air-gapped: pre-download the jar and use COPY instead:
# COPY moderne-cli.jar /usr/local/bin/mod.jar
RUN if [ -n "${MODERNE_CLI_VERSION}" ]; then \
        echo "Downloading version: ${MODERNE_CLI_VERSION}"; \
        curl -f -s --insecure --request GET --url "https://repo1.maven.org/maven2/io/moderne/moderne-cli/${MODERNE_CLI_VERSION}/moderne-cli-${MODERNE_CLI_VERSION}.jar" --output /usr/local/bin/mod.jar; \
    elif [ "${MODERNE_CLI_STAGE}" = "staging" ]; then \
        LATEST_VERSION=$(curl -f -s --insecure --request GET --url "https://api.github.com/repos/moderneinc/moderne-cli-releases/releases" | jq '.[0].tag_name' -r | sed "s/^v//"); \
        if [ -z "${LATEST_VERSION}" ]; then \
            echo "Failed to get latest staging version"; \
            exit 1; \
        fi; \
        echo "Downloading latest staging version: ${LATEST_VERSION}"; \
        curl -f -s --insecure --request GET --url "https://repo1.maven.org/maven2/io/moderne/moderne-cli/${LATEST_VERSION}/moderne-cli-${LATEST_VERSION}.jar" --output /usr/local/bin/mod.jar; \
    else \
        LATEST_VERSION=$(curl -f -s --insecure --request GET --url "https://api.github.com/repos/moderneinc/moderne-cli-releases/releases/latest" | jq '.tag_name' -r | sed "s/^v//"); \
        if [ -z "${LATEST_VERSION}" ]; then \
            echo "Failed to get latest stable version"; \
            exit 1; \
        fi; \
        echo "Downloading latest stable version: ${LATEST_VERSION}"; \
        curl -f -s --insecure --request GET --url "https://repo1.maven.org/maven2/io/moderne/moderne-cli/${LATEST_VERSION}/moderne-cli-${LATEST_VERSION}.jar" --output /usr/local/bin/mod.jar; \
    fi

# Create mod wrapper script (same pattern as mass-ingest)
RUN echo -e '#!/bin/sh\njava -jar /usr/local/bin/mod.jar "$@"' > /usr/local/bin/mod && \
    chmod +x /usr/local/bin/mod

# Verify mod CLI is working
RUN mod --version

################################################################################
# OPTIONAL: Language Support (uncomment as needed)
################################################################################
# Most projects use Maven/Gradle wrappers and don't need these installations.
# Uncomment only if your repositories specifically require them for mod exec.

FROM modcli AS language-support

# Gradle (uncomment if projects don't use Gradle without a wrapper)
# RUN wget --no-check-certificate https://services.gradle.org/distributions/gradle-8.14-bin.zip
# RUN mkdir /opt/gradle
# RUN unzip -d /opt/gradle gradle-8.14-bin.zip
# ENV PATH="${PATH}:/opt/gradle/gradle-8.14/bin"

# Maven (uncomment if projects don't use Maven without a wrapper)
# ENV MAVEN_VERSION=3.9.11
# RUN wget --no-check-certificate https://repo1.maven.org/maven2/org/apache/maven/apache-maven/${MAVEN_VERSION}/apache-maven-${MAVEN_VERSION}-bin.tar.gz && tar xzvf apache-maven-${MAVEN_VERSION}-bin.tar.gz && rm apache-maven-${MAVEN_VERSION}-bin.tar.gz
# RUN mv apache-maven-${MAVEN_VERSION} /opt/apache-maven-${MAVEN_VERSION}
# RUN ln -s /opt/apache-maven-${MAVEN_VERSION}/bin/mvn /usr/local/bin/mvn

# Node.js (uncomment for JavaScript/TypeScript projects)
# RUN curl -fsSL https://deb.nodesource.com/setup_24.x | bash - && \
#     apt-get install -y --no-install-recommends nodejs

# Python 3.11 (uncomment for Python projects)
# RUN apt-get update && apt-get install -y software-properties-common \
#     && add-apt-repository ppa:deadsnakes/ppa && apt-get update \
#     && apt-get install -y python3.11 python3.11-venv python3.11-dev
# RUN python3.11 -m ensurepip --upgrade && python3.11 -m pip install --upgrade pip

# .NET SDK (uncomment for .NET projects)
# RUN apt-get install -y dotnet-sdk-8.0

################################################################################
# AWS CLI (for S3 access)
################################################################################

FROM language-support AS tools

# Install AWS CLI for S3 operations (architecture-aware)
RUN ARCH=$(uname -m) && \
    if [ "$ARCH" = "aarch64" ] || [ "$ARCH" = "arm64" ]; then \
        curl "https://awscli.amazonaws.com/awscli-exe-linux-aarch64.zip" -o "awscliv2.zip"; \
    else \
        curl "https://awscli.amazonaws.com/awscli-exe-linux-x86_64.zip" -o "awscliv2.zip"; \
    fi && \
    unzip awscliv2.zip && \
    ./aws/install && \
    rm -rf awscliv2.zip aws

################################################################################
# RUNTIME CONFIGURATION
################################################################################

FROM tools AS runner

# Git authentication configuration
# Credentials are configured at runtime via volume mounts (not baked into image)
RUN git config --global credential.helper "store --file=/root/.git-credentials"

# Mount git credentials at runtime with:
# docker run -v $(pwd)/.git-credentials:/root/.git-credentials:ro ...
#
# .git-credentials format (one line per host):
# https://<username>:<password>@github.com
# https://<token-name>:<token>@bitbucket.example.com

# Optional: Disable SSL verification (uncomment if needed)
# RUN git config --global http.sslVerify false

################################################################################
# OPTIONAL: Self-signed Certificates (uncomment if needed)
################################################################################
# Only needed if your artifact repository, source control, or Moderne tenant
# uses self-signed certificates.

# COPY mycert.crt /root/mycert.crt
# RUN /usr/lib/jvm/temurin-8-jdk/bin/keytool -import -noprompt -storepass changeit -file /root/mycert.crt -keystore /usr/lib/jvm/temurin-8-jdk/jre/lib/security/cacerts
# RUN /usr/lib/jvm/temurin-11-jdk/bin/keytool -import -noprompt -storepass changeit -file /root/mycert.crt -keystore /usr/lib/jvm/temurin-11-jdk/lib/security/cacerts
# RUN /usr/lib/jvm/temurin-17-jdk/bin/keytool -import -noprompt -storepass changeit -file /root/mycert.crt -keystore /usr/lib/jvm/temurin-17-jdk/lib/security/cacerts
# RUN /usr/lib/jvm/temurin-21-jdk/bin/keytool -import -noprompt -storepass changeit -file /root/mycert.crt -keystore /usr/lib/jvm/temurin-21-jdk/lib/security/cacerts
# RUN /usr/lib/jvm/temurin-25-jdk/bin/keytool -import -noprompt -storepass changeit -file /root/mycert.crt -keystore /usr/lib/jvm/temurin-25-jdk/lib/security/cacerts
# RUN mod config http trust-store edit java-home

# Optional: Configure wget for self-signed certificates
# RUN echo "ca_certificate=/root/mycert.crt" >> /root/.wgetrc

# Configure JVM options for LST processing
RUN mod config java options edit "-Xmx4g -Xss3m"

################################################################################
# FINAL SETUP
################################################################################

WORKDIR /app

# Copy scripts
COPY --chmod=755 run.sh run.sh
COPY --chmod=755 pr-scripts/ pr-scripts/

# Expose mod CLI monitor port
EXPOSE 8080

# Disable extra formatting in logs
ENV CUSTOM_CI=true

# =============================================================================
# RUNTIME ENVIRONMENT VARIABLES
# =============================================================================
# Required:
#   REPOS_CSV_LOCATION   - Path or S3 URL to repos.csv
#   RECIPE               - Recipe ID to run (e.g., org.openrewrite.java.search.FindTypes)
#   OUTPUT_LOCATION      - S3 path for output (e.g., s3://bucket/output)
#
# Required for PR creation:
#   SCM_MAPPING_CSV      - Path to scm-mapping.csv (maps origins to SCM types)
#
# Optional - License:
#   MODERNE_LICENSE_KEY  - License key (configured at runtime, not build time)
#
# Optional - Moderne tenant:
#   MODERNE_TOKEN        - Moderne API token
#   MODERNE_TENANT       - Moderne tenant URL (default: https://app.moderne.io)
#   MODERNE_HOST         - Alias for MODERNE_TENANT (for backwards compatibility)
#
# Optional - Recipe execution:
#   RECIPES_CSV_LOCATION - Path or S3 URL to recipes.csv (defines available recipes)
#   ORGANIZATION         - Organization name for syncing repos
#   RECIPE_OPTIONS       - Recipe options (e.g., "-Pfoo=bar -Pbaz=bop")
#   RECIPE_TIMEOUT       - Timeout in seconds for recipe execution (0 = no timeout)
#
# Optional - PR creation:
#   CREATE_PRS           - Set to "true" to create PRs (default: false)
#   PR_TITLE             - Title for created PRs
#   PR_BODY              - Body text for created PRs
#   BRANCH_NAME          - Branch name for changes (default: moderne/<recipe-suffix>)
#   COMMIT_MESSAGE       - Commit message for changes
#
# Optional - S3/LST Configuration:
#   LST_BUCKET           - S3 bucket URL for pre-built LSTs (e.g., s3://my-lst-bucket)
#   S3_ENDPOINT          - S3-compatible endpoint URL (e.g., for MinIO)
#   S3_REGION            - AWS region
#   S3_PROFILE           - AWS profile name

CMD ["./run.sh"]
