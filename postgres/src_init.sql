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

-- UPSERT author/owner relation example (extend later for assignments if needed)
INSERT INTO user_items_projection (user_id,
                                   task_id,
                                   role,
                                   status,
                                   due_at,
                                   created_at,
                                   is_active,
                                   is_expired,
                                   updated_at)
VALUES (NEW.id, -- NOTE: placeholder; replace with real user mapping logic
        NEW.id,
        'owner',
        NEW.status,
        NEW.due_at,
        NEW.created_at,
        flags.is_active,
        flags.is_expired,
        now()) ON CONFLICT (user_id, task_id, role)
    DO
UPDATE SET
    status = EXCLUDED.status,
    due_at = EXCLUDED.due_at,
    is_active = EXCLUDED.is_active,
    is_expired = EXCLUDED.is_expired,
    updated_at = now();

RETURN NEW;
END;
$$
LANGUAGE plpgsql;

-- =========================================================
-- TRIGGER
-- =========================================================

CREATE TRIGGER trg_work_item_projection
    AFTER INSERT OR
UPDATE ON work_item
    FOR EACH ROW
    EXECUTE FUNCTION sync_projection_from_work_item();

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