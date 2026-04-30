* partition by entity
* use version column
* idempotent consumer with version column, setting it to redis on the receiving side with TTL (max processed version)
  and other blows and whistles (SETNX processed:{topic}:{partition}:{offset},SETNX processed:{event_id} (TTL 1–6
  hours) )
* what to do with the debezium heartbeat topic debezium
* what to do with the debezium cdc.transaction topic

### resnapshotting:

avoid the barrier entirely using a tombstone key convention
Instead of a barrier message, embed the snapshot context into the key of every bump event. Your consumer detects it from
the event itself:
sql-- add a snapshot_id column to the projection table
ALTER TABLE user_items_projection ADD COLUMN snapshot_id TEXT;

-- when resnapshotting

```sql
UPDATE user_items_projection
SET version     = version + 1,
    updated_at  = now(),
    snapshot_id = 'rs-1';
```

The idea
Instead of two Redis DBs, every key is namespaced with the snapshot ID:
`p:{snapshot_id}:{user_id}:{work_item_id}:{role}`
Normal keys (no snapshot in progress):
`p:live:{user_id}:{work_item_id}:{role}`
During re-snapshot, bump events carry snapshot_id = 'rs-1', so the consumer writes to:
`p:rs-1:{user_id}:{work_item_id}:{role}`
Live events still write to p:live:.... No switching, no coordination, both namespaces coexist.
When snapshot is done, you do one atomic rename:
-- Lua script, atomic

```lua
local keys = redis.call('KEYS', 'p:rs-1:*')
for _, k in ipairs(keys) do
local newkey = k:gsub('^p:rs%-1:', 'p:live:')
redis.call('RENAME', k, newkey)
end
```

Which overwrites the live key with the snapshot value. Version fence ensures the higher version wins if a live event
already updated the key after the snapshot wrote it.

1. UPDATE projection SET snapshot_id='rs-1', version=version+1
   -- Debezium emits bump events with snapshot_id field

2. Consumer writes bump events to p:rs-1:... keys
   Live events continue writing to p:live:... keys (snapshot_id=NULL)

3. When consumer lag = 0 on all partitions:
   SET snapshot:current "rs-1"
   -- instant cutover, readers now use rs-1 namespace

4. Background job: SCAN + DEL p:live:* (old namespace, lazy cleanup)

5. Next re-snapshot uses snapshot_id='rs-2', cutover flips to rs-2, cleanup rs-1

### End of resnapshotting

event arrives
│
├── snapshot_tx_id = NULL
│ → live event
│ → namespace = GET snapshot:current
│ → write to p:<current>:...
│
└── snapshot_tx_id = "8675309"
→ bump event
→ namespace = "rs-8675309"   ← built directly from the tx_id, no lookup
→ write to p:rs-8675309:...
│
└── __transaction_id == snapshot_tx_id? ← watermark check
yes → vote this partition done
check if all partitions done
if yes → SET snapshot:current "rs-8675309"