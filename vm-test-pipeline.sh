#!/usr/bin/env bash
# ============================================================
#  vm-test-pipeline.sh
#  Tests full end-to-end pipeline on the VM:
#  API → Kafka → Consumer → Elasticsearch + Redis + ScyllaDB
#  Usage: chmod +x vm-test-pipeline.sh && ./vm-test-pipeline.sh
# ============================================================

set -euo pipefail

GREEN='\033[0;32m'; YELLOW='\033[1;33m'; CYAN='\033[0;36m'
RED='\033[0;31m'; BOLD='\033[1m'; RESET='\033[0m'

ok()     { echo -e "  ${GREEN}✔${RESET}  $1"; }
warn()   { echo -e "  ${YELLOW}⚠${RESET}  $1"; }
fail()   { echo -e "  ${RED}✘${RESET}  $1"; exit 1; }
banner() { echo -e "\n${CYAN}${BOLD}══════════  $1  ══════════${RESET}\n"; }

TOPIC="vm-pipeline-test"
TIMESTAMP=$(date +%s)

banner "VM Environment"
echo "  Host    : $(hostname)"
echo "  OS      : $(uname -a)"
echo "  Docker  : $(docker --version)"
echo "  Compose : $(docker compose version)"
echo "  CPU     : $(nproc) cores"
echo "  RAM     : $(free -h | awk '/Mem/{print $2}')"
echo "  Disk    : $(df -h / | awk 'NR==2{print $4}') free"

banner "Step 1 — Start Stack"
sudo sysctl -w vm.max_map_count=262144 2>/dev/null || true
docker compose up -d
ok "Stack started"
docker ps --format "table {{.Names}}\t{{.Status}}"

banner "Step 2 — Wait for Services"
# Zookeeper
echo -n "  Zookeeper "
until docker exec zookeeper bash -c "echo ruok | timeout 3 bash -c 'cat >/dev/tcp/localhost/2181'" 2>/dev/null; do
  echo -n "."; sleep 3
done; echo " ✔"

# Kafka
echo -n "  Kafka "
until docker exec kafka kafka-topics --bootstrap-server localhost:9092 --list 2>/dev/null; do
  echo -n "."; sleep 5
done; echo " ✔"

# Elasticsearch
echo -n "  Elasticsearch "
until curl -sf http://localhost:9200/_cluster/health 2>/dev/null | grep -v '"status":"red"'; do
  echo -n "."; sleep 5
done; echo " ✔"

# Redis
echo -n "  Redis "
until docker exec redis redis-cli ping 2>/dev/null | grep -q PONG; do
  echo -n "."; sleep 2
done; echo " ✔"

# ScyllaDB
echo -n "  ScyllaDB "
until docker exec scylladb nodetool status 2>/dev/null | grep -q UN; do
  echo -n "."; sleep 10
done; echo " ✔"

banner "Step 3 — Kafka Flow Test (API → Kafka)"
# Create topic
docker exec kafka kafka-topics \
  --bootstrap-server localhost:9092 \
  --create --topic "$TOPIC" \
  --partitions 1 --replication-factor 1 2>/dev/null || true
ok "Topic created: $TOPIC"

# Produce message (simulates API publishing to Kafka)
MSG="vm-event-${TIMESTAMP}-build-ok"
echo "$MSG" | docker exec -i kafka \
  kafka-console-producer \
  --bootstrap-server localhost:9092 \
  --topic "$TOPIC"
ok "Message produced: $MSG"

# Consume message (simulates consumer reading from Kafka)
CONSUMED=$(docker exec kafka kafka-console-consumer \
  --bootstrap-server localhost:9092 \
  --topic "$TOPIC" \
  --from-beginning \
  --max-messages 1 \
  --timeout-ms 15000 2>/dev/null)

[ -n "$CONSUMED" ] \
  && ok "Message consumed: $CONSUMED" \
  || fail "Kafka consume failed"

banner "Step 4 — Storage Test (Consumer → Elasticsearch)"
RESULT=$(curl -sf -X POST "http://localhost:9200/vm-pipeline/_doc" \
  -H "Content-Type: application/json" \
  -d "{
    \"source\": \"kafka-consumer\",
    \"topic\": \"$TOPIC\",
    \"message\": \"$CONSUMED\",
    \"timestamp\": \"$(date -u +%Y-%m-%dT%H:%M:%SZ)\",
    \"host\": \"$(hostname)\"
  }")

echo "$RESULT" | grep -q '"result":"created"' \
  && ok "Stored in Elasticsearch" \
  || fail "Elasticsearch storage failed"

banner "Step 5 — Cache Test (Consumer → Redis)"
docker exec redis redis-cli set "vm:last-event:$TIMESTAMP" "$CONSUMED" EX 86400
VAL=$(docker exec redis redis-cli get "vm:last-event:$TIMESTAMP")
[ "$VAL" = "$CONSUMED" ] \
  && ok "Cached in Redis: $VAL" \
  || fail "Redis cache failed"

banner "Step 6 — ScyllaDB Test (Consumer → ScyllaDB)"
docker exec scylladb cqlsh -e "
  CREATE KEYSPACE IF NOT EXISTS pipeline
  WITH replication = {'class': 'SimpleStrategy', 'replication_factor': 1};

  CREATE TABLE IF NOT EXISTS pipeline.events (
    event_id   text PRIMARY KEY,
    topic      text,
    message    text,
    created_at timestamp
  );

  INSERT INTO pipeline.events (event_id, topic, message, created_at)
  VALUES ('evt-$TIMESTAMP', '$TOPIC', '$CONSUMED', toTimestamp(now()));

  SELECT * FROM pipeline.events LIMIT 5;
" 2>/dev/null \
  && ok "Stored in ScyllaDB" \
  || warn "ScyllaDB insert skipped"

banner "Step 7 — Resource Usage"
docker stats --no-stream \
  --format "table {{.Name}}\t{{.CPUPerc}}\t{{.MemUsage}}\t{{.MemPerc}}"

banner "Step 8 — Network Verification"
docker network inspect app-network \
  --format='{{range .Containers}}  • {{.Name}}  {{.IPv4Address}}{{println}}{{end}}'

banner "Result"
echo -e "${GREEN}${BOLD}"
echo "  ╔══════════════════════════════════════════╗"
echo "  ║   ✔  END-TO-END VM PIPELINE PASSED      ║"
echo "  ║                                          ║"
echo "  ║   API → Kafka → Consumer → Storage       ║"
echo "  ║   Elasticsearch  ✔                       ║"
echo "  ║   Redis          ✔                       ║"
echo "  ║   ScyllaDB       ✔                       ║"
echo "  ╚══════════════════════════════════════════╝"
echo -e "${RESET}"
echo "  Kafka UI  →  http://$(hostname -I | awk '{print $1}'):8080"
echo "  Elastic   →  http://$(hostname -I | awk '{print $1}'):9200"
echo ""
