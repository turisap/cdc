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

What you actually want is already there
You're trying to avoid the LSN watermark because it feels like extra complexity. But look at what you already have in
every Debezium event from your existing config:
json"transforms.unwrap.add.fields": "op,ts_ms,transaction.id,transaction.total_order,
transaction.data_collection_order,source.table,
source.db,source.ts_ms"
You're already capturing transaction.id. The bump UPDATE is one transaction — it has one transaction.id. That
transaction ID is on every single bump event across every partition.
So the signal is just:
seen transaction.id = bump_tx_id on this partition? → partition done
all partitions done? → flip
Store the bump transaction ID in Redis when you start:
sqlBEGIN;
UPDATE cdc_config SET value = 'rs-1' WHERE key = 'current_snapshot_id';
UPDATE user_items_projection SET snapshot_id = 'rs-1', version = version + 1, updated_at = now();
SELECT txid_current(); -- capture this, store in Redis as snapshot:rs-1:tx_id
COMMIT;
Consumer logic becomes:
pythonbump_tx_id = redis.get('snapshot:rs-1:tx_id')

if event['__transaction_id'] == bump_tx_id:
mark_partition_done(partition)
check_and_flip()
No LSN parsing, no watermark comparison, no separate heartbeat. The transaction ID is an exact, unambiguous marker that
is already in your events. When every partition has seen at least one event from that transaction, every bump row has
been processed, and the flip is safe.

After the flip you set snapshot:current = rs-1. Your application now reads from p:rs-1:.... But new live events keep
writing to p:live:.... You're back to the same problem as before — the application reads a namespace nobody is writing
to.
You can't avoid this. After the flip, live events must write to the new namespace. The consumer needs to know which
namespace is currently live, and it gets that from snapshot:current in Redis: