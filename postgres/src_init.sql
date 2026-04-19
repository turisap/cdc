-- =========================
-- CORE TABLES
-- =========================

CREATE TABLE work_item
(
    id         UUID PRIMARY KEY,

    author_id  UUID        NOT NULL,

    title      TEXT        NOT NULL,

    status     TEXT        NOT NULL CHECK (
        status IN ('active', 'completed', 'expired')
        ),

    due_at     TIMESTAMPTZ,
    created_at TIMESTAMPTZ NOT NULL DEFAULT now(),
    updated_at TIMESTAMPTZ NOT NULL DEFAULT now(),

    version    BIGINT      NOT NULL DEFAULT 1,

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

-- =========================
-- PROJECTION TABLE
-- =========================

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

    version    BIGINT      NOT NULL,

    updated_at TIMESTAMPTZ NOT NULL DEFAULT now(),

    PRIMARY KEY (user_id, task_id, role)
);

-- =========================
-- DEBEZIUM SETUP
-- =========================

ALTER SYSTEM SET wal_level = logical;
ALTER SYSTEM SET max_replication_slots = 10;
ALTER SYSTEM SET max_wal_senders = 10;

CREATE ROLE debezium WITH LOGIN PASSWORD 'debezium';

GRANT CONNECT ON DATABASE cdc_db TO debezium;
GRANT USAGE ON SCHEMA public TO debezium;
GRANT SELECT ON TABLE public.user_items_projection TO debezium;

ALTER ROLE debezium WITH REPLICATION;

CREATE PUBLICATION debezium_workitems_pub
FOR TABLE public.user_items_projection;

-- =========================
-- HELPER
-- =========================

CREATE OR REPLACE FUNCTION compute_task_flags(
  status TEXT,
  due_at TIMESTAMPTZ
)
RETURNS TABLE (is_active BOOLEAN, is_expired BOOLEAN)
AS $$
BEGIN
RETURN QUERY SELECT
    (status = 'active') AS is_active,
    (status = 'active' AND due_at IS NOT NULL AND due_at < now()) AS is_expired;
END;
$$ LANGUAGE plpgsql;

-- =========================
-- TRIGGER: WORK ITEM
-- =========================

CREATE OR REPLACE FUNCTION sync_projection_from_work_item()
RETURNS TRIGGER AS $$
DECLARE
flags RECORD;
BEGIN
SELECT * INTO flags FROM compute_task_flags(NEW.status, NEW.due_at);

-- update all rows for task
UPDATE user_items_projection
SET status     = NEW.status,
    due_at     = NEW.due_at,
    is_active  = flags.is_active,
    is_expired = flags.is_expired,
    version    = NEW.version,
    updated_at = now()
WHERE task_id = NEW.id;

-- handle author
INSERT INTO user_items_projection (
    user_id, task_id, role,
    status, due_at, created_at,
    is_active, is_expired,
    version, updated_at
)
VALUES (
           NEW.author_id, NEW.id, 'author',
           NEW.status, NEW.due_at, NEW.created_at,
           flags.is_active, flags.is_expired,
           NEW.version, now()
       )
    ON CONFLICT (user_id, task_id, role)
  DO UPDATE SET
    status = EXCLUDED.status,
             due_at = EXCLUDED.due_at,
             is_active = EXCLUDED.is_active,
             is_expired = EXCLUDED.is_expired,
             version = EXCLUDED.version,
             updated_at = now();

RETURN NEW;
END;
$$ LANGUAGE plpgsql;

CREATE TRIGGER trg_work_item_projection
    AFTER INSERT OR UPDATE ON work_item
                        FOR EACH ROW
                        WHEN (NEW.deleted_at IS NULL)
                        EXECUTE FUNCTION sync_projection_from_work_item();

-- =========================
-- TRIGGER: ASSIGNMENT
-- =========================

CREATE OR REPLACE FUNCTION sync_projection_from_assignment()
RETURNS TRIGGER AS $$
DECLARE
wi RECORD;
  flags RECORD;
  mapped_role TEXT;
BEGIN
  -- role mapping
  mapped_role := CASE NEW.role
    WHEN 'owner' THEN 'author'
    WHEN 'executor' THEN 'performer'
    WHEN 'watcher' THEN 'observer'
END;

  IF TG_OP = 'INSERT' AND NEW.deleted_at IS NULL THEN

SELECT * INTO wi FROM work_item WHERE id = NEW.work_item_id;

SELECT * INTO flags FROM compute_task_flags(wi.status, wi.due_at);

INSERT INTO user_items_projection (
    user_id, task_id, role,
    status, due_at, created_at,
    is_active, is_expired,
    version, updated_at
)
VALUES (
           NEW.user_id, NEW.work_item_id, mapped_role,
           wi.status, wi.due_at, wi.created_at,
           flags.is_active, flags.is_expired,
           wi.version, now()
       )
    ON CONFLICT DO NOTHING;

END IF;

  IF TG_OP = 'DELETE' OR (TG_OP = 'UPDATE' AND NEW.deleted_at IS NOT NULL) THEN

DELETE FROM user_items_projection
WHERE user_id = OLD.user_id
  AND task_id = OLD.work_item_id
  AND role = mapped_role;

END IF;

RETURN NULL;
END;
$$ LANGUAGE plpgsql;

CREATE TRIGGER trg_assignment_projection
    AFTER INSERT OR UPDATE OR DELETE ON work_assignment
    FOR EACH ROW
    EXECUTE FUNCTION sync_projection_from_assignment();

-- =========================
-- TEST DATA
-- =========================

INSERT INTO user_profile (user_id, timezone)
VALUES
    ('00000000-0000-0000-0000-000000000001', 'Europe/Warsaw'),
    ('00000000-0000-0000-0000-000000000002', 'Europe/Berlin'),
    ('00000000-0000-0000-0000-000000000003', 'America/New_York'),
    ('00000000-0000-0000-0000-000000000004', 'Asia/Tokyo');

INSERT INTO work_item (
    id, author_id, title, status, due_at, created_at, updated_at, deleted_at
)
VALUES
    ('10000000-0000-0000-0000-000000000001','00000000-0000-0000-0000-000000000001','Active task 1','active', now()+interval '2 days',now(),now(),NULL),
    ('10000000-0000-0000-0000-000000000002','00000000-0000-0000-0000-000000000002','Active task 2','active', now()+interval '5 hours',now(),now(),NULL),
    ('10000000-0000-0000-0000-000000000003','00000000-0000-0000-0000-000000000003','Expired task 1','expired', now()-interval '1 day',now(),now(),NULL),
    ('10000000-0000-0000-0000-000000000004','00000000-0000-0000-0000-000000000003','Completed task 1','completed', now()-interval '2 days',now(),now(),NULL),
    ('10000000-0000-0000-0000-000000000005','00000000-0000-0000-0000-000000000001','Today task','active', now()+interval '2 hours',now(),now(),NULL),
    ('10000000-0000-0000-0000-000000000006','00000000-0000-0000-0000-000000000001','Deleted task','active', now()+interval '1 day',now(),now(),now());

INSERT INTO work_assignment (id, work_item_id, user_id, role, created_at, deleted_at)
VALUES
    ('20000000-0000-0000-0000-000000000001','10000000-0000-0000-0000-000000000001','00000000-0000-0000-0000-000000000001','owner',now(),NULL),
    ('20000000-0000-0000-0000-000000000002','10000000-0000-0000-0000-000000000001','00000000-0000-0000-0000-000000000002','executor',now(),NULL),
    ('20000000-0000-0000-0000-000000000003','10000000-0000-0000-0000-000000000002','00000000-0000-0000-0000-000000000001','executor',now(),NULL),
    ('20000000-0000-0000-0000-000000000004','10000000-0000-0000-0000-000000000002','00000000-0000-0000-0000-000000000003','watcher',now(),NULL);