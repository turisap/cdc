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