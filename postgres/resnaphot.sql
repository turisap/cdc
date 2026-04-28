-- embed transaction id into the projection to be able to detect re-snapshotting
BEGIN;
UPDATE user_items_projection
SET snapshot_tx_id = (SELECT pg_current_xact_id() ::text),
    version        = version + 1,
    updated_at     = now()
WHERE deleted_at IS NULL; -- or any other filter
COMMIT;