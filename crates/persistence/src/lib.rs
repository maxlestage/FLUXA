//! Base locale SQLite. Tout reste sur l'appareil.
//!
//! Conservation : mesures détaillées 7 jours, agrégats horaires 30 jours,
//! agrégats journaliers 12 mois. L'historique des règles suit une durée réglable.

mod schema;

use std::path::Path;

use bandwidth_manager::{Profile, builtin_profiles};
use rusqlite::{Connection, OptionalExtension, params};
use shared_types::{
    ApplyResult, ApplyStatus, BandwidthPolicy, LimitMode, NetworkError, NetworkKind,
};
use traffic_analytics::{Aggregate, DAY_MS, HOUR_MS, Sample, aggregate, bucket_start, merge};

/// Durée de conservation des mesures détaillées.
pub const SAMPLE_RETENTION_MS: i64 = 7 * DAY_MS;
/// Durée de conservation des agrégats horaires.
pub const HOURLY_RETENTION_MS: i64 = 30 * DAY_MS;
/// Durée de conservation des agrégats journaliers : 12 mois.
pub const DAILY_RETENTION_MS: i64 = 365 * DAY_MS;

const WATERMARK_KEY: &str = "rollup_watermark_ms";
/// Préférence : nombre de jours de conservation de l'historique des règles.
pub const POLICY_HISTORY_DAYS_KEY: &str = "policy_history_days";

/// Finesse d'un agrégat stocké.
#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub enum Granularity {
    Hour,
    Day,
}

impl Granularity {
    const fn key(self) -> &'static str {
        match self {
            Granularity::Hour => "hour",
            Granularity::Day => "day",
        }
    }

    const fn bucket_ms(self) -> i64 {
        match self {
            Granularity::Hour => HOUR_MS,
            Granularity::Day => DAY_MS,
        }
    }
}

/// Une règle enregistrée et ce qu'il en est advenu.
#[derive(Debug, Clone, PartialEq, Eq)]
pub struct PolicyRecord {
    pub id: i64,
    /// `global` ou `device:<identifiant>`.
    pub target: String,
    pub result: ApplyResult,
}

/// Ce que la purge a supprimé.
#[derive(Debug, Clone, Copy, PartialEq, Eq, Default)]
pub struct RetentionReport {
    pub samples: usize,
    pub hourly: usize,
    pub daily: usize,
    pub sessions: usize,
    pub policies: usize,
}

/// Ce que la base contient.
#[derive(Debug, Clone, Copy, PartialEq, Eq, Default)]
pub struct StoreStats {
    pub schema_version: i64,
    pub samples: u64,
    pub oldest_sample_ms: Option<i64>,
    pub hourly_records: u64,
    pub daily_records: u64,
    pub sessions: u64,
    pub policies: u64,
    pub profiles: u64,
}

fn storage(error: rusqlite::Error) -> NetworkError {
    NetworkError::Storage(error.to_string())
}

fn to_i64(value: u64) -> i64 {
    i64::try_from(value).unwrap_or(i64::MAX)
}

fn to_u64(value: i64) -> u64 {
    u64::try_from(value).unwrap_or(0)
}

fn mode_key(mode: LimitMode) -> &'static str {
    match mode {
        LimitMode::HardLimit => "hard_limit",
        LimitMode::SoftLimit => "soft_limit",
        LimitMode::FairShare => "fair_share",
        LimitMode::Priority => "priority",
    }
}

fn mode_from_key(key: &str) -> LimitMode {
    match key {
        "soft_limit" => LimitMode::SoftLimit,
        "fair_share" => LimitMode::FairShare,
        "priority" => LimitMode::Priority,
        _ => LimitMode::HardLimit,
    }
}

fn capability_from_key(key: &str) -> shared_types::Capability {
    shared_types::Capability::ALL
        .into_iter()
        .find(|capability| capability.key() == key)
        .unwrap_or(shared_types::Capability::HotspotShaping)
}

/// La base locale.
#[derive(Debug)]
pub struct Store {
    connection: Connection,
}

impl Store {
    /// Ouvre (ou crée) la base au chemin donné.
    pub fn open(path: &Path) -> Result<Self, NetworkError> {
        Self::prepare(Connection::open(path).map_err(storage)?)
    }

    /// Base en mémoire, pour les tests et les aperçus.
    pub fn open_in_memory() -> Result<Self, NetworkError> {
        Self::prepare(Connection::open_in_memory().map_err(storage)?)
    }

    fn prepare(connection: Connection) -> Result<Self, NetworkError> {
        // Une ligne supprimée est écrasée : « effacer » efface vraiment.
        connection
            .execute_batch("PRAGMA foreign_keys = ON; PRAGMA secure_delete = ON;")
            .map_err(storage)?;
        // Le mode WAL renvoie une ligne : il se lit comme une requête.
        let _: String = connection
            .query_row("PRAGMA journal_mode = WAL", [], |row| row.get(0))
            .map_err(storage)?;
        let mut store = Store { connection };
        schema::migrate(&mut store.connection).map_err(storage)?;
        store.seed_builtin_profiles()?;
        Ok(store)
    }

    fn seed_builtin_profiles(&self) -> Result<(), NetworkError> {
        for (position, profile) in builtin_profiles().iter().enumerate() {
            self.connection
                .execute(
                    "INSERT OR IGNORE INTO bandwidth_profiles
                         (id, name, download_bps, upload_bps, builtin, position)
                     VALUES (?1, ?2, ?3, ?4, 1, ?5)",
                    params![
                        profile.id,
                        profile.name,
                        profile.download_bps.map(to_i64),
                        profile.upload_bps.map(to_i64),
                        position as i64
                    ],
                )
                .map_err(storage)?;
        }
        Ok(())
    }

    // ----- Sessions et mesures -----

    /// Ouvre une session de mesure. Renvoie son identifiant.
    pub fn start_session(&self, now_ms: i64, kind: NetworkKind) -> Result<i64, NetworkError> {
        self.connection
            .execute(
                "INSERT INTO network_sessions (started_at_ms, network_kind) VALUES (?1, ?2)",
                params![now_ms, kind.key()],
            )
            .map_err(storage)?;
        Ok(self.connection.last_insert_rowid())
    }

    pub fn end_session(&self, session_id: i64, now_ms: i64) -> Result<(), NetworkError> {
        self.connection
            .execute(
                "UPDATE network_sessions SET ended_at_ms = ?2 WHERE id = ?1 AND ended_at_ms IS NULL",
                params![session_id, now_ms],
            )
            .map_err(storage)?;
        Ok(())
    }

    /// Ferme les sessions restées ouvertes après un arrêt brutal, à la date de leur
    /// dernière mesure (ou de leur début, faute de mesure).
    pub fn close_stale_sessions(&self) -> Result<usize, NetworkError> {
        self.connection
            .execute(
                "UPDATE network_sessions SET ended_at_ms = COALESCE(
                     (SELECT MAX(timestamp_ms) FROM network_samples WHERE session_id = network_sessions.id),
                     started_at_ms)
                 WHERE ended_at_ms IS NULL",
                [],
            )
            .map_err(storage)
    }

    pub fn insert_sample(
        &self,
        session_id: Option<i64>,
        sample: &Sample,
        kind: NetworkKind,
    ) -> Result<(), NetworkError> {
        self.connection
            .execute(
                "INSERT INTO network_samples
                     (timestamp_ms, session_id, interval_ms, download_bps, upload_bps, rx_bytes, tx_bytes, network_kind)
                 VALUES (?1, ?2, ?3, ?4, ?5, ?6, ?7, ?8)",
                params![
                    sample.timestamp_ms,
                    session_id,
                    to_i64(sample.interval_ms),
                    to_i64(sample.download_bps),
                    to_i64(sample.upload_bps),
                    to_i64(sample.rx_bytes),
                    to_i64(sample.tx_bytes),
                    kind.key()
                ],
            )
            .map_err(storage)?;
        Ok(())
    }

    /// Mesures de `from_ms` inclus à `to_ms` exclu, triées par date.
    pub fn samples_between(&self, from_ms: i64, to_ms: i64) -> Result<Vec<Sample>, NetworkError> {
        let mut statement = self
            .connection
            .prepare_cached(
                "SELECT timestamp_ms, interval_ms, download_bps, upload_bps, rx_bytes, tx_bytes
                 FROM network_samples WHERE timestamp_ms >= ?1 AND timestamp_ms < ?2
                 ORDER BY timestamp_ms",
            )
            .map_err(storage)?;
        let rows = statement
            .query_map(params![from_ms, to_ms], |row| {
                Ok(Sample {
                    timestamp_ms: row.get(0)?,
                    interval_ms: to_u64(row.get(1)?),
                    download_bps: to_u64(row.get(2)?),
                    upload_bps: to_u64(row.get(3)?),
                    rx_bytes: to_u64(row.get(4)?),
                    tx_bytes: to_u64(row.get(5)?),
                })
            })
            .map_err(storage)?;
        rows.collect::<Result<_, _>>().map_err(storage)
    }

    // ----- Agrégats -----

    fn upsert_usage(
        &self,
        granularity: Granularity,
        aggregates: &[Aggregate],
    ) -> Result<(), NetworkError> {
        let mut statement = self
            .connection
            .prepare_cached(
                "INSERT OR REPLACE INTO usage_records
                     (granularity, bucket_start_ms, samples, measured_ms, avg_download_bps, avg_upload_bps,
                      peak_download_bps, peak_upload_bps, rx_bytes, tx_bytes)
                 VALUES (?1, ?2, ?3, ?4, ?5, ?6, ?7, ?8, ?9, ?10)",
            )
            .map_err(storage)?;
        for a in aggregates {
            statement
                .execute(params![
                    granularity.key(),
                    a.bucket_start_ms,
                    i64::from(a.samples),
                    to_i64(a.measured_ms),
                    to_i64(a.avg_download_bps),
                    to_i64(a.avg_upload_bps),
                    to_i64(a.peak_download_bps),
                    to_i64(a.peak_upload_bps),
                    to_i64(a.rx_bytes),
                    to_i64(a.tx_bytes)
                ])
                .map_err(storage)?;
        }
        Ok(())
    }

    /// Agrégats dont le début est entre `from_ms` inclus et `to_ms` exclu.
    pub fn usage_between(
        &self,
        granularity: Granularity,
        from_ms: i64,
        to_ms: i64,
    ) -> Result<Vec<Aggregate>, NetworkError> {
        let mut statement = self
            .connection
            .prepare_cached(
                "SELECT bucket_start_ms, samples, measured_ms, avg_download_bps, avg_upload_bps,
                        peak_download_bps, peak_upload_bps, rx_bytes, tx_bytes
                 FROM usage_records
                 WHERE granularity = ?1 AND bucket_start_ms >= ?2 AND bucket_start_ms < ?3
                 ORDER BY bucket_start_ms",
            )
            .map_err(storage)?;
        let rows = statement
            .query_map(params![granularity.key(), from_ms, to_ms], |row| {
                Ok(Aggregate {
                    bucket_start_ms: row.get(0)?,
                    bucket_ms: granularity.bucket_ms(),
                    samples: u32::try_from(row.get::<_, i64>(1)?).unwrap_or(u32::MAX),
                    measured_ms: to_u64(row.get(2)?),
                    avg_download_bps: to_u64(row.get(3)?),
                    avg_upload_bps: to_u64(row.get(4)?),
                    peak_download_bps: to_u64(row.get(5)?),
                    peak_upload_bps: to_u64(row.get(6)?),
                    rx_bytes: to_u64(row.get(7)?),
                    tx_bytes: to_u64(row.get(8)?),
                })
            })
            .map_err(storage)?;
        rows.collect::<Result<_, _>>().map_err(storage)
    }

    /// Met à jour les agrégats horaires et journaliers à partir des mesures arrivées
    /// depuis le dernier passage. À appeler avant la purge.
    ///
    /// `offset_ms` : décalage du fuseau local, pour que les jours commencent à minuit local.
    pub fn rollup(&mut self, now_ms: i64, offset_ms: i64) -> Result<(), NetworkError> {
        let watermark = match self
            .setting(WATERMARK_KEY)?
            .and_then(|v| v.parse::<i64>().ok())
        {
            Some(watermark) => watermark,
            None => match self.oldest_sample_ms()? {
                Some(oldest) => oldest,
                None => return Ok(()),
            },
        };
        let from_hour = bucket_start(watermark, HOUR_MS, offset_ms);
        let samples = self.samples_between(from_hour, now_ms.saturating_add(1))?;
        let hourly = aggregate(&samples, HOUR_MS, offset_ms);

        self.upsert_usage(Granularity::Hour, &hourly)?;

        let from_day = bucket_start(from_hour, DAY_MS, offset_ms);
        let hours = self.usage_between(Granularity::Hour, from_day, now_ms.saturating_add(1))?;
        self.upsert_usage(Granularity::Day, &merge(&hours, DAY_MS, offset_ms))?;

        // Le prochain passage repart de l'heure en cours : les jours anciens, dont
        // les heures finissent par être purgées, ne sont jamais recalculés.
        self.set_setting(WATERMARK_KEY, &now_ms.to_string())
    }

    /// Supprime ce qui dépasse les durées de conservation.
    pub fn apply_retention(&self, now_ms: i64) -> Result<RetentionReport, NetworkError> {
        let delete = |sql: &str, limit: i64| {
            self.connection
                .execute(sql, params![limit])
                .map_err(storage)
        };
        let samples = delete(
            "DELETE FROM network_samples WHERE timestamp_ms < ?1",
            now_ms - SAMPLE_RETENTION_MS,
        )?;
        let hourly = delete(
            "DELETE FROM usage_records WHERE granularity = 'hour' AND bucket_start_ms < ?1",
            now_ms - HOURLY_RETENTION_MS,
        )?;
        let daily = delete(
            "DELETE FROM usage_records WHERE granularity = 'day' AND bucket_start_ms < ?1",
            now_ms - DAILY_RETENTION_MS,
        )?;
        // Une session terminée n'a plus d'intérêt quand ses mesures ont disparu.
        let sessions = delete(
            "DELETE FROM network_sessions WHERE ended_at_ms IS NOT NULL AND ended_at_ms < ?1",
            now_ms - SAMPLE_RETENTION_MS,
        )?;
        let policies = match self
            .setting(POLICY_HISTORY_DAYS_KEY)?
            .and_then(|days| days.parse::<i64>().ok())
            .filter(|days| *days > 0)
        {
            Some(days) => delete(
                "DELETE FROM bandwidth_policies WHERE configured_at_ms < ?1",
                now_ms.saturating_sub(days.saturating_mul(DAY_MS)),
            )?,
            None => 0,
        };
        Ok(RetentionReport {
            samples,
            hourly,
            daily,
            sessions,
            policies,
        })
    }

    fn oldest_sample_ms(&self) -> Result<Option<i64>, NetworkError> {
        self.connection
            .query_row("SELECT MIN(timestamp_ms) FROM network_samples", [], |row| {
                row.get(0)
            })
            .map_err(storage)
    }

    // ----- Profils -----

    pub fn profiles(&self) -> Result<Vec<Profile>, NetworkError> {
        let mut statement = self
            .connection
            .prepare_cached(
                "SELECT id, name, download_bps, upload_bps, builtin FROM bandwidth_profiles
                 ORDER BY position, name",
            )
            .map_err(storage)?;
        let rows = statement
            .query_map([], |row| {
                Ok(Profile {
                    id: row.get(0)?,
                    name: row.get(1)?,
                    download_bps: row.get::<_, Option<i64>>(2)?.map(to_u64),
                    upload_bps: row.get::<_, Option<i64>>(3)?.map(to_u64),
                    builtin: row.get::<_, i64>(4)? != 0,
                })
            })
            .map_err(storage)?;
        rows.collect::<Result<_, _>>().map_err(storage)
    }

    pub fn profile(&self, id: &str) -> Result<Option<Profile>, NetworkError> {
        Ok(self
            .profiles()?
            .into_iter()
            .find(|profile| profile.id == id))
    }

    /// Crée un profil ou modifie le nom et les plafonds d'un profil existant.
    /// Un préréglage modifié reste un préréglage.
    pub fn save_profile(&self, profile: &Profile) -> Result<(), NetworkError> {
        let position: i64 = self
            .connection
            .query_row(
                "SELECT COALESCE(MAX(position), -1) + 1 FROM bandwidth_profiles",
                [],
                |row| row.get(0),
            )
            .map_err(storage)?;
        self.connection
            .execute(
                "INSERT INTO bandwidth_profiles (id, name, download_bps, upload_bps, builtin, position)
                 VALUES (?1, ?2, ?3, ?4, 0, ?5)
                 ON CONFLICT(id) DO UPDATE SET
                     name = excluded.name,
                     download_bps = excluded.download_bps,
                     upload_bps = excluded.upload_bps",
                params![
                    profile.id,
                    profile.name,
                    profile.download_bps.map(to_i64),
                    profile.upload_bps.map(to_i64),
                    position
                ],
            )
            .map_err(storage)?;
        Ok(())
    }

    /// Supprime un profil personnel. Un préréglage ne se supprime pas.
    pub fn delete_profile(&self, id: &str) -> Result<(), NetworkError> {
        match self.profile(id)? {
            None => Err(NetworkError::NotFound(format!("profil {id}"))),
            Some(profile) if profile.builtin => Err(NetworkError::InvalidInput(
                "un préréglage ne peut pas être supprimé".to_string(),
            )),
            Some(_) => {
                self.connection
                    .execute("DELETE FROM bandwidth_profiles WHERE id = ?1", params![id])
                    .map_err(storage)?;
                Ok(())
            }
        }
    }

    /// Rend aux préréglages leurs valeurs d'origine.
    pub fn reset_builtin_profiles(&self) -> Result<(), NetworkError> {
        self.connection
            .execute("DELETE FROM bandwidth_profiles WHERE builtin = 1", [])
            .map_err(storage)?;
        self.seed_builtin_profiles()
    }

    // ----- Règles et résultats d'application -----

    /// Enregistre une règle configurée et le résultat de sa demande d'application.
    pub fn record_policy(
        &mut self,
        target: &str,
        result: &ApplyResult,
    ) -> Result<i64, NetworkError> {
        let transaction = self.connection.transaction().map_err(storage)?;
        let requested = result.requested;
        transaction
            .execute(
                "INSERT INTO bandwidth_policies
                     (target, download_bps, upload_bps, mode, duration_seconds, configured_at_ms)
                 VALUES (?1, ?2, ?3, ?4, ?5, ?6)",
                params![
                    target,
                    requested.download_bps.map(to_i64),
                    requested.upload_bps.map(to_i64),
                    mode_key(requested.mode),
                    requested.duration_seconds.map(to_i64),
                    result.decided_at_ms
                ],
            )
            .map_err(storage)?;
        let policy_id = transaction.last_insert_rowid();
        let effective = result.effective;
        transaction
            .execute(
                "INSERT INTO policy_applications
                     (policy_id, status, has_effective, effective_download_bps, effective_upload_bps,
                      reason, capability, decided_at_ms)
                 VALUES (?1, ?2, ?3, ?4, ?5, ?6, ?7, ?8)",
                params![
                    policy_id,
                    result.status.key(),
                    effective.is_some(),
                    effective.and_then(|p| p.download_bps).map(to_i64),
                    effective.and_then(|p| p.upload_bps).map(to_i64),
                    result.reason,
                    result.capability.key(),
                    result.decided_at_ms
                ],
            )
            .map_err(storage)?;
        transaction.commit().map_err(storage)?;
        Ok(policy_id)
    }

    /// Les dernières règles enregistrées, de la plus récente à la plus ancienne.
    pub fn policy_history(&self, limit: u32) -> Result<Vec<PolicyRecord>, NetworkError> {
        let mut statement = self
            .connection
            .prepare_cached(
                "SELECT p.id, p.target, p.download_bps, p.upload_bps, p.mode, p.duration_seconds,
                        a.status, a.has_effective, a.effective_download_bps, a.effective_upload_bps,
                        a.reason, a.capability, a.decided_at_ms
                 FROM bandwidth_policies p JOIN policy_applications a ON a.policy_id = p.id
                 ORDER BY a.decided_at_ms DESC, p.id DESC LIMIT ?1",
            )
            .map_err(storage)?;
        let rows = statement
            .query_map(params![i64::from(limit)], |row| {
                let mode = mode_from_key(&row.get::<_, String>(4)?);
                let duration_seconds = row.get::<_, Option<i64>>(5)?.map(to_u64);
                let requested = BandwidthPolicy {
                    download_bps: row.get::<_, Option<i64>>(2)?.map(to_u64),
                    upload_bps: row.get::<_, Option<i64>>(3)?.map(to_u64),
                    mode,
                    duration_seconds,
                };
                let effective = row.get::<_, bool>(7)?.then_some(BandwidthPolicy {
                    download_bps: row.get::<_, Option<i64>>(8)?.map(to_u64),
                    upload_bps: row.get::<_, Option<i64>>(9)?.map(to_u64),
                    mode,
                    duration_seconds,
                });
                let status = ApplyStatus::from_key(&row.get::<_, String>(6)?)
                    .unwrap_or(ApplyStatus::Unsupported);
                Ok(PolicyRecord {
                    id: row.get(0)?,
                    target: row.get(1)?,
                    result: ApplyResult {
                        requested,
                        effective,
                        status,
                        reason: row.get(10)?,
                        capability: capability_from_key(&row.get::<_, String>(11)?),
                        decided_at_ms: row.get(12)?,
                    },
                })
            })
            .map_err(storage)?;
        rows.collect::<Result<_, _>>().map_err(storage)
    }

    // ----- Préférences -----

    pub fn setting(&self, key: &str) -> Result<Option<String>, NetworkError> {
        self.connection
            .query_row(
                "SELECT value FROM app_settings WHERE key = ?1",
                params![key],
                |row| row.get(0),
            )
            .optional()
            .map_err(storage)
    }

    pub fn set_setting(&self, key: &str, value: &str) -> Result<(), NetworkError> {
        self.connection
            .execute(
                "INSERT INTO app_settings (key, value) VALUES (?1, ?2)
                 ON CONFLICT(key) DO UPDATE SET value = excluded.value",
                params![key, value],
            )
            .map_err(storage)?;
        Ok(())
    }

    pub fn remove_setting(&self, key: &str) -> Result<(), NetworkError> {
        self.connection
            .execute("DELETE FROM app_settings WHERE key = ?1", params![key])
            .map_err(storage)?;
        Ok(())
    }

    // ----- Suppression -----

    /// Efface tout l'historique : mesures, sessions, agrégats, règles et résultats.
    /// Les profils et les préférences restent.
    pub fn erase_history(&mut self) -> Result<(), NetworkError> {
        self.connection
            .execute_batch(
                "BEGIN;
                 DELETE FROM network_samples;
                 DELETE FROM network_sessions;
                 DELETE FROM usage_records;
                 DELETE FROM policy_applications;
                 DELETE FROM bandwidth_policies;
                 DELETE FROM app_settings WHERE key = 'rollup_watermark_ms';
                 COMMIT;",
            )
            .map_err(storage)?;
        self.compact()
    }

    /// Efface toutes les données : l'historique, les profils personnels et les
    /// préférences. Les préréglages reviennent à leurs valeurs d'origine.
    pub fn erase_all(&mut self) -> Result<(), NetworkError> {
        self.erase_history()?;
        self.connection
            .execute_batch("DELETE FROM bandwidth_profiles; DELETE FROM app_settings;")
            .map_err(storage)?;
        self.seed_builtin_profiles()?;
        self.compact()
    }

    /// Rend au système l'espace libéré, pour que rien ne subsiste dans le fichier.
    fn compact(&self) -> Result<(), NetworkError> {
        self.connection
            .execute_batch("PRAGMA wal_checkpoint(TRUNCATE); VACUUM;")
            .map_err(storage)
    }

    pub fn stats(&self) -> Result<StoreStats, NetworkError> {
        let count = |sql: &str| -> Result<u64, NetworkError> {
            self.connection
                .query_row(sql, [], |row| row.get::<_, i64>(0))
                .map(to_u64)
                .map_err(storage)
        };
        Ok(StoreStats {
            schema_version: schema::version(&self.connection).map_err(storage)?,
            samples: count("SELECT COUNT(*) FROM network_samples")?,
            oldest_sample_ms: self.oldest_sample_ms()?,
            hourly_records: count("SELECT COUNT(*) FROM usage_records WHERE granularity = 'hour'")?,
            daily_records: count("SELECT COUNT(*) FROM usage_records WHERE granularity = 'day'")?,
            sessions: count("SELECT COUNT(*) FROM network_sessions")?,
            policies: count("SELECT COUNT(*) FROM bandwidth_policies")?,
            profiles: count("SELECT COUNT(*) FROM bandwidth_profiles")?,
        })
    }
}

#[cfg(test)]
mod tests;
