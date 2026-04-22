-- =========================================================
-- CLEAN CDC DEMO SCHEMA (NO VERSION IN SOURCE TABLE)
-- =========================================================

-- =========================
-- CORE DOMAIN TABLES
-- =========================

CREATE TABLE work_item
(
    id         UUID PRIMARY KEY,
    title      TEXT        NOT NULL,

    status     TEXT        NOT NULL CHECK (
        status IN ('active', 'completed', 'expired')
        ),

    due_at     TIMESTAMPTZ,
    created_at TIMESTAMPTZ NOT NULL DEFAULT now(),
    updated_at TIMESTAMPTZ NOT NULL DEFAULT now(),
    deleted_at TIMESTAMPTZ
);

CREATE TABLE work_assignment
(
    id           UUID PRIMARY KEY,
    work_item_id UUID        NOT NULL REFERENCES work_item (id),

    user_id      UUID        NOT NULL,

    role         TEXT        NOT NULL CHECK (
        role IN ('owner', 'executor', 'watcher')
        ),

    created_at   TIMESTAMPTZ NOT NULL DEFAULT now(),
    deleted_at   TIMESTAMPTZ
);

CREATE TABLE user_profile
(
    user_id  UUID PRIMARY KEY,
    timezone TEXT NOT NULL
);

-- =========================================================
-- PROJECTION TABLE (THIS IS WHAT CDC WILL READ)
-- =========================================================

CREATE TABLE user_items_projection
(
    user_id    UUID        NOT NULL,
    task_id    UUID        NOT NULL,
    role       TEXT        NOT NULL,

    status     TEXT        NOT NULL,

    due_at     TIMESTAMPTZ,
    created_at TIMESTAMPTZ NOT NULL,

    is_active  BOOLEAN     NOT NULL,
    is_expired BOOLEAN     NOT NULL,

    updated_at TIMESTAMPTZ NOT NULL DEFAULT now(),

    version    BIGINT      NOT NULL,

    PRIMARY KEY (user_id, task_id, role)
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

CREATE
PUBLICATION debezium_workitems_pub
FOR TABLE public.user_items_projection;

-- =========================================================
-- PUBLICATION (ONLY PROJECTION TABLE)
-- =========================================================

CREATE
PUBLICATION debezium_pub
FOR TABLE public.user_items_projection;

-- =========================================================
-- BUSINESS LOGIC: FLAGS CALCULATION
-- =========================================================

CREATE
OR REPLACE FUNCTION compute_task_flags(
    status TEXT,
    due_at TIMESTAMPTZ
)
RETURNS TABLE (is_active BOOLEAN, is_expired BOOLEAN)
AS $$
BEGIN
RETURN QUERY
SELECT (status = 'active')                                           AS is_active,
       (status = 'active' AND due_at IS NOT NULL AND due_at < now()) AS is_expired;
END;
$$
LANGUAGE plpgsql;

-- =========================================================
-- PROJECTION SYNC TRIGGER (SOURCE OF TRUTH FOR CDC)
-- =========================================================

CREATE
OR REPLACE FUNCTION sync_projection_from_work_item()
RETURNS TRIGGER AS $$
DECLARE
flags RECORD;
BEGIN
SELECT *
INTO flags
FROM compute_task_flags(NEW.status, NEW.due_at);

-- UPSERT with version control
INSERT INTO user_items_projection (user_id,
                                   task_id,
                                   role,
                                   status,
                                   due_at,
                                   created_at,
                                   is_active,
                                   is_expired,
                                   version,
                                   updated_at)
VALUES (NEW.id, -- TODO replace with real user_id mapping
        NEW.id,
        'owner',
        NEW.status,
        NEW.due_at,
        NEW.created_at,
        flags.is_active,
        flags.is_expired,
        1,
        now()) ON CONFLICT (user_id, task_id, role)
    DO
UPDATE SET
    status = EXCLUDED.status,
    due_at = EXCLUDED.due_at,
    is_active = EXCLUDED.is_active,
    is_expired = EXCLUDED.is_expired,

    version = user_items_projection.version + 1,

    updated_at = now();

RETURN NEW;
END;
$$
LANGUAGE plpgsql;

CREATE
OR REPLACE FUNCTION sync_projection_from_assignment()
RETURNS TRIGGER AS $$
DECLARE
flags RECORD;
    wi
RECORD;
BEGIN
    -- Load work_item
SELECT *
INTO wi
FROM work_item
WHERE id = COALESCE(NEW.work_item_id, OLD.work_item_id);

-- If task is deleted → remove projection rows
IF
wi.deleted_at IS NOT NULL THEN
DELETE
FROM user_items_projection
WHERE task_id = wi.id
  AND user_id = COALESCE(NEW.user_id, OLD.user_id);
RETURN NULL;
END IF;

    -- Compute flags
SELECT *
INTO flags
FROM compute_task_flags(wi.status, wi.due_at);

-- =========================
-- DELETE / SOFT DELETE
-- =========================
IF
TG_OP = 'DELETE' OR (TG_OP = 'UPDATE' AND NEW.deleted_at IS NOT NULL) THEN
DELETE
FROM user_items_projection
WHERE user_id = OLD.user_id
  AND task_id = OLD.work_item_id
  AND role = OLD.role;

RETURN NULL;
END IF;

    -- =========================
    -- ROLE CHANGE (UPDATE)
    -- =========================
    IF
TG_OP = 'UPDATE' THEN
        -- If role OR user changed → remove old row
        IF OLD.role IS DISTINCT FROM NEW.role
           OR OLD.user_id IS DISTINCT FROM NEW.user_id THEN

DELETE
FROM user_items_projection
WHERE user_id = OLD.user_id
  AND task_id = OLD.work_item_id
  AND role = OLD.role;
END IF;
END IF;

    -- =========================
    -- UPSERT NEW STATE
    -- =========================
INSERT INTO user_items_projection (user_id,
                                   task_id,
                                   role,
                                   status,
                                   due_at,
                                   created_at,
                                   is_active,
                                   is_expired,
                                   version,
                                   updated_at)
VALUES (NEW.user_id,
        NEW.work_item_id,
        NEW.role,
        wi.status,
        wi.due_at,
        wi.created_at,
        flags.is_active,
        flags.is_expired,
        1,
        now()) ON CONFLICT (user_id, task_id, role)
    DO
UPDATE SET
    status = EXCLUDED.status,
    due_at = EXCLUDED.due_at,
    is_active = EXCLUDED.is_active,
    is_expired = EXCLUDED.is_expired,
    version = user_items_projection.version + 1,
    updated_at = now();

RETURN NEW;
END;
$$
LANGUAGE plpgsql;

-- @TODO a few partitions and finish triggers
-- @TODO store only active records (not deleted or cancelled),
-- @TODO use shorts keys instead projection:{user}:{task}:{role} p:{u}:{t}:{r} HSET p:1:100:executor v 3 a 1 e 0

-- =========================================================
-- TRIGGER
-- =========================================================

CREATE TRIGGER trg_work_item_projectionwork_assignment
    AFTER INSERT OR
UPDATE ON work_item
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
VALUES ('00000000-0000-0000-0000-000000000001', 'Europe/Warsaw'),
       ('00000000-0000-0000-0000-000000000002', 'Europe/Berlin'),
       ('00000000-0000-0000-0000-000000000003', 'America/New_York'),
       ('00000000-0000-0000-0000-000000000004', 'Asia/Tokyo');

INSERT INTO work_item (id, title, status, due_at, created_at, updated_at, deleted_at)
VALUES ('10000000-0000-0000-0000-000000000001', 'Active task 1', 'active', now() + interval '2 days', now(), now(),
        NULL),
       ('10000000-0000-0000-0000-000000000002', 'Active task 2', 'active', now() + interval '5 hours', now(), now(),
        NULL),
       ('10000000-0000-0000-0000-000000000003', 'Expired task', 'expired', now() - interval '1 day', now(), now(),
        NULL),
       ('10000000-0000-0000-0000-000000000004', 'Completed task', 'completed', now() - interval '2 days', now(), now(),
        NULL),
       ('10000000-0000-0000-0000-000000000005', 'Today task', 'active', now() + interval '2 hours', now(), now(), NULL),
       ('10000000-0000-0000-0000-000000000006', 'Deleted task', 'active', now() + interval '1 day', now(), now(),
        now());

INSERT INTO work_assignment (id, work_item_id, user_id, role, created_at, deleted_at)
VALUES ('20000000-0000-0000-0000-000000000001', '10000000-0000-0000-0000-000000000001',
        '00000000-0000-0000-0000-000000000001', 'owner', now(), NULL),
       ('20000000-0000-0000-0000-000000000002', '10000000-0000-0000-0000-000000000001',
        '00000000-0000-0000-0000-000000000002', 'executor', now(), NULL),
       ('20000000-0000-0000-0000-000000000003', '10000000-0000-0000-0000-000000000002',
        '00000000-0000-0000-0000-000000000001', 'executor', now(), NULL),
       ('20000000-0000-0000-0000-000000000004', '10000000-0000-0000-0000-000000000002',
        '00000000-0000-0000-0000-000000000003', 'watcher', now(), NULL);