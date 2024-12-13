FROM eclipse-temurin:17-jammy AS jdk17
# Import Grafana and Prometheus
# Comment out the following lines if you don't need Grafana and Prometheus
FROM grafana/grafana as grafana
FROM prom/prometheus as prometheus

# Install dependencies for `mod` cli
FROM jdk17 AS dependencies
RUN apt-get update && apt-get install -y git supervisor perl build-essential maven

# Install a JDK
COPY --from=jdk17 /opt/java/openjdk /usr/lib/jvm/temurin-17-jdk

# Import Grafana and Prometheus into mass-ingest image
# Comment out the following lines if you don't need Grafana and Prometheus
COPY --from=grafana /usr/share/grafana /usr/share/grafana
COPY --from=grafana /etc/grafana /etc/grafana
COPY --from=prometheus /bin/prometheus /bin/prometheus
COPY --from=prometheus /etc/prometheus /etc/prometheus

# Copy configs for prometheus and grafana
# Comment out the following lines if you don't need Grafana and Prometheus
ADD grafana-datasource.yml /etc/grafana/provisioning/datasources/grafana-datasource.yml
ADD grafana-dashboard.yml /etc/grafana/provisioning/dashboards/grafana-dashboard.yml
ADD grafana-build-dashboard.json /etc/grafana/dashboards/build.json
ADD grafana-run-dashboard.json /etc/grafana/dashboards/run.json
ADD prometheus.yml /etc/prometheus/prometheus.yml

FROM dependencies AS modcli
ARG MODERNE_CLI_VERSION=LATEST
ARG MODERNE_TENANT=app
# Personal access token for Moderne; can be created through https://<tenant>.moderne.io/settings/access-token
ARG MODERNE_TOKEN
# We recommend a dedicated Artifactory Maven repository, allowing both releases & snapshots; supply the full URL here
ARG ARTIFACTORY_DOWNLOAD_URL
ARG ARTIFACTORY_USER
ARG ARTIFACTORY_PASSWORD

# Copy some of these args to environment variables for use in the CLI
ENV ARTIFACTORY_UPLOAD_URL=$ARTIFACTORY_UPLOAD_URL
ENV ARTIFACTORY_USER=$ARTIFACTORY_USER
ENV ARTIFACTORY_PASSWORD=$ARTIFACTORY_PASSWORD
# Path to the trusted certificates file, which will replace the cacerts file in the configured JDKs if necessary
ARG TRUSTED_CERTIFICATES_PATH

WORKDIR /app
# Download the CLI and connect it to your instance of Moderne, and your own Artifactory
RUN mvn dependency:get -Dartifact=io.moderne:moderne-cli:$MODERNE_CLI_VERSION && mvn dependency:copy -Dartifact=io.moderne:moderne-cli:$MODERNE_CLI_VERSION -DoutputDirectory=. && mv moderne-cli*.jar mod.jar
RUN java -jar mod.jar config moderne edit --token=${MODERNE_TOKEN} https://${MODERNE_TENANT}.moderne.io
RUN java -jar mod.jar config lsts artifacts artifactory edit ${ARTIFACTORY_DOWNLOAD_URL} --user ${ARTIFACTORY_USER} --password ${ARTIFACTORY_PASSWORD}

# Install perl module for url encoding
RUN cpan install URI::Escape

# Configure git credentials if they are required to clone; ensure this lines up with your use of https:// or ssh://
# .git-credentials each line defines credentilas for a host in the format: https://username:password@host
ADD .git-credentials /root/.git-credentials
RUN git config --global credential.helper store --file=/root/.git-credentials
RUN git config --global http.sslVerify false

# Configure trust store if self-signed certificates are in use for artifact repository, source control, or moderne tenant
COPY ${TRUSTED_CERTIFICATES_PATH} /usr/lib/jvm/temurin-17-jdk/lib/security/cacerts
RUN java -jar mod.jar config http trust-store edit java-home

FROM modcli AS runner
EXPOSE 8080
ADD supervisord.conf /etc/supervisord.conf

WORKDIR /app
ADD run.sh run.sh
ADD recipe.yml recipe.yml
ADD organization-list.txt organization-list.txt
RUN chmod +x run.sh

CMD ["/usr/bin/supervisord", "-c", "/etc/supervisord.conf"]
