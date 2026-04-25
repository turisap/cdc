* partition by entity
* use version column
* idempotent consumer with version column, setting it to redis on the receiving side with TTL (max processed version)
  and other blows and whistles (SETNX processed:{topic}:{partition}:{offset},SETNX processed:{event_id} (TTL 1–6
  hours) )
* what to do with the debezium heartbeat topic debezium
* what to do with the debezium cdc.transaction topic

### resnapshotting:

* Step 1 — send SNAPSHOT_START to the control topic
  This is a separate single-partition Kafka topic you own, not the CDC topic. Every consumer instance subscribes to it
  independently of its main partition assignment.
  json{ "type": "SNAPSHOT_START", "snapshot_id": "rs-20260424-1", "ts": 1745000000 }
  When a consumer reads this, it switches its Redis write target from DB0 → DB1. Live events (op=c/u/d) keep arriving
  and go to DB1. DB0 continues serving reads — zero downtime.
* Step 2 — bump versions and let WAL do the work
  sqlBEGIN;

```sql
UPDATE user_items_projection
SET version    = version + 1,
    updated_at = now()
WHERE deleted_at IS NULL; -- only rows you want re-emitted
COMMIT;
```

This single transaction generates N WAL records (one per row), each flows through Debezium as op=u, lands in Kafka on
the correct partition (because Debezium uses your message.key.columns), and the consumer writes them to DB1 with the
version fence. A replayed v7 that's already in DB1 as v8 gets rejected. A row that was at v7 in Redis (DB0) and arrives
as v8 gets applied.
The transaction boundary matters here — all the bumps appear as one Postgres transaction in the WAL, but Debezium still
emits them as individual row events. They're not atomic in Kafka, which is fine because each row is independent.

* Step 3 — send SNAPSHOT_DONE
  After the UPDATE commits and Debezium has had time to flush (you can wait for the WAL LSN to advance past your
  transaction, or just wait a few seconds conservatively):
  `json{ "type": "SNAPSHOT_DONE", "snapshot_id": "rs-20260424-1", "ts": 1745000010 }`
  Each consumer instance, on receiving this, starts polling its own consumer lag. When lag hits zero on all assigned
  partitions, it marks itself ready.
* Step 4 — coordinate the swap
  With multiple consumer instances you need all of them ready before swapping. Simple approach using Redis itself:

```lua-- each consumer runs this when lag = 0
local count = redis.call('INCR', 'snapshot:ready:rs-20260424-1')
redis.call('EXPIRE', 'snapshot:ready:rs-20260424-1', 3600)
if tonumber(count) >= tonumber(ARGV[1]) then   -- ARGV[1] = total instances
redis.call('SWAPDB', 0, 1)
return 1   -- this instance does the swap
end
return 0   -- waiting
```

SWAPDB 0 1 is atomic and instant at the Redis level — no reader sees a partial state. DB0 becomes the new shadow, DB1
becomes live.

* Step 5 — switch writes back to DB0, flush old DB
  All consumers switch write target back to DB0 (which is now the fresh shadow). Then FLUSHDB on what is now DB1 (the
  old live data) to prepare it for the next re-snapshot cycle. Your system is back to normal.

The one subtle problem: consumer starts up mid-snapshot
Your control topic must be replayable from the beginning — set retention.ms = -1 (infinite) or at least long enough that
a crashed consumer can restart, seek to offset 0 on the control topic, replay SNAPSHOT_START / SNAPSHOT_DONE, and
reconstruct whether it should be in shadow mode or not. Without this a restarted consumer misses the SNAPSHOT_START,
writes to DB0, and corrupts the shadow DB with stale data.
On startup, every consumer should:

Seek control topic to offset 0, read all messages
Find the latest SNAPSHOT_START / SNAPSHOT_DONE pair
If SNAPSHOT_START exists with no matching SNAPSHOT_DONE → snapshot in progress, write to DB1
If both exist → snapshot complete, write to DB0
Then resume normal partition consumption from committed offsets

What you don't need

Debezium signals — your UPDATE generates real WAL events
A separate snapshot connector — same connector, same slot, no disruption
Any Debezium configuration changes — this is entirely driven from your side
Pausing the consumer — it runs continuously throughout, version fence handles everything

The whole thing is operationally just: write one Kafka message, run one SQL UPDATE, write another Kafka message, wait
for lag, SWAPDB. Everything else is handled by mechanisms already in your system.