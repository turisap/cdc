BEGIN;

UPDATE user_items_projection
SET snapshot_tx_id = (SELECT pg_current_xact_id()::text),
    version        = version + 1,
    updated_at     = now()

-- only thing you need to note from output is rows_bumped (for monitoring)
SELECT pg_current_xact_id()::text AS bump_tx_id,
       count(*)                   AS rows_bumped
FROM user_items_projection
WHERE snapshot_tx_id = (SELECT pg_current_xact_id()::text);

COMMIT;