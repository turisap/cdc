* partition by entity
* use version column
* idempotent consumer with version column, setting it to redis on the receiving side with TTL (max processed version)
  and other blows and whistles (SETNX processed:{topic}:{partition}:{offset},SETNX processed:{event_id} (TTL 1–6
  hours) )
* what to do with the debezium heartbeat topic debezium
* what to do with the debezium cdc.transaction topic

### flow:

receive event
│
├── parse before / after / op / transaction.id
│
├── derive namespace
│     snapshot_tx_id != NULL → "rs-" + snapshot_tx_id
│     snapshot_tx_id == NULL → GET snapshot:current
│
├── compute delta
│     op=d               → delta = -1 if before.status=active, else 0
│     op=c / op=r        → delta = +1 if after.status=active,  else 0
│     op=u, no role change→ delta from before→after status transition
│     op=u, role changed  → before role -1 (if was active), after role +1 (if now active)
│
├── if delta != 0:
│     run Lua script atomically:
│       version fence check (reject if stale)
│       HINCRBY counters:{ns}:{user_id}  active:{role}  {delta}
│
└── resnapshot watermark check
if snapshot_tx_id != NULL AND transaction.id starts with snapshot_tx_id:
SADD snapshot:tx:{snapshot_tx_id}:done {partition_id}
if SCARD == total_partitions:
SET snapshot:current "rs-{snapshot_tx_id}"

### Consumer

1. store previous state in the Debezium event itself
   Debezium's ExtractNewRecordState SMT can include the before-image:
   json"transforms.unwrap.add.fields": "before"
   Each event then carries both before and after state. Consumer computes the delta without needing to read from Redis
   first — no extra round trip, no row hashes needed in Redis at all.
2. @TODO before state