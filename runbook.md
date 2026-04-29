-- @TODO fill it
-- =============================================================
-- RESNAPSHOT RUNBOOK
-- complete operational procedure, copy-pasteable
-- =============================================================


-- =============================================================
-- PHASE 0 — verify nothing is already in progress
-- =============================================================

-- should return NULL or the previous (completed) snapshot label
redis-cli GET snapshot:current

-- should return no rows
SELECT snapshot_tx_id, count(*)
FROM user_items_projection
WHERE snapshot_tx_id IS NOT NULL
GROUP BY snapshot_tx_id;


-- =============================================================
-- PHASE 1 — bump (postgres)
-- run in psql, note the output row
-- =============================================================

BEGIN;

\set bump_tx_id `psql -Atc "SELECT pg_current_xact_id()::text"`

UPDATE user_items_projection
SET
snapshot_tx_id = (SELECT pg_current_xact_id()::text),
version        = version + 1,
updated_at     = now()
WHERE
deleted_at IS NULL;

-- capture output — you need bump_tx_id and label for phase 2
SELECT
pg_current_xact_id()::text                          AS bump_tx_id,
concat('rs-', to_char(now(), 'YYYYMMDD-HH24MISS')) AS label,
count(*)                                            AS rows_bumped
FROM user_items_projection
WHERE snapshot_tx_id = (SELECT pg_current_xact_id()::text);

COMMIT;

-- example output:
--   bump_tx_id  | label                  | rows_bumped
--   ------------+------------------------+-------------
--   8675309     | rs-20260428-143022     | 142857


-- =============================================================
-- PHASE 2 — register in redis (immediately after phase 1)
-- substitute values from phase 1 output
-- =============================================================

redis-cli SET "snapshot:tx:8675309:id"          "rs-20260428-143022"
redis-cli SET "snapshot:tx:8675309:total_parts" "12"   -- your kafka partition count

-- at this point consumers will:
--   bump events (snapshot_tx_id=8675309) → write to p:rs-20260428-143022:...
--   live events (snapshot_tx_id=NULL)    → write to p:<current>:...  (old namespace)
-- both namespaces coexist, version fence handles any overlap


-- =============================================================
-- PHASE 3 — monitor progress (poll until all partitions done)
-- =============================================================

-- how many partitions have crossed the watermark
redis-cli SCARD "snapshot:tx:8675309:done_parts"

-- which ones specifically
redis-cli SMEMBERS "snapshot:tx:8675309:done_parts"

-- how many rows still have snapshot_tx_id set (draining)
SELECT count(*)
FROM user_items_projection
WHERE snapshot_tx_id = '8675309';

-- consumer lag per partition (run in your kafka tooling)
-- kafka-consumer-groups.sh --describe --group <your-consumer-group>


-- =============================================================
-- PHASE 4 — flip (redis)
-- only after SCARD done_parts == total_parts
-- consumers do this automatically via vote_and_flip lua script
-- but you can force it manually if needed
-- =============================================================

-- verify all partitions voted
redis-cli SCARD "snapshot:tx:8675309:done_parts"   -- must equal total_parts

-- flip (consumers do this — manual override only)
redis-cli SET snapshot:current "rs-20260428-143022"

-- from this moment:
--   live events (snapshot_tx_id=NULL) → p:rs-20260428-143022:...
--   old namespace p:<previous>:* is orphaned, safe to delete


-- =============================================================
-- PHASE 5 — cleanup redis (background, non-urgent)
-- =============================================================

-- delete old namespace keys in batches (non-blocking)
-- replace "live" with whatever snapshot:current was before the flip
redis-cli --scan --pattern "p:live:*" | xargs -L 100 redis-cli DEL

-- delete coordination keys
redis-cli DEL "snapshot:tx:8675309:id"
redis-cli DEL "snapshot:tx:8675309:total_parts"
redis-cli DEL "snapshot:tx:8675309:done_parts"


-- =============================================================
-- PHASE 6 — cleanup postgres (after redis cleanup settles)
-- =============================================================

BEGIN;

UPDATE user_items_projection
SET
snapshot_tx_id = NULL,
version        = version + 1,
updated_at     = now()
WHERE
snapshot_tx_id = '8675309';

-- verify
SELECT count(*) AS still_stamped
FROM user_items_projection
WHERE snapshot_tx_id IS NOT NULL;   -- must be 0

COMMIT;

-- these cleanup rows flow through debezium as live events
-- (snapshot_tx_id=NULL) and land in p:rs-20260428-143022:...
-- which is now the live namespace — correct


-- =============================================================
-- PHASE 7 — verify
-- =============================================================

-- redis: spot check a few projection keys in new namespace
redis-cli HGETALL "p:rs-20260428-143022:<user_id>:<item_id>:owner"

-- postgres: no rows should have snapshot_tx_id set
SELECT count(*) FROM user_items_projection WHERE snapshot_tx_id IS NOT NULL;

-- redis: current namespace should be the new label
redis-cli GET snapshot:current   -- rs-20260428-143022

-- redis: no old namespace keys should remain
redis-cli --scan --pattern "p:live:*" | wc -l   -- 0


-- =============================================================
-- ABORT PROCEDURE (if anything goes wrong before phase 4 flip)
-- =============================================================

-- 1. reset postgres rows — removes snapshot_tx_id without bumping
--    consumers will continue writing live events to old namespace
BEGIN;
UPDATE user_items_projection
SET    snapshot_tx_id = NULL,
updated_at     = now()
WHERE  snapshot_tx_id = '8675309';
COMMIT;

-- 2. delete redis coordination keys
redis-cli DEL "snapshot:tx:8675309:id"
redis-cli DEL "snapshot:tx:8675309:total_parts"
redis-cli DEL "snapshot:tx:8675309:done_parts"

-- 3. delete any partial snapshot namespace keys that were written
redis-cli --scan --pattern "p:rs-20260428-143022:*" | xargs -L 100 redis-cli DEL

-- system is back to normal — snapshot:current unchanged, old namespace still live
-- note: version was incremented during the bump even on abort
-- that is fine — version only moves forward, consumers handle it correctly