-- @TODO go to the consumer-side
CREATE
EXTENSION IF NOT EXISTS "uuid-ossp";

CREATE TYPE service_id AS ENUM ('auto', 'web', 'mobile', 'api');

CREATE
OR REPLACE FUNCTION random_service_id()
    RETURNS service_id
    LANGUAGE sql
AS
$$
SELECT (ARRAY['auto', 'web', 'mobile', 'api'])[floor(random() * 2 + 1)::int]::service_id;
$$;

-- =========================
-- CORE DOMAIN TABLES
-- =========================

CREATE TABLE work_item
(
    id         UUID PRIMARY KEY     DEFAULT uuid_generate_v4(),
    title      TEXT        NOT NULL,
    status     TEXT        NOT NULL CHECK (status IN ('active', 'completed', 'expired')),
    due_at     TIMESTAMPTZ,
    created_at TIMESTAMPTZ NOT NULL DEFAULT now(),
    updated_at TIMESTAMPTZ NOT NULL DEFAULT now(),
    deleted_at TIMESTAMPTZ
);

CREATE TABLE work_assignment
(
    id           UUID PRIMARY KEY     DEFAULT uuid_generate_v4(),
    work_item_id UUID        NOT NULL REFERENCES work_item (id),
    user_id      UUID        NOT NULL,
    role         TEXT        NOT NULL CHECK (role IN ('owner', 'executor', 'watcher', 'reviewer')),
    created_at   TIMESTAMPTZ NOT NULL DEFAULT now(),
    deleted_at   TIMESTAMPTZ
);

CREATE TABLE user_profile
(
    user_id  UUID PRIMARY KEY DEFAULT uuid_generate_v4(),
    timezone TEXT NOT NULL
);

-- =========================================================
-- PROJECTION TABLE (THIS IS WHAT CDC WILL READ)
-- =========================================================

CREATE TABLE user_items_projection
(
    user_id        UUID        NOT NULL,
    work_item_id   UUID        NOT NULL,
    role           TEXT        NOT NULL,
    status         TEXT        NOT NULL,
    due_at         TIMESTAMPTZ,
    created_at     TIMESTAMPTZ NOT NULL,
    updated_at     TIMESTAMPTZ NOT NULL DEFAULT now(),
    version        BIGINT      NOT NULL,
    snapshot_tx_id TEXT,
    service_id     service_id  NOT NULL,
    PRIMARY KEY (user_id, work_item_id, role)
);

-- =========================================================
-- POSTGRES CDC SETTINGS (logical replication)
-- =========================================================

ALTER
SYSTEM SET wal_level = logical;
ALTER
SYSTEM SET max_replication_slots = 10;
ALTER
SYSTEM SET max_wal_senders = 10;

-- =========================================================
-- CDC USER
-- =========================================================

CREATE ROLE debezium WITH LOGIN PASSWORD 'debezium';
ALTER
ROLE debezium WITH REPLICATION;

GRANT CONNECT
ON DATABASE cdc_db TO debezium;
GRANT TEMPORARY
ON DATABASE cdc_db TO debezium;
GRANT USAGE ON SCHEMA
public TO debezium;
GRANT
SELECT
ON ALL TABLES IN SCHEMA public TO debezium;
GRANT pg_read_all_data TO debezium;

-- =========================================================
-- PUBLICATION (ONLY PROJECTION TABLE)
-- =========================================================

ALTER TABLE user_items_projection REPLICA IDENTITY FULL;

CREATE
PUBLICATION debezium_workitems_pub
    FOR TABLE public.user_items_projection;

-- =========================================================
-- AUDIT TABLES
-- append-only, never updated or deleted
-- one row per state change on the source entity
-- =========================================================

CREATE TABLE work_item_audit
(
    id           UUID PRIMARY KEY DEFAULT uuid_generate_v4(),
    work_item_id UUID NOT NULL,
    action       TEXT NOT NULL CHECK (action IN ('created', 'updated', 'deleted')
) ,

    -- full snapshot of the row at the time of the change
    title        TEXT        NOT NULL,
    status       TEXT        NOT NULL,
    due_at       TIMESTAMPTZ,

    -- what changed (NULL on create)
    old_status   TEXT,
    old_due_at   TIMESTAMPTZ,
    old_title    TEXT,

    changed_at   TIMESTAMPTZ NOT NULL DEFAULT now(),
    changed_by   service_id  NOT NULL  -- which service triggered the change
);

CREATE TABLE work_assignment_audit
(
    id           UUID PRIMARY KEY DEFAULT uuid_generate_v4(),
    work_item_id UUID NOT NULL,
    action       TEXT NOT NULL CHECK (action IN ('assigned', 'reassigned', 'unassigned')
) ,

    -- current state
    user_id        UUID        NOT NULL,
    role           TEXT        NOT NULL,

    -- previous state — populated on reassign, NULL on first assign / unassign
    old_user_id    UUID,
    old_role       TEXT,

    changed_at     TIMESTAMPTZ NOT NULL DEFAULT now(),
    changed_by     service_id  NOT NULL
);

-- indexes for the most common audit queries
CREATE INDEX idx_work_item_audit_work_item_id ON work_item_audit (work_item_id, changed_at DESC);
CREATE INDEX idx_work_assignment_audit_item_id ON work_assignment_audit (work_item_id, changed_at DESC);
CREATE INDEX idx_work_assignment_audit_user_id ON work_assignment_audit (user_id, changed_at DESC);

-- =========================================================
-- PROJECTION SYNC TRIGGERS
-- =========================================================

CREATE
OR REPLACE FUNCTION sync_projection_from_work_item()
    RETURNS TRIGGER AS
$$
BEGIN
    -- audit: created
    IF
TG_OP = 'INSERT' THEN
        INSERT INTO work_item_audit (work_item_id, action, title, status, due_at,
                                     old_status, old_due_at, old_title, changed_by)
        VALUES (NEW.id, 'created', NEW.title, NEW.status, NEW.due_at,
                NULL, NULL, NULL, random_service_id());
RETURN NEW;
END IF;

    -- audit: deleted (soft delete)
    IF
NEW.deleted_at IS NOT NULL AND OLD.deleted_at IS NULL THEN
        INSERT INTO work_item_audit (work_item_id, action, title, status, due_at,
                                     old_status, old_due_at, old_title, changed_by)
        VALUES (NEW.id, 'deleted', NEW.title, NEW.status, NEW.due_at,
                OLD.status, OLD.due_at, OLD.title, random_service_id());

        -- remove all projection rows for this item
DELETE
FROM user_items_projection
WHERE work_item_id = NEW.id;
RETURN NEW;
END IF;

    -- audit: updated (only when something meaningful changed)
    IF
OLD.status IS DISTINCT FROM NEW.status
        OR OLD.due_at IS DISTINCT FROM NEW.due_at
        OR OLD.title  IS DISTINCT FROM NEW.title THEN

        INSERT INTO work_item_audit (work_item_id, action, title, status, due_at,
                                     old_status, old_due_at, old_title, changed_by)
        VALUES (NEW.id, 'updated', NEW.title, NEW.status, NEW.due_at,
                OLD.status, OLD.due_at, OLD.title, random_service_id());
END IF;

    -- propagate status/due_at changes to ALL assigned users and roles
UPDATE user_items_projection
SET status     = NEW.status,
    due_at     = NEW.due_at,
    version    = version + 1,
    updated_at = now()
WHERE work_item_id = NEW.id;

RETURN NEW;
END;
$$
LANGUAGE plpgsql;


CREATE
OR REPLACE FUNCTION sync_projection_from_assignment()
    RETURNS TRIGGER AS
$$
DECLARE
wi         RECORD;
    svc
service_id;
BEGIN
SELECT *
INTO wi
FROM work_item
WHERE id = COALESCE(NEW.work_item_id, OLD.work_item_id);

-- roll service_id once per trigger execution
svc
:= random_service_id();

    -- work_item soft deleted — remove projection row for this user, no audit entry
    -- (work_item_audit already captured the deletion)
    IF
wi.deleted_at IS NOT NULL THEN
DELETE
FROM user_items_projection
WHERE work_item_id = wi.id
  AND user_id = COALESCE(NEW.user_id, OLD.user_id);
RETURN NULL;
END IF;

    -- assignment hard delete or soft delete → unassigned
    IF
TG_OP = 'DELETE' OR (TG_OP = 'UPDATE' AND NEW.deleted_at IS NOT NULL) THEN
        INSERT INTO work_assignment_audit (work_item_id, action, user_id, role,
                                           old_user_id, old_role, changed_by)
        VALUES (OLD.work_item_id, 'unassigned', OLD.user_id, OLD.role,
                NULL, NULL, svc);

DELETE
FROM user_items_projection
WHERE user_id = OLD.user_id
  AND work_item_id = OLD.work_item_id
  AND role = OLD.role;
RETURN NULL;
END IF;

    -- first assignment → assigned
    IF
TG_OP = 'INSERT' THEN
        INSERT INTO work_assignment_audit (work_item_id, action, user_id, role,
                                           old_user_id, old_role, changed_by)
        VALUES (NEW.work_item_id, 'assigned', NEW.user_id, NEW.role,
                NULL, NULL, svc);

    -- role or user changed → reassigned
    ELSIF
TG_OP = 'UPDATE' THEN
        IF OLD.role IS DISTINCT FROM NEW.role OR OLD.user_id IS DISTINCT FROM NEW.user_id THEN
            INSERT INTO work_assignment_audit (work_item_id, action, user_id, role,
                                               old_user_id, old_role, changed_by)
            VALUES (NEW.work_item_id, 'reassigned', NEW.user_id, NEW.role,
                    OLD.user_id, OLD.role, svc);

            -- remove old projection row
DELETE
FROM user_items_projection
WHERE user_id = OLD.user_id
  AND work_item_id = OLD.work_item_id
  AND role = OLD.role;
END IF;
END IF;

    -- upsert projection
INSERT INTO user_items_projection (user_id,
                                   work_item_id,
                                   role,
                                   status,
                                   due_at,
                                   created_at,
                                   version,
                                   updated_at,
                                   service_id,
                                   snapshot_tx_id)
VALUES (NEW.user_id,
        NEW.work_item_id,
        NEW.role,
        wi.status,
        wi.due_at,
        wi.created_at,
        1,
        now(),
        svc,
        NULL) ON CONFLICT (user_id, work_item_id, role) DO
UPDATE
    SET status = EXCLUDED.status,
    due_at = EXCLUDED.due_at,
    version = user_items_projection.version + 1,
    updated_at = now();

RETURN NEW;
END;
$$
LANGUAGE plpgsql;

-- =========================================================
-- TRIGGERS
-- =========================================================

CREATE TRIGGER trg_work_item_projection
    AFTER INSERT OR
UPDATE
    ON work_item
    FOR EACH ROW
    EXECUTE FUNCTION sync_projection_from_work_item();

CREATE TRIGGER trg_work_assignment_projection
    AFTER INSERT OR
UPDATE OR
DELETE
ON work_assignment
    FOR EACH ROW
    EXECUTE FUNCTION sync_projection_from_assignment();

-- =========================================================
-- TEST DATA
-- =========================================================

INSERT INTO user_profile (user_id, timezone)
VALUES ('BBA1C98B-94F3-4265-9DC9-EE3A3E64A087', 'Europe/Warsaw'),
       ('CE863D57-F767-4CE0-8EBB-FA108A99D324', 'Europe/Berlin'),
       ('BE09B724-2075-4D65-B179-206C9251A751', 'America/New_York'),
       ('3B9D8588-72D6-4CA0-BD69-271A8139907B', 'Asia/Tokyo');

INSERT INTO work_item (id, title, status, due_at, created_at, updated_at, deleted_at)
VALUES ('25AA3915-1A85-4553-90D7-F7C89B6D4268', 'Active task 1', 'active', now() + interval '2 days', now(), now(),
        NULL);

INSERT INTO work_assignment (work_item_id, user_id, role, created_at, deleted_at)
VALUES ('25AA3915-1A85-4553-90D7-F7C89B6D4268', 'BBA1C98B-94F3-4265-9DC9-EE3A3E64A087', 'owner', now(), NULL),
       ('25AA3915-1A85-4553-90D7-F7C89B6D4268', 'CE863D57-F767-4CE0-8EBB-FA108A99D324', 'watcher', now(), NULL),
       ('25AA3915-1A85-4553-90D7-F7C89B6D4268', 'BE09B724-2075-4D65-B179-206C9251A751', 'executor', now(), NULL),
       ('25AA3915-1A85-4553-90D7-F7C89B6D4268', '3B9D8588-72D6-4CA0-BD69-271A8139907B', 'reviewer', now(), NULL);