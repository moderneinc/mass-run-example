#!/bin/bash
set -e

# Start mod monitor in background (exposes metrics at :8080/prometheus)
echo "Starting mod monitor..."
java -jar /app/mod.jar monitor --port 8080 &
MOD_MONITOR_PID=$!

# Start Prometheus in background (scrapes mod monitor, serves at :9090)
echo "Starting Prometheus..."
/bin/prometheus --config.file=/etc/prometheus/prometheus.yml &
PROMETHEUS_PID=$!

# Start Grafana in background (dashboards at :3000)
echo "Starting Grafana..."
cd /usr/share/grafana && bin/grafana server \
    --homepath=/usr/share/grafana \
    --config=/etc/grafana/grafana.ini \
    --packaging=docker \
    cfg:default.log.mode=console \
    cfg:default.paths.data=/var/lib/grafana \
    cfg:default.paths.logs=/var/log/grafana \
    cfg:default.paths.plugins=/var/lib/grafana/plugins \
    cfg:default.paths.provisioning=/etc/grafana/provisioning &
GRAFANA_PID=$!

cd /app

# Give services time to start
sleep 2

echo "Monitoring services started:"
echo "  - mod monitor: http://localhost:8080/prometheus"
echo "  - Prometheus:  http://localhost:9090"
echo "  - Grafana:     http://localhost:3000"
echo ""

# Run the main script
exec /app/run.sh
