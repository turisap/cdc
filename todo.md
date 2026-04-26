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
When your UPDATE commits, Postgres assigns it a Log Sequence Number (LSN). That LSN is the exact position in the WAL after which no more bump events exist. Debezium includes the source LSN in every event via your existing add.fields config (__source.lsn).
So the flow becomes:
1. run UPDATE, capture the commit LSN
2. consumer tracks: have I seen an event with __source.lsn >= commit_lsn on every partition?
3. when yes on all partitions → snapshot complete → flip snapshot:current
   Step 1 — capture the commit LSN
   sqlBEGIN;
   UPDATE user_items_projection
   SET    snapshot_id = 'rs-1',
   version     = version + 1,
   updated_at  = now();

-- capture LSN at commit time
SELECT pg_current_wal_lsn() AS commit_lsn;
COMMIT;
Store that LSN somewhere your consumers can read it — simplest is Redis itself:
SET snapshot:rs-1:commit_lsn "0/3A7F210"
Step 2 — consumer watches for the watermark
Every event from Debezium carries __source.lsn. Your consumer compares it against the stored commit LSN per partition:
pythondef handle_event(event, partition):
source_lsn = event.get('__source_lsn')
current_snapshot = redis.get('snapshot:current')          # e.g. "live"
pending_snapshot = redis.get('snapshot:pending')          # e.g. "rs-1"

    if pending_snapshot:
        commit_lsn = redis.get(f'snapshot:{pending_snapshot}:commit_lsn')
        
        # write to correct namespace
        snapshot_id = event.get('snapshot_id') or 'live'
        write_to_redis(event, namespace=snapshot_id)
        
        # check watermark
        if lsn_gte(source_lsn, commit_lsn):
            mark_partition_done(pending_snapshot, partition)
            check_and_flip(pending_snapshot)
    else:
        write_to_redis(event, namespace='live')

def check_and_flip(snapshot_id):
total = get_total_partition_count()
done  = redis.incr(f'snapshot:{snapshot_id}:partitions_done')
if done >= total:
redis.set('snapshot:current', snapshot_id)
# background cleanup of old namespace
Each partition independently marks itself done when it sees an event past the LSN watermark. The last partition to cross the watermark triggers the flip.
