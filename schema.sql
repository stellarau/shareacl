-- ShareACL schema v0.1
PRAGMA journal_mode = WAL;
PRAGMA synchronous = NORMAL;

-- One row per scan run
CREATE TABLE IF NOT EXISTS scans (
    scan_id          INTEGER PRIMARY KEY AUTOINCREMENT,
    started_utc      TEXT    NOT NULL,
    completed_utc    TEXT,
    root_paths_json  TEXT    NOT NULL,
    host             TEXT,
    operator         TEXT,
    status           TEXT    NOT NULL CHECK (status IN ('running','completed','failed','aborted')),
    folder_count     INTEGER NOT NULL DEFAULT 0,
    ace_count        INTEGER NOT NULL DEFAULT 0,
    error_count      INTEGER NOT NULL DEFAULT 0,
    notes            TEXT
);

-- One row per folder visited
CREATE TABLE IF NOT EXISTS folders (
    folder_id            INTEGER PRIMARY KEY AUTOINCREMENT,
    scan_id              INTEGER NOT NULL REFERENCES scans(scan_id),
    path                 TEXT    NOT NULL,
    parent_id            INTEGER REFERENCES folders(folder_id),
    depth                INTEGER NOT NULL,
    owner_sid            TEXT,
    inheritance_enabled  INTEGER NOT NULL,         -- 0 = broken, 1 = inherits
    is_reparse_point     INTEGER NOT NULL DEFAULT 0,
    explicit_ace_count   INTEGER NOT NULL DEFAULT 0,
    scan_error           TEXT,
    visited_utc          TEXT    NOT NULL
);
CREATE INDEX IF NOT EXISTS ix_folders_scan        ON folders(scan_id);
CREATE INDEX IF NOT EXISTS ix_folders_scan_path   ON folders(scan_id, path);
CREATE INDEX IF NOT EXISTS ix_folders_broken      ON folders(scan_id, inheritance_enabled);

-- One row per ACE on each folder
CREATE TABLE IF NOT EXISTS aces (
    ace_id              INTEGER PRIMARY KEY AUTOINCREMENT,
    folder_id           INTEGER NOT NULL REFERENCES folders(folder_id),
    trustee_sid         TEXT    NOT NULL,
    access_control_type TEXT    NOT NULL CHECK (access_control_type IN ('Allow','Deny')),
    rights_text         TEXT    NOT NULL,
    rights_mask         INTEGER NOT NULL,
    inheritance_flags   TEXT    NOT NULL,
    propagation_flags   TEXT    NOT NULL,
    is_inherited        INTEGER NOT NULL,
    inherited_from      TEXT
);
CREATE INDEX IF NOT EXISTS ix_aces_folder   ON aces(folder_id);
CREATE INDEX IF NOT EXISTS ix_aces_trustee  ON aces(trustee_sid);

-- Cached SID -> identity resolution (shared across scans)
CREATE TABLE IF NOT EXISTS principals (
    sid                TEXT PRIMARY KEY,
    name               TEXT,
    domain             TEXT,
    sam_account_name   TEXT,
    principal_type     TEXT NOT NULL CHECK (principal_type IN
                          ('User','Group','Computer','WellKnown','ForeignSecurityPrincipal','Orphaned','Unknown')),
    is_well_known      INTEGER NOT NULL DEFAULT 0,
    last_resolved_utc  TEXT NOT NULL
);

-- Transitive group membership: one row per (group, transitive member, shortest depth)
CREATE TABLE IF NOT EXISTS group_members (
    group_sid    TEXT    NOT NULL REFERENCES principals(sid),
    member_sid   TEXT    NOT NULL REFERENCES principals(sid),
    depth        INTEGER NOT NULL,    -- 1 = direct member, 2 = nested once, ...
    PRIMARY KEY (group_sid, member_sid)
);
CREATE INDEX IF NOT EXISTS ix_gm_member ON group_members(member_sid);

-- Resume queue: folders discovered but not yet processed
CREATE TABLE IF NOT EXISTS folders_pending (
    scan_id    INTEGER NOT NULL REFERENCES scans(scan_id),
    path       TEXT    NOT NULL,
    parent_id  INTEGER,
    depth      INTEGER NOT NULL,
    PRIMARY KEY (scan_id, path)
);

-- Errors worth surfacing in the viewer
CREATE TABLE IF NOT EXISTS scan_errors (
    error_id    INTEGER PRIMARY KEY AUTOINCREMENT,
    scan_id     INTEGER NOT NULL REFERENCES scans(scan_id),
    path        TEXT,
    phase       TEXT NOT NULL,   -- 'enumerate','acl','owner','resolve'
    message     TEXT NOT NULL,
    logged_utc  TEXT NOT NULL
);
CREATE INDEX IF NOT EXISTS ix_errors_scan ON scan_errors(scan_id);