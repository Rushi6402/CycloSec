#!/usr/bin/env bash
# ============================================================
#  monitor.sh — Full stack monitoring
#  Usage: chmod +x monitor.sh && ./monitor.sh
#  Live mode: watch -n 5 ./monitor.sh
# ============================================================

RED='\033[0;31m'; GREEN='\033[0;32m'; YELLOW='\033[1;33m'
CYAN='\033[0;36m'; BOLD='\033[1m'; RESET='\033[0m'

SERVICES=(zookeeper kafka kafka-ui elasticsearch scylladb redis)

banner() { echo -e "\n${CYAN}${BOLD}══════════  $1  ══════════${RESET}\n"; }
ok()     { echo -e "  ${GREEN}✔${RESET}  $1"; }
warn()   { echo -e "  ${YELLOW}⚠${RESET}  $1"; }
fail()   { echo -e "  ${RED}✘${RESET}  $1"; }

echo -e "${BOLD}$(date '+%Y-%m-%d %H:%M:%S')${RESET}"

# ── 1. Container Status ───────────────────────────────────────
banner "Container Status"
docker ps --format "table {{.Names}}\t{{.Status}}\t{{.RunningFor}}" 2>/dev/null

# ── 2. Health Status ─────────────────────────────────────────
banner "Health Checks"
for svc in "${SERVICES[@]}"; do
  state=$(docker inspect --format='{{.State.Status}}' "$svc" 2>/dev/null || echo "missing")
  health=$(docker inspect --format='{{if .State.Health}}{{.State.Health.Status}}{{else}}no-healthcheck{{end}}' "$svc" 2>/dev/null || echo "missing")
  restarts=$(docker inspect --format='{{.RestartCount}}' "$svc" 2>/dev/null || echo "?")

  if [[ "$state" == "running" && ("$health" == "healthy" || "$health" == "no-healthcheck") ]]; then
    ok "$svc  →  $health  (restarts: $restarts)"
  elif [[ "$state" == "running" && "$health" == "starting" ]]; then
    warn "$svc  →  starting...  (restarts: $restarts)"
  else
    fail "$svc  →  state=$state  health=$health  (restarts: $restarts)"
  fi
done

# ── 3. Resource Usage ─────────────────────────────────────────
banner "Resource Usage (CPU / Memory)"
docker stats --no-stream --format \
  "table {{.Name}}\t{{.CPUPerc}}\t{{.MemUsage}}\t{{.MemPerc}}\t{{.NetIO}}" \
  "${SERVICES[@]}" 2>/dev/null || true

# ── 4. Kafka Flow ─────────────────────────────────────────────
banner "Kafka — Topics & Consumer Groups"

echo -e "  ${BOLD}Topics:${RESET}"
docker exec kafka kafka-topics \
  --bootstrap-server localhost:9092 \
  --list 2>/dev/null \
  | sed 's/^/    /' \
  || warn "Kafka not reachable"

echo ""
echo -e "  ${BOLD}Consumer Groups:${RESET}"
docker exec kafka kafka-consumer-groups \
  --bootstrap-server localhost:9092 \
  --list 2>/dev/null \
  | sed 's/^/    /' \
  || warn "No consumer groups found"

# ── 5. Kafka Consumer Lag ─────────────────────────────────────
banner "Kafka — Consumer Lag"
GROUPS=$(docker exec kafka kafka-consumer-groups \
  --bootstrap-server localhost:9092 \
  --list 2>/dev/null || echo "")

if [[ -z "$GROUPS" ]]; then
  warn "No consumer groups to check"
else
  for group in $GROUPS; do
    echo -e "  ${BOLD}Group: $group${RESET}"
    docker exec kafka kafka-consumer-groups \
      --bootstrap-server localhost:9092 \
      --describe --group "$group" 2>/dev/null \
      | sed 's/^/    /' || true
  done
fi

# ── 6. Elasticsearch Health ───────────────────────────────────
banner "Elasticsearch — Cluster Health"
curl -sf http://localhost:9200/_cluster/health?pretty 2>/dev/null \
  | grep -E '"status"|"number_of_nodes"|"active_shards"|"unassigned_shards"' \
  | sed 's/^/  /' \
  || warn "Elasticsearch not reachable"

echo ""
echo -e "  ${BOLD}Indices:${RESET}"
curl -sf "http://localhost:9200/_cat/indices?v&h=index,health,status,docs.count,store.size" 2>/dev/null \
  | sed 's/^/    /' \
  || warn "No indices found"

# ── 7. ScyllaDB Status ────────────────────────────────────────
banner "ScyllaDB — Node Status"
docker exec scylladb nodetool status 2>/dev/null \
  | sed 's/^/  /' \
  || warn "ScyllaDB not reachable"

# ── 8. Redis Stats ────────────────────────────────────────────
banner "Redis — Stats"
docker exec redis redis-cli info server 2>/dev/null \
  | grep -E "redis_version|uptime_in_seconds|connected_clients|used_memory_human|maxmemory_human" \
  | sed 's/^/  /' \
  || warn "Redis not reachable"

echo ""
docker exec redis redis-cli info stats 2>/dev/null \
  | grep -E "total_commands_processed|total_connections_received|keyspace_hits|keyspace_misses" \
  | sed 's/^/  /' || true

# ── 9. Volume Usage ───────────────────────────────────────────
banner "Volume Disk Usage"
docker system df -v 2>/dev/null \
  | grep -A 100 "Local Volumes" \
  | grep -E "VOLUME NAME|_data|kafka_|zookeeper_|redis_|elastic|scylla" \
  | sed 's/^/  /' || true

# ── 10. Network ───────────────────────────────────────────────
banner "Network: app-network"
docker network inspect app-network \
  --format='{{range .Containers}}  • {{.Name}}  ({{.IPv4Address}}){{println}}{{end}}' \
  2>/dev/null || warn "app-network not found"

echo ""
