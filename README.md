# Version Fencing, Resnapshot & Voting

## Normal Flow

Two Redis hashes per user — one for versions, one for counters:

```
versions:live:user-A   →  { "item-1:owner": 3,  "item-2:executor": 1 }
counters:live:user-A   →  { "active:owner": 1,   "active:executor": 1 }
```

Event arrives: `user-A, item-1, owner, version=4, status=completed`

Lua script runs atomically:

```
cur = HGET versions:live:user-A  "item-1:owner"   → 3
3 >= 4?  NO → proceed
HSET    versions:live:user-A  "item-1:owner"  4
HINCRBY counters:live:user-A  "active:owner"  -1   ← was active, now completed
```

After:

```
versions:live:user-A   →  { "item-1:owner": 4,  "item-2:executor": 1 }
counters:live:user-A   →  { "active:owner": 0,   "active:executor": 1 }
```

Consumer restarts, same event replayed:

```
cur = HGET versions:live:user-A  "item-1:owner"   → 4
4 >= 4?  YES → reject
```

Counter stays at `0`. Correct.

---

## Resnapshot Flow

Something poisoned Redis — `counters:live:user-A active:owner = 5` but the truth is `2`.

You run the bump SQL. Every projection row gets `snapshot_tx_id = tx789` and `version = version + 1`.
Debezium emits bump events. Consumer sees `snapshot_tx_id = tx789`, derives namespace `rs-tx789`, and writes to a
completely separate set of keys:

```
versions:rs-tx789:user-A  →  {}   ← starts empty
counters:rs-tx789:user-A  →  {}   ← starts empty
```

Bump event arrives: `user-A, item-1, owner, version=5, snapshot_tx_id=tx789, status=active`

```
namespace = "rs-tx789"
cur = HGET versions:rs-tx789:user-A  "item-1:owner"  → nil → -1
-1 >= 5?  NO → proceed
HSET    versions:rs-tx789:user-A  "item-1:owner"  5
HINCRBY counters:rs-tx789:user-A  "active:owner"  +1
```

Meanwhile live events (`snapshot_tx_id = NULL`) keep going to the current namespace:

```
namespace = GET snapshot:current → "live"
counters:live:user-A             ← poisoned, still serving reads during snapshot
```

This continues until all partitions vote ready. Then `snapshot:current` flips to `rs-tx789`.
From that moment live events write to `rs-tx789` and the poisoned `live` namespace is abandoned and cleaned up.

---

## Voting — How the Consumer Knows the Snapshot Is Done

Each partition independently detects when its bump events are fully processed.
The signal is `transaction.id`.

The bump SQL ran as one Postgres transaction — `tx789`. Every bump event carries
`transaction.id = "tx789:some_lsn"`. The consumer extracts the Postgres tx id part (`tx789`)
and compares it to `snapshot_tx_id` in the event.

Within one partition events are strictly ordered. Once the consumer sees any event whose
transaction started after `tx789`, all of `tx789`'s events have been delivered to that partition.
That is the watermark crossing.

Partition 3 sees:

```
offset 100: tx789  snapshot_tx_id=tx789  item-5   ← bump event
offset 101: tx789  snapshot_tx_id=tx789  item-9   ← bump event
offset 102: tx801  snapshot_tx_id=NULL   item-3   ← live event → tx789 done on P3
```

When offset 102 arrives, partition 3 votes:

```lua
SADD  snapshot:tx789:done  3      -- partition 3 votes
done  = SCARD snapshot:tx789:done -- how many voted so far
total = 5                         -- total partitions (from config)

done < total?  YES → return ""    -- not all partitions done yet
```

When the last partition votes:

```lua
SADD  snapshot:tx789:done  7      -- partition 7, the last one
done  = SCARD snapshot:tx789:done -- 5
5 >= 5?  YES → SET snapshot:current "rs-tx789"
              → return "rs-tx789"
```

The consumer that ran the last vote sees the non-empty return value, logs the flip,
and kicks off background cleanup of `snapshot:tx789:done` and the old `live` namespace keys.

---

## The Three Guarantees

**Idempotency** — replaying any event at any version never corrupts counters
because `>=` rejects anything already applied, including an exact version match.

**Resnapshot safety** — poisoned state is abandoned in a separate namespace,
never overwritten in place. The new namespace builds from scratch regardless
of what the old one contained.

**Ordering** — within a partition Kafka guarantees events arrive in WAL order.
The version fence is a backstop for replays, not the primary ordering mechanism.
The primary mechanism is Kafka itself.

## BFF and multi-service counters

```
service A (autoitems)     service B (manual items)    service C (future)
   own Postgres DB            own Postgres DB              own Postgres DB
   own Debezium               own Debezium                 own Debezium
   own Kafka topic            own Kafka topic              own Kafka topic
   own consumer               own consumer                 own consumer
   own Redis counters         own Redis counters            own Redis counters
        ↓                          ↓                             ↓
                          BFF / API gateway
                    merges counters at request time
         
work_item + work_assignment
    → triggers
    → user_items_projection
    → Debezium
    → Kafka
    → consumer
    → Redis counters:{service}:{ns}:{user}
```