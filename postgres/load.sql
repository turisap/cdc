-- =============================================================
-- load test: 30k users, 500k work_items, 4-20 assignments each
-- =============================================================

-- 30k users with random timezones
INSERT INTO user_profile (user_id, timezone)
SELECT uuid_generate_v4(),
       (ARRAY [
           'Europe/Warsaw', 'Europe/Berlin', 'Europe/London', 'Europe/Paris',
           'America/New_York', 'America/Chicago', 'America/Los_Angeles',
           'Asia/Tokyo', 'Asia/Shanghai', 'Asia/Singapore',
           'Australia/Sydney', 'Pacific/Auckland'
           ])[floor(random() * 12 + 1)::int]
FROM generate_series(1, 30000);

-- 500k work_items
INSERT INTO work_item (id, title, status, due_at, created_at, updated_at)
SELECT uuid_generate_v4(),
       'Load test task ' || s,
       (ARRAY ['active', 'active', 'active', 'completed', 'expired'])[floor(random() * 5 + 1)::int],
       CASE
           WHEN random() < 0.2 THEN NULL
           WHEN random() < 0.5 THEN now() + (floor(random() * 30)::int * interval '1 day')
           ELSE now() - (floor(random() * 30)::int * interval '1 day')
           END,
       now() - (floor(random() * 90)::int * interval '1 day'),
       now()
FROM generate_series(1, 100000) s;

-- assignments: 4-20 per work_item, owner always first then random roles
-- users pulled randomly from user_profile
-- uses a lateral to generate variable number of rows per work_item
INSERT INTO work_assignment (work_item_id, user_id, role, created_at)
SELECT wi.id,
       up.user_id,
       roles.role,
       now() - (floor(random() * 90)::int * interval '1 day')
FROM (SELECT id, floor(random() * 17 + 4)::int AS assignment_count
      FROM work_item
      WHERE title LIKE 'Load test task %') wi
         CROSS JOIN LATERAL generate_series(1, wi.assignment_count) AS slot(n)
         CROSS JOIN LATERAL (
    SELECT (ARRAY ['owner', 'executor', 'watcher', 'reviewer'])[floor(random() * 4 + 1)::int] AS role
    ) roles
         CROSS JOIN LATERAL (
    SELECT user_id
    FROM user_profile
    OFFSET floor(random() * 30000)::int LIMIT 1
    ) up
ON CONFLICT DO NOTHING;;

-- =============================================================
-- verify
-- =============================================================

SELECT (SELECT count(*) FROM user_profile)          AS users,
       (SELECT count(*)
        FROM work_item
        WHERE title LIKE 'Load test task %')        AS work_items,
       (SELECT count(*)
        FROM work_assignment wa
                 JOIN work_item wi ON wi.id = wa.work_item_id
        WHERE wi.title LIKE 'Load test task %')     AS assignments,
       (SELECT count(*) FROM user_items_projection) AS projection_rows;