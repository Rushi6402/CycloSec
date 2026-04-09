from fastapi import FastAPI
from elasticsearch import Elasticsearch
from kafka import KafkaProducer
from cassandra.cluster import Cluster
import json, uuid
from datetime import datetime
import logging

logging.basicConfig(level=logging.INFO)
logger = logging.getLogger(__name__)

app = FastAPI(title="CycloSec API")

# ── Elasticsearch ─────────────────────────────────────────
es = Elasticsearch("http://elasticsearch:9200")

# ── ScyllaDB ──────────────────────────────────────────────
scylla = Cluster(["scylladb"]).connect()

app = FastAPI(title="CycloSec API")

# ── Connections ───────────────────────────────────────────
es     = Elasticsearch("http://elasticsearch:9200")
kafka  = KafkaProducer(
            bootstrap_servers="kafka:29092",
            value_serializer=lambda v: json.dumps(v).encode()
         )
scylla = Cluster(["scylladb"]).connect()

# Create keyspace + table on startup

scylla.execute("""
    CREATE KEYSPACE IF NOT EXISTS cyclosec
    WITH replication = {'class':'SimpleStrategy','replication_factor':1}
""")
scylla.set_keyspace("cyclosec")
scylla.execute("""
    CREATE TABLE IF NOT EXISTS events (
        id UUID PRIMARY KEY,
        type TEXT,
        data TEXT,
        created_at TIMESTAMP
    )
""")

# ── Kafka — lazy connection (reconnects if dropped) ───────
_kafka_producer = None

def get_kafka():
    global _kafka_producer
    try:
        # test if existing producer still works
        if _kafka_producer and _kafka_producer.bootstrap_connected():
            return _kafka_producer
    except Exception:
        pass
    # reconnect
    logger.info("Connecting to Kafka...")
    _kafka_producer = KafkaProducer(
        bootstrap_servers="kafka:29092",
        value_serializer=lambda v: json.dumps(v).encode(),
        request_timeout_ms=10000,
        retries=3,
    )
    return _kafka_producer

# ── Routes ────────────────────────────────────────────────

@app.get("/")
def root():
    return {"status": "running", "docs": "/docs"}


@app.get("/health")
def health():
    # Kafka
    try:
        k = get_kafka()
        kafka_status = "ok" if k.bootstrap_connected() else "error"
    except Exception as e:
        kafka_status = f"error: {str(e)}"

    # Elasticsearch
    try:
        es_status = "ok" if es.ping() else "error"
    except Exception as e:
        es_status = f"error: {str(e)}"

    # ScyllaDB
    try:
        scylla.execute("SELECT now() FROM system.local")
        scylla_status = "ok"
    except Exception as e:
        scylla_status = f"error: {str(e)}"

    return {
        "kafka":         kafka_status,
        "elasticsearch": es_status,
        "scylladb":      scylla_status,
    }
    return {
        "kafka":         "ok" if kafka.bootstrap_connected() else "error",
        "elasticsearch": "ok" if es.ping() else "error",
        "scylladb":      "ok"
    }


@app.post("/event")
def create_event(type: str, data: str):
    event_id = uuid.uuid4()
    now      = datetime.utcnow()

    results = {"id": str(event_id), "type": type,
               "data": data, "created_at": str(now)}

    # → Kafka
    try:
        producer = get_kafka()
        producer.send("events", {"id": str(event_id), "type": type, "data": data})
        producer.flush()
        results["kafka"] = "sent"
    except Exception as e:
        results["kafka"] = f"error: {str(e)}"

    # → ScyllaDB
    try:
        scylla.execute(
            "INSERT INTO events (id, type, data, created_at) VALUES (%s,%s,%s,%s)",
            (event_id, type, data, now)
        )
        results["scylladb"] = "stored"
    except Exception as e:
        results["scylladb"] = f"error: {str(e)}"

    # → Elasticsearch
    try:
        es.index(index="events", id=str(event_id),
                 document={"type": type, "data": data,
                            "created_at": now.isoformat()})
        results["elasticsearch"] = "indexed"
    except Exception as e:
        results["elasticsearch"] = f"error: {str(e)}"

    return results
    # → Kafka
    kafka.send("events", {"id": str(event_id), "type": type, "data": data})
    kafka.flush()

    # → ScyllaDB
    scylla.execute(
        "INSERT INTO events (id, type, data, created_at) VALUES (%s,%s,%s,%s)",
        (event_id, type, data, now)
    )

    # → Elasticsearch
    es.index(index="events", id=str(event_id),
             document={"type": type, "data": data, "created_at": now.isoformat()})

    return {"id": str(event_id), "type": type, "data": data, "created_at": str(now)}



@app.get("/events")
def get_events():

    rows = scylla.execute(
        "SELECT id, type, data, created_at FROM events LIMIT 20"
    )
    return {
        "events": [
            {"id": str(r.id), "type": r.type,
             "data": r.data, "created_at": str(r.created_at)}
            for r in rows
        ]
    }
    rows = scylla.execute("SELECT id, type, data, created_at FROM events LIMIT 20")
    return {"events": [{"id": str(r.id), "type": r.type,
                        "data": r.data, "created_at": str(r.created_at)} for r in rows]}


@app.get("/search")
def search(q: str):

    result = es.search(
        index="events",
        body={"query": {"multi_match": {"query": q, "fields": ["type", "data"]}}}
    )
    hits = result["hits"]["hits"]
    return {"query": q, "total": len(hits),
            "results": [h["_source"] for h in hits]}
    result = es.search(index="events",
                       body={"query": {"multi_match": {"query": q, "fields": ["type","data"]}}})
    hits = result["hits"]["hits"]
    return {"query": q, "results": [h["_source"] for h in hits]}
