-- Argus enterprise simulation — schema.
-- Tables: users, assets, access_logs, tickets.
-- All synthetic data; example.com domain only.

BEGIN;

CREATE SCHEMA IF NOT EXISTS enterprise;
SET search_path TO enterprise, public;

-- ----------------------------------------------------------------------
-- users — synthetic employees aligned with Keycloak realm roles.
-- ----------------------------------------------------------------------
CREATE TABLE IF NOT EXISTS users (
    employee_id     TEXT PRIMARY KEY,
    username        TEXT UNIQUE NOT NULL,
    email           TEXT UNIQUE NOT NULL,
    full_name       TEXT NOT NULL,
    department      TEXT NOT NULL,
    role            TEXT NOT NULL CHECK (role IN ('helpdesk', 'manager', 'it-admin', 'compliance', 'staff')),
    manager_id      TEXT REFERENCES users(employee_id),
    is_active       BOOLEAN NOT NULL DEFAULT TRUE,
    created_at      TIMESTAMPTZ NOT NULL DEFAULT NOW()
);
CREATE INDEX IF NOT EXISTS idx_users_role ON users(role);
CREATE INDEX IF NOT EXISTS idx_users_department ON users(department);

-- ----------------------------------------------------------------------
-- assets — laptops, servers, datasets, etc. owned by an employee.
-- ----------------------------------------------------------------------
CREATE TABLE IF NOT EXISTS assets (
    asset_id        TEXT PRIMARY KEY,
    asset_type      TEXT NOT NULL CHECK (asset_type IN ('laptop', 'desktop', 'server', 'dataset', 'application', 'mobile')),
    hostname        TEXT,
    owner_id        TEXT REFERENCES users(employee_id),
    sensitivity     TEXT NOT NULL CHECK (sensitivity IN ('public', 'internal', 'confidential', 'restricted')),
    last_seen       TIMESTAMPTZ,
    created_at      TIMESTAMPTZ NOT NULL DEFAULT NOW()
);
CREATE INDEX IF NOT EXISTS idx_assets_owner ON assets(owner_id);
CREATE INDEX IF NOT EXISTS idx_assets_type ON assets(asset_type);
CREATE INDEX IF NOT EXISTS idx_assets_sensitivity ON assets(sensitivity);

-- ----------------------------------------------------------------------
-- access_logs — append-only auth/access events.
-- ----------------------------------------------------------------------
CREATE TABLE IF NOT EXISTS access_logs (
    log_id          BIGSERIAL PRIMARY KEY,
    employee_id     TEXT REFERENCES users(employee_id),
    asset_id        TEXT REFERENCES assets(asset_id),
    action          TEXT NOT NULL CHECK (action IN ('login', 'logout', 'read', 'write', 'export', 'admin_action', 'failed_login')),
    source_ip       INET,
    succeeded       BOOLEAN NOT NULL DEFAULT TRUE,
    occurred_at     TIMESTAMPTZ NOT NULL DEFAULT NOW()
);
CREATE INDEX IF NOT EXISTS idx_access_logs_employee ON access_logs(employee_id);
CREATE INDEX IF NOT EXISTS idx_access_logs_asset ON access_logs(asset_id);
CREATE INDEX IF NOT EXISTS idx_access_logs_occurred ON access_logs(occurred_at);

-- ----------------------------------------------------------------------
-- tickets — IT helpdesk tickets, the agent's workspace.
-- ----------------------------------------------------------------------
CREATE TABLE IF NOT EXISTS tickets (
    ticket_id       TEXT PRIMARY KEY,
    requester_id    TEXT NOT NULL REFERENCES users(employee_id),
    assignee_id     TEXT REFERENCES users(employee_id),
    title           TEXT NOT NULL,
    description     TEXT,
    status          TEXT NOT NULL CHECK (status IN ('open', 'in_progress', 'pending_approval', 'resolved', 'closed')),
    priority        TEXT NOT NULL CHECK (priority IN ('low', 'normal', 'high', 'urgent')),
    created_at      TIMESTAMPTZ NOT NULL DEFAULT NOW(),
    updated_at      TIMESTAMPTZ NOT NULL DEFAULT NOW()
);
CREATE INDEX IF NOT EXISTS idx_tickets_requester ON tickets(requester_id);
CREATE INDEX IF NOT EXISTS idx_tickets_assignee ON tickets(assignee_id);
CREATE INDEX IF NOT EXISTS idx_tickets_status ON tickets(status);

COMMIT;
