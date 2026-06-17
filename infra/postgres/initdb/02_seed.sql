-- Argus enterprise simulation — synthetic seed data.
-- Generates ~500 users, ~1000 assets, ~10,000 access logs, ~120 tickets.
-- Determinism: setseed() called below, so reseeds reproduce the same data.

BEGIN;

SET search_path TO enterprise, public;

-- Reproducible RNG seed
SELECT setseed(0.42);

-- ----------------------------------------------------------------------
-- Insert the 8 Keycloak-aligned users explicitly so cross-system joins work.
-- These match infra/keycloak/realm.json.
-- ----------------------------------------------------------------------
INSERT INTO users (employee_id, username, email, full_name, department, role, manager_id) VALUES
    ('E0001', 'alice.helpdesk',   'alice.helpdesk@example.com',   'Alice Helpdesk',   'IT Support',   'helpdesk',   NULL),
    ('E0002', 'bob.helpdesk',     'bob.helpdesk@example.com',     'Bob Helpdesk',     'IT Support',   'helpdesk',   NULL),
    ('E0003', 'carol.helpdesk',   'carol.helpdesk@example.com',   'Carol Helpdesk',   'IT Support',   'helpdesk',   NULL),
    ('E0004', 'dave.manager',     'dave.manager@example.com',     'Dave Manager',     'Engineering',  'manager',    NULL),
    ('E0005', 'erin.manager',     'erin.manager@example.com',     'Erin Manager',     'Engineering',  'manager',    NULL),
    ('E0006', 'frank.itadmin',    'frank.itadmin@example.com',    'Frank ITAdmin',    'IT Support',   'it-admin',   NULL),
    ('E0007', 'grace.itadmin',    'grace.itadmin@example.com',    'Grace ITAdmin',    'IT Support',   'it-admin',   NULL),
    ('E0008', 'henry.compliance', 'henry.compliance@example.com', 'Henry Compliance', 'Compliance',   'compliance', NULL)
ON CONFLICT (employee_id) DO NOTHING;

-- Backfill manager_id pointing helpdesk -> Frank, engineering -> Dave
UPDATE users SET manager_id = 'E0006' WHERE role = 'helpdesk' AND manager_id IS NULL;
UPDATE users SET manager_id = 'E0006' WHERE role = 'compliance' AND manager_id IS NULL;

-- ----------------------------------------------------------------------
-- Bulk-insert ~492 additional synthetic staff users (E0009 .. E0500).
-- ----------------------------------------------------------------------
INSERT INTO users (employee_id, username, email, full_name, department, role, manager_id)
SELECT
    'E' || LPAD(n::TEXT, 4, '0'),
    'staff' || n,
    'staff' || n || '@example.com',
    'Staff Member ' || n,
    (ARRAY['Engineering', 'Sales', 'Marketing', 'Finance', 'HR', 'Operations', 'Legal'])[1 + (n % 7)],
    'staff',
    -- Round-robin assign to one of the two managers
    CASE WHEN n % 2 = 0 THEN 'E0004' ELSE 'E0005' END
FROM generate_series(9, 500) AS n
ON CONFLICT (employee_id) DO NOTHING;

-- ----------------------------------------------------------------------
-- Assets: ~1000 spread across users, types, and sensitivity tiers.
-- ----------------------------------------------------------------------
INSERT INTO assets (asset_id, asset_type, hostname, owner_id, sensitivity, last_seen)
SELECT
    'A' || LPAD(n::TEXT, 5, '0'),
    (ARRAY['laptop', 'desktop', 'server', 'dataset', 'application', 'mobile'])[1 + (n % 6)],
    'host-' || n || '.example.com',
    'E' || LPAD((1 + (n % 500))::TEXT, 4, '0'),
    (ARRAY['public', 'internal', 'internal', 'internal', 'confidential', 'restricted'])[1 + (n % 6)],
    NOW() - ((random() * 90)::INT || ' days')::INTERVAL
FROM generate_series(1, 1000) AS n;

-- A few obviously-sensitive named assets the agent might encounter.
INSERT INTO assets (asset_id, asset_type, hostname, owner_id, sensitivity, last_seen) VALUES
    ('A99001', 'dataset',     'pii-customer-export.example.com',  'E0008', 'restricted',   NOW() - INTERVAL '2 days'),
    ('A99002', 'dataset',     'salary-2026-q1.example.com',       'E0004', 'restricted',   NOW() - INTERVAL '5 days'),
    ('A99003', 'application', 'audit-archive.example.com',        'E0008', 'confidential', NOW() - INTERVAL '1 day'),
    ('A99004', 'server',      'prod-db-primary.example.com',      'E0006', 'restricted',   NOW() - INTERVAL '6 hours'),
    ('A99005', 'application', 'helpdesk-portal.example.com',      'E0001', 'internal',     NOW() - INTERVAL '1 hour')
ON CONFLICT (asset_id) DO NOTHING;

-- ----------------------------------------------------------------------
-- Access logs: 10,000 events spanning the last 90 days.
-- Mix of successful and failed events; weights bias toward 'read' / 'login'.
-- ----------------------------------------------------------------------
INSERT INTO access_logs (employee_id, asset_id, action, source_ip, succeeded, occurred_at)
SELECT
    'E' || LPAD((1 + (n % 500))::TEXT, 4, '0'),
    'A' || LPAD((1 + (n % 1000))::TEXT, 5, '0'),
    (ARRAY['login', 'login', 'login', 'logout', 'read', 'read', 'read', 'write', 'export', 'failed_login', 'admin_action'])[1 + (n % 11)],
    ('10.0.' || (n % 256) || '.' || ((n * 7) % 256))::INET,
    -- ~95% success
    (n % 20) <> 0,
    NOW() - ((random() * 90 * 86400)::INT || ' seconds')::INTERVAL
FROM generate_series(1, 10000) AS n;

-- ----------------------------------------------------------------------
-- Tickets: ~120 helpdesk tickets in mixed states.
-- ----------------------------------------------------------------------
INSERT INTO tickets (ticket_id, requester_id, assignee_id, title, description, status, priority, created_at, updated_at)
SELECT
    'T' || LPAD(n::TEXT, 5, '0'),
    'E' || LPAD((9 + (n % 492))::TEXT, 4, '0'),                                   -- requester from staff pool
    (ARRAY['E0001', 'E0002', 'E0003'])[1 + (n % 3)],                              -- helpdesk assignee
    (ARRAY[
        'Password reset request',
        'VPN connectivity issue',
        'New laptop provisioning',
        'Email export request',
        'Software install: data analysis tools',
        'Access request for shared drive',
        'MFA token re-enrollment',
        'Printer driver installation'
    ])[1 + (n % 8)],
    'Synthetic ticket #' || n || ' for Argus harness testing.',
    (ARRAY['open', 'open', 'in_progress', 'in_progress', 'pending_approval', 'resolved', 'closed'])[1 + (n % 7)],
    (ARRAY['low', 'normal', 'normal', 'normal', 'high', 'urgent'])[1 + (n % 6)],
    NOW() - ((random() * 30 * 86400)::INT || ' seconds')::INTERVAL,
    NOW() - ((random() * 5 * 86400)::INT || ' seconds')::INTERVAL
FROM generate_series(1, 120) AS n;

COMMIT;

-- Sanity check — surfaced in `docker logs` so the operator can confirm.
\echo 'Seed counts:'
SELECT 'users' AS table_name, COUNT(*) FROM enterprise.users
UNION ALL SELECT 'assets', COUNT(*) FROM enterprise.assets
UNION ALL SELECT 'access_logs', COUNT(*) FROM enterprise.access_logs
UNION ALL SELECT 'tickets', COUNT(*) FROM enterprise.tickets;
