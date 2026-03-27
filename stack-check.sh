#!/usr/bin/env bash
# ============================================================
#  stack-check.sh  –  Validate & monitor your full Docker stack
#  Usage:  chmod +x stack-check.sh && ./stack-check.sh
# ============================================================

set -euo pipefail

RED='\033[0;31m'; GREEN='\033[0;32m'; YELLOW='\033[1;33m'
CYAN='\033[0;36m'; BOLD='\033[1m'; RESET='\033[0m'

SERVICES=(zookeeper kafka kafka-ui elasticsearch scylladb redis)

banner() { echo -e "\n${CYAN}${BOLD}══════════  $1  ══════════${RESET}\n"; }
ok()     { echo -e "  ${GREEN}✔${RESET}  $1"; }
warn()   { echo -e "  ${YELLOW}⚠${RESET}  $1"; }
fail()   { echo -e "  ${RED}✘${RESET}  $1"; }

# ── 1. Start the stack ────────────────────────────────────────
banner "Starting Stack"
docker compose up -d
echo ""

# ── 2. Wait for containers to settle ─────────────────────────
banner "Waiting 15s for services to initialise…"
sleep 15

# ── 3. Container status ───────────────────────────────────────
banner "Container Status"
docker ps --format "table {{.Names}}\t{{.Status}}\t{{.Ports}}"

# ── 4. Health checks ─────────────────────────────────────────
banner "Health Checks"
ALL_OK=true
for svc in "${SERVICES[@]}"; do
  state=$(docker inspect --format='{{.State.Status}}' "$svc" 2>/dev/null || echo "missing")
  health=$(docker inspect --format='{{if .State.Health}}{{.State.Health.Status}}{{else}}no-healthcheck{{end}}' "$svc" 2>/dev/null || echo "missing")

  if [[ "$state" == "running" ]]; then
    ok "$svc  →  state=$state  health=$health"
  else
    fail "$svc  →  state=$state  health=$health"
    ALL_OK=false
  fi
done

# ── 5. Network membership ─────────────────────────────────────
banner "Network: app-network"
docker network inspect app-network \
  --format='{{range .Containers}}  • {{.Name}}{{println}}{{end}}' 2>/dev/null \
  || warn "Network app-network not found yet"

# ── 6. Connectivity probes ────────────────────────────────────
banner "Service Connectivity"

# Kafka (from host)
if docker exec kafka kafka-broker-api-versions \
     --bootstrap-server localhost:9092 &>/dev/null; then
  ok "Kafka broker reachable on localhost:9092"
else
  warn "Kafka not yet responding (may still be starting)"
fi

# Elasticsearch
if curl -sf http://localhost:9200/_cluster/health &>/dev/null; then
  status=$(curl -sf http://localhost:9200/_cluster/health | python3 -c "import sys,json; print(json.load(sys.stdin)['status'])" 2>/dev/null || echo "unknown")
  ok "Elasticsearch healthy  →  cluster status: $status"
else
  warn "Elasticsearch not yet responding"
fi

# Redis
if docker exec redis redis-cli ping 2>/dev/null | grep -q PONG; then
  ok "Redis responding to PING"
else
  warn "Redis not yet responding"
fi

# ScyllaDB
if docker exec scylladb cqlsh -e "describe cluster" &>/dev/null; then
  ok "ScyllaDB CQL port reachable"
else
  warn "ScyllaDB not yet ready (it takes ~60 s on first start)"
fi

# ── 7. Resource usage ─────────────────────────────────────────
banner "Resource Usage"
docker stats --no-stream --format \
  "table {{.Name}}\t{{.CPUPerc}}\t{{.MemUsage}}\t{{.MemPerc}}" \
  "${SERVICES[@]}" 2>/dev/null || true

# ── 8. Final verdict ──────────────────────────────────────────
banner "Result"
if $ALL_OK; then
  echo -e "${GREEN}${BOLD}All containers are running.  Stack looks healthy!${RESET}"
  echo ""
  echo -e "  Kafka UI  →  http://localhost:8080"
  echo -e "  Elastic   →  http://localhost:9200"
  echo -e "  Redis     →  localhost:6379"
  echo -e "  ScyllaDB  →  localhost:9042  (cqlsh)"
  echo -e "  Kafka     →  localhost:9092  (external)"
  echo -e "              kafka:29092      (internal/container)"
else
  echo -e "${RED}${BOLD}One or more containers failed.  Check logs:${RESET}"
  for svc in "${SERVICES[@]}"; do
    state=$(docker inspect --format='{{.State.Status}}' "$svc" 2>/dev/null || echo "missing")
    [[ "$state" != "running" ]] && echo "  docker logs $svc"
  done
fi
echo ""
