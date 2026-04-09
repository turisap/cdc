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

    version    BIGINT      NOT NULL DEFAULT 0,

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
    version      BIGINT      NOT NULL DEFAULT 0,

    created_at   TIMESTAMPTZ NOT NULL DEFAULT now(),
    deleted_at   TIMESTAMPTZ
);

CREATE TABLE user_profile
(
    user_id  UUID PRIMARY KEY,
    timezone TEXT NOT NULL -- e.g. "Europe/Warsaw"
);


INSERT INTO user_profile (user_id, timezone)
VALUES
-- Europe users
('00000000-0000-0000-0000-000000000001', 'Europe/Warsaw'),
('00000000-0000-0000-0000-000000000002', 'Europe/Berlin'),

-- US user
('00000000-0000-0000-0000-000000000003', 'America/New_York'),

-- Asia user
('00000000-0000-0000-0000-000000000004', 'Asia/Tokyo');

INSERT INTO work_item (id, title, status, due_at, created_at, updated_at, deleted_at, version)
VALUES

-- ACTIVE (future due date)
('10000000-0000-0000-0000-000000000001', 'Active task 1', 'active',
 now() + interval '2 days', now(), now(), NULL, 1),

('10000000-0000-0000-0000-000000000002', 'Active task 2', 'active',
 now() + interval '5 hours', now(), now(), NULL, 1),

-- EXPIRED (past due date)
('10000000-0000-0000-0000-000000000003', 'Expired task 1', 'expired',
 now() - interval '1 day', now(), now(), NULL, 2),

-- COMPLETED
('10000000-0000-0000-0000-000000000004', 'Completed task 1', 'completed',
 now() - interval '2 days', now(), now(), NULL, 3),

-- TODAY task (important for timezone logic)
('10000000-0000-0000-0000-000000000005', 'Today task', 'active',
 now() + interval '2 hours', now(), now(), NULL, 1),

-- SOFT DELETED (should not count)
('10000000-0000-0000-0000-000000000006', 'Deleted task', 'active',
 now() + interval '1 day', now(), now(), now(), 2);

INSERT INTO work_assignment (id, work_item_id, user_id, role, created_at, deleted_at, version)
VALUES

-- Task 1 (active)
-- user1 = owner
('20000000-0000-0000-0000-000000000001',
 '10000000-0000-0000-0000-000000000001',
 '00000000-0000-0000-0000-000000000001',
 'owner', now(), NULL, 1),

-- user2 = executor
('20000000-0000-0000-0000-000000000002',
 '10000000-0000-0000-0000-000000000001',
 '00000000-0000-0000-0000-000000000002',
 'executor', now(), NULL, 1),

-- Task 2 (active)
-- user1 = executor
('20000000-0000-0000-0000-000000000003',
 '10000000-0000-0000-0000-000000000002',
 '00000000-0000-0000-0000-000000000001',
 'executor', now(), NULL, 1),

-- user3 = watcher
('20000000-0000-0000-0000-000000000004',
 '10000000-0000-0000-0000-000000000002',
 '00000000-0000-0000-0000-000000000003',
 'watcher', now(), NULL, 1),

-- Task 3 (expired)
-- user2 = owner
('20000000-0000-0000-0000-000000000005',
 '10000000-0000-0000-0000-000000000003',
 '00000000-0000-0000-0000-000000000002',
 'owner', now(), NULL, 2),

-- Task 4 (completed)
-- user3 = executor
('20000000-0000-0000-0000-000000000006',
 '10000000-0000-0000-0000-000000000004',
 '00000000-0000-0000-0000-000000000003',
 'executor', now(), NULL, 3),

-- Task 5 (today task)
-- user1 = owner
('20000000-0000-0000-0000-000000000007',
 '10000000-0000-0000-0000-000000000005',
 '00000000-0000-0000-0000-000000000001',
 'owner', now(), NULL, 1),

-- user4 = executor
('20000000-0000-0000-0000-000000000008',
 '10000000-0000-0000-0000-000000000005',
 '00000000-0000-0000-0000-000000000004',
 'executor', now(), NULL, 1),

-- SOFT-DELETED assignment (should not count)
('20000000-0000-0000-0000-000000000009',
 '10000000-0000-0000-0000-000000000001',
 '00000000-0000-0000-0000-000000000003',
 'watcher', now(), now(), 2);