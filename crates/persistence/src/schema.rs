//! Schéma de la base et migrations.

use rusqlite::Connection;

/// Version courante du schéma, stockée dans `PRAGMA user_version`.
pub const CURRENT_VERSION: i64 = 1;

const V1: &str = "
CREATE TABLE network_sessions (
    id            INTEGER PRIMARY KEY,
    started_at_ms INTEGER NOT NULL,
    ended_at_ms   INTEGER,
    network_kind  TEXT    NOT NULL
);

CREATE TABLE network_samples (
    timestamp_ms INTEGER NOT NULL,
    session_id   INTEGER REFERENCES network_sessions(id) ON DELETE SET NULL,
    interval_ms  INTEGER NOT NULL,
    download_bps INTEGER NOT NULL,
    upload_bps   INTEGER NOT NULL,
    rx_bytes     INTEGER NOT NULL,
    tx_bytes     INTEGER NOT NULL,
    network_kind TEXT    NOT NULL
);
CREATE INDEX network_samples_by_time ON network_samples(timestamp_ms);
CREATE INDEX network_samples_by_session ON network_samples(session_id);

CREATE TABLE usage_records (
    granularity       TEXT    NOT NULL CHECK (granularity IN ('hour', 'day')),
    bucket_start_ms   INTEGER NOT NULL,
    samples           INTEGER NOT NULL,
    measured_ms       INTEGER NOT NULL,
    avg_download_bps  INTEGER NOT NULL,
    avg_upload_bps    INTEGER NOT NULL,
    peak_download_bps INTEGER NOT NULL,
    peak_upload_bps   INTEGER NOT NULL,
    rx_bytes          INTEGER NOT NULL,
    tx_bytes          INTEGER NOT NULL,
    PRIMARY KEY (granularity, bucket_start_ms)
) WITHOUT ROWID;

CREATE TABLE bandwidth_profiles (
    id           TEXT    PRIMARY KEY,
    name         TEXT    NOT NULL,
    download_bps INTEGER,
    upload_bps   INTEGER,
    builtin      INTEGER NOT NULL DEFAULT 0,
    position     INTEGER NOT NULL
);

CREATE TABLE bandwidth_policies (
    id               INTEGER PRIMARY KEY,
    target           TEXT    NOT NULL,
    download_bps     INTEGER,
    upload_bps       INTEGER,
    mode             TEXT    NOT NULL,
    duration_seconds INTEGER,
    configured_at_ms INTEGER NOT NULL
);

CREATE TABLE policy_applications (
    id                     INTEGER PRIMARY KEY,
    policy_id              INTEGER NOT NULL REFERENCES bandwidth_policies(id) ON DELETE CASCADE,
    status                 TEXT    NOT NULL CHECK (status IN ('applied', 'partial', 'simulated', 'unsupported')),
    has_effective          INTEGER NOT NULL DEFAULT 0,
    effective_download_bps INTEGER,
    effective_upload_bps   INTEGER,
    reason                 TEXT,
    capability             TEXT    NOT NULL,
    decided_at_ms          INTEGER NOT NULL
);
CREATE INDEX policy_applications_by_policy ON policy_applications(policy_id);

CREATE TABLE app_settings (
    key   TEXT PRIMARY KEY,
    value TEXT NOT NULL
) WITHOUT ROWID;
";

pub fn version(connection: &Connection) -> rusqlite::Result<i64> {
    connection.query_row("PRAGMA user_version", [], |row| row.get(0))
}

/// Amène la base à la version courante. Sans effet si elle y est déjà.
pub fn migrate(connection: &mut Connection) -> rusqlite::Result<()> {
    let current = version(connection)?;
    if current < 1 {
        let transaction = connection.transaction()?;
        transaction.execute_batch(V1)?;
        transaction.pragma_update(None, "user_version", CURRENT_VERSION)?;
        transaction.commit()?;
    }
    Ok(())
}
