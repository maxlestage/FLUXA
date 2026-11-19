//! Façade du moteur FLUXA.
//!
//! [`Engine`] coordonne les modules : capacités détectées au démarrage, mesure,
//! limites, historique et base locale. Une interface écrite en Rust dépend de cette
//! seule crate : tous les types dont elle a besoin sont réexportés ici.
//!
//! L'adaptateur natif fournit les relevés (compteurs d'octets, type de réseau,
//! sondes de latence) ; le moteur calcule, enregistre et dit ce qui est réellement
//! appliqué. Une limite n'est jamais annoncée comme appliquée sans confirmation.
//!
//! ```
//! use app_core::{
//!     ApplyStatus, Engine, EngineConfig, InterfaceClass, InterfaceReading, NetworkKind,
//!     NetworkMonitor,
//! };
//!
//! # fn main() -> Result<(), app_core::NetworkError> {
//! // Base en mémoire ; sur l'appareil : `EngineConfig::ios(Some(chemin))`.
//! let engine = Engine::open(EngineConfig::ios(None))?;
//!
//! // Le système signale le réseau, puis l'app relève les compteurs chaque seconde.
//! engine.update_path(NetworkKind::Wifi, true);
//! engine.start()?;
//! let reading = |rx_bytes, tx_bytes| InterfaceReading {
//!     name: "en0".to_string(),
//!     class: InterfaceClass::Wifi,
//!     rx_bytes,
//!     tx_bytes,
//! };
//! assert_eq!(engine.ingest_counters(&[reading(0, 0)])?, None); // premier relevé : la base
//! # std::thread::sleep(std::time::Duration::from_millis(5));
//! let throughput = engine.ingest_counters(&[reading(500_000, 100_000)])?;
//! assert!(throughput.is_some());
//!
//! // Sur iOS, la limite d'un profil est enregistrée et simulée, jamais appliquée.
//! let outcome = engine.activate_profile("streaming")?;
//! assert_eq!(outcome.status, ApplyStatus::Simulated);
//! assert_eq!(outcome.effective, None);
//! # Ok(())
//! # }
//! ```

mod clock;
mod validation;

pub use clock::{Clock, ManualClock, SystemClock};

// Tout ce dont une interface a besoin, sans dépendre des autres crates du moteur.
pub use bandwidth_manager::{
    Allocation, Demand, DirectionEffect, Priority, Profile, Simulation, allocate, builtin_profiles,
};
pub use capability_manager::{CapabilityStatus, Platform, PlatformContext, Support};
pub use network_monitor::{CounterWidth, InterfaceReading};
pub use persistence::{PolicyRecord, RetentionReport, StoreStats};
pub use shared_types::{
    ApplyResult, ApplyStatus, BandwidthController, BandwidthPolicy, Capability, DeviceId,
    InterfaceClass, LimitMode, MAX_LIMIT_BPS, MIN_DURATION_SECONDS, MIN_LIMIT_BPS,
    MeasurementScope, NetworkError, NetworkKind, NetworkMonitor, NetworkSnapshot, Throughput,
    bps_to_mbps, mbps_to_bps,
};
pub use traffic_analytics::{Aggregate, Saturation, SaturationRule, Summary, usage_change};

use std::collections::VecDeque;
use std::path::PathBuf;
use std::sync::{Arc, Mutex, MutexGuard};

use bandwidth_manager::{BandwidthManager, PolicyTarget, simulate, validate, validate_profile};
use capability_manager::CapabilitySet;
use network_monitor::Monitor;
use persistence::{Granularity, POLICY_HISTORY_DAYS_KEY, Store};
use traffic_analytics::{MINUTE_MS, Sample, aggregate, detect_saturation, summarize};

const ACTIVE_PROFILE_KEY: &str = "active_profile_id";
const LATENCY_HOST_KEY: &str = "latency_host";

/// Hôte sondé par défaut pour la latence : l'adaptateur ouvre une connexion TCP
/// vers lui et mesure le temps d'établissement, sans envoyer de contenu.
pub const DEFAULT_LATENCY_HOST: &str = "www.apple.com";
const MAX_EVENTS: usize = 200;

/// Réglages de démarrage du moteur.
#[derive(Debug, Clone)]
pub struct EngineConfig {
    /// Fichier de la base locale. `None` : base en mémoire, perdue à la fermeture.
    pub database_path: Option<PathBuf>,
    pub context: PlatformContext,
    /// Largeur des compteurs d'octets que fournit l'adaptateur natif.
    pub counter_width: CounterWidth,
    /// Décalage du fuseau local par rapport à UTC, en secondes.
    pub utc_offset_seconds: i32,
}

impl EngineConfig {
    /// Les réglages de l'app iOS de la V1 : pas d'extension VPN, compteurs de
    /// 32 bits (`if_data`), heure UTC tant que l'app n'a pas donné son fuseau.
    pub fn ios(database_path: Option<PathBuf>) -> Self {
        EngineConfig {
            database_path,
            context: PlatformContext::ios(),
            counter_width: CounterWidth::Bits32,
            utc_offset_seconds: 0,
        }
    }
}

/// Finesse demandée pour une courbe d'historique.
#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub enum HistoryStep {
    Minute,
    Hour,
    Day,
}

#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub enum EventLevel {
    Info,
    Warning,
    Error,
}

/// Une ligne du journal de diagnostic. Aucune donnée de trafic n'y figure.
#[derive(Debug, Clone, PartialEq, Eq)]
pub struct Event {
    pub timestamp_ms: i64,
    pub level: EventLevel,
    pub message: String,
}

/// État du moteur, pour le centre de diagnostic.
#[derive(Debug, Clone, PartialEq, Eq)]
pub struct Diagnostics {
    pub engine_version: String,
    pub platform: String,
    pub monitoring: bool,
    pub store: StoreStats,
    /// Du plus récent au plus ancien.
    pub events: Vec<Event>,
}

/// Bilan d'un passage de maintenance.
#[derive(Debug, Clone, PartialEq, Eq, Default)]
pub struct MaintenanceReport {
    pub retention: RetentionReport,
    /// Limites retirées parce que leur durée était écoulée.
    pub expired_policies: usize,
}

struct Inner {
    capabilities: CapabilitySet,
    monitor: Monitor,
    bandwidth: BandwidthManager,
    store: Store,
    session_id: Option<i64>,
    active_profile_id: Option<String>,
    utc_offset_ms: i64,
    events: VecDeque<Event>,
}

impl Inner {
    fn log(&mut self, timestamp_ms: i64, level: EventLevel, message: impl Into<String>) {
        if self.events.len() == MAX_EVENTS {
            self.events.pop_back();
        }
        self.events.push_front(Event {
            timestamp_ms,
            level,
            message: message.into(),
        });
    }
}

/// Le moteur. Utilisable depuis plusieurs fils d'exécution.
pub struct Engine {
    clock: Arc<dyn Clock>,
    inner: Mutex<Inner>,
}

impl Engine {
    /// Démarre le moteur avec l'horloge du système.
    pub fn open(config: EngineConfig) -> Result<Self, NetworkError> {
        Self::open_with_clock(config, Arc::new(SystemClock::new()))
    }

    pub fn open_with_clock(
        config: EngineConfig,
        clock: Arc<dyn Clock>,
    ) -> Result<Self, NetworkError> {
        validation::utc_offset(config.utc_offset_seconds)?;
        let store = match &config.database_path {
            Some(path) => Store::open(path)?,
            None => Store::open_in_memory()?,
        };
        let stale = store.close_stale_sessions()?;
        let capabilities = CapabilitySet::detect(config.context);
        let mut inner = Inner {
            bandwidth: BandwidthManager::new(capabilities.clone()),
            capabilities,
            monitor: Monitor::new(config.counter_width),
            store,
            session_id: None,
            active_profile_id: None,
            utc_offset_ms: i64::from(config.utc_offset_seconds) * 1000,
            events: VecDeque::new(),
        };
        let now = clock.wall_ms();
        inner.log(now, EventLevel::Info, "Moteur démarré.");
        if stale > 0 {
            inner.log(
                now,
                EventLevel::Warning,
                format!("{stale} session(s) de mesure fermée(s) après un arrêt inattendu."),
            );
        }

        // Le profil actif est une préférence : il est rétabli, sans nouvelle ligne
        // dans le journal des règles.
        if let Some(id) = inner.store.setting(ACTIVE_PROFILE_KEY)? {
            match inner.store.profile(&id)? {
                Some(profile) => {
                    inner
                        .bandwidth
                        .apply(PolicyTarget::Global, profile.policy(), now, None)?;
                    inner.active_profile_id = Some(id);
                }
                None => inner.store.remove_setting(ACTIVE_PROFILE_KEY)?,
            }
        }
        Ok(Engine {
            clock,
            inner: Mutex::new(inner),
        })
    }

    fn lock(&self) -> MutexGuard<'_, Inner> {
        // Un fil qui a paniqué ne doit pas bloquer l'application entière.
        self.inner
            .lock()
            .unwrap_or_else(|poisoned| poisoned.into_inner())
    }

    pub fn version() -> &'static str {
        env!("CARGO_PKG_VERSION")
    }

    // ----- Capacités -----

    pub fn capabilities(&self) -> Vec<CapabilityStatus> {
        self.lock().capabilities.all().cloned().collect()
    }

    pub fn capabilities_json(&self) -> String {
        self.lock().capabilities.to_json()
    }

    // ----- Mesure -----

    pub fn is_monitoring(&self) -> bool {
        self.lock().monitor.is_running()
    }

    /// Le système signale un changement de réseau.
    pub fn update_path(&self, kind: NetworkKind, online: bool) {
        let now = self.clock.wall_ms();
        let mut inner = self.lock();
        if inner.monitor.kind() != kind {
            inner.log(now, EventLevel::Info, format!("Réseau : {}.", kind.key()));
        }
        inner.monitor.set_path(kind, online);
    }

    /// Intègre un relevé des compteurs d'octets des interfaces et enregistre la
    /// mesure qui en découle. Renvoie `None` tant qu'aucun débit n'est calculable.
    pub fn ingest_counters(
        &self,
        readings: &[InterfaceReading],
    ) -> Result<Option<Throughput>, NetworkError> {
        validation::readings(readings)?;
        let (wall_ms, monotonic_ms) = (self.clock.wall_ms(), self.clock.monotonic_ms());
        let mut inner = self.lock();
        let Some(throughput) = inner.monitor.ingest(readings, monotonic_ms) else {
            return Ok(None);
        };
        let sample = Sample {
            timestamp_ms: wall_ms,
            interval_ms: throughput.interval_ms,
            download_bps: throughput.download_bps,
            upload_bps: throughput.upload_bps,
            rx_bytes: throughput.rx_bytes,
            tx_bytes: throughput.tx_bytes,
        };
        let (session_id, kind) = (inner.session_id, inner.monitor.kind());
        if let Err(error) = inner.store.insert_sample(session_id, &sample, kind) {
            inner.log(
                wall_ms,
                EventLevel::Error,
                format!("Mesure non enregistrée : {error}."),
            );
            return Err(error);
        }
        Ok(Some(throughput))
    }

    /// Résultat d'une sonde de latence, en millisecondes. `None` : restée sans réponse.
    pub fn record_latency(&self, latency_ms: Option<f64>) -> Result<(), NetworkError> {
        let latency_ms = validation::latency(latency_ms)?;
        self.lock().monitor.record_latency(latency_ms);
        Ok(())
    }

    pub fn snapshot(&self) -> NetworkSnapshot {
        let now = self.clock.wall_ms();
        self.lock().monitor.snapshot(now)
    }

    // ----- Profils -----

    pub fn profiles(&self) -> Result<Vec<Profile>, NetworkError> {
        self.lock().store.profiles()
    }

    pub fn active_profile_id(&self) -> Option<String> {
        self.lock().active_profile_id.clone()
    }

    /// Crée un profil (`id` absent) ou modifie un profil existant.
    pub fn save_profile(
        &self,
        id: Option<&str>,
        name: &str,
        download_bps: Option<u64>,
        upload_bps: Option<u64>,
    ) -> Result<Profile, NetworkError> {
        let name = validate_profile(name, download_bps, upload_bps)?;
        let now = self.clock.wall_ms();
        let mut inner = self.lock();
        let (id, builtin) = match id {
            Some(id) => match inner.store.profile(id)? {
                Some(existing) => (existing.id, existing.builtin),
                None => return Err(NetworkError::NotFound(format!("profil {id}"))),
            },
            None => (
                format!("perso-{now}-{}", inner.store.stats()?.profiles),
                false,
            ),
        };
        let profile = Profile {
            id,
            name,
            download_bps,
            upload_bps,
            builtin,
        };
        inner.store.save_profile(&profile)?;
        // Si le profil actif vient d'être modifié, sa limite suit.
        if inner.active_profile_id.as_deref() == Some(profile.id.as_str()) {
            let result =
                inner
                    .bandwidth
                    .apply(PolicyTarget::Global, profile.policy(), now, None)?;
            inner.store.record_policy("global", &result)?;
        }
        Ok(profile)
    }

    pub fn delete_profile(&self, id: &str) -> Result<(), NetworkError> {
        let mut inner = self.lock();
        inner.store.delete_profile(id)?;
        if inner.active_profile_id.as_deref() == Some(id) {
            inner.active_profile_id = None;
            inner.store.remove_setting(ACTIVE_PROFILE_KEY)?;
            inner.bandwidth.clear(&PolicyTarget::Global);
        }
        Ok(())
    }

    /// Choisit le profil actif et rend compte de ce qu'il advient de sa limite.
    pub fn activate_profile(&self, id: &str) -> Result<ApplyResult, NetworkError> {
        let now = self.clock.wall_ms();
        let mut inner = self.lock();
        let profile = inner
            .store
            .profile(id)?
            .ok_or_else(|| NetworkError::NotFound(format!("profil {id}")))?;
        let result = Self::apply(&mut inner, PolicyTarget::Global, profile.policy(), now)?;
        inner.store.set_setting(ACTIVE_PROFILE_KEY, id)?;
        inner.active_profile_id = Some(id.to_string());
        Ok(result)
    }

    // ----- Limites -----

    fn apply(
        inner: &mut Inner,
        target: PolicyTarget,
        policy: BandwidthPolicy,
        now: i64,
    ) -> Result<ApplyResult, NetworkError> {
        let target_key = match &target {
            PolicyTarget::Global => "global".to_string(),
            PolicyTarget::Device(id) => format!("device:{}", id.as_str()),
        };
        // La V1 iOS n'a aucun adaptateur de contrôle : rien ne peut être confirmé.
        let result = inner.bandwidth.apply(target, policy, now, None)?;
        inner.store.record_policy(&target_key, &result)?;
        inner.log(
            now,
            EventLevel::Info,
            format!("Limite {target_key} : {}.", result.status.key()),
        );
        Ok(result)
    }

    /// La limite globale enregistrée et son statut, s'il y en a une.
    pub fn global_limit(&self) -> Option<ApplyResult> {
        self.lock()
            .bandwidth
            .global()
            .map(|applied| applied.result.clone())
    }

    /// Retire la limite globale et le profil actif.
    pub fn clear_global_limit(&self) -> Result<(), NetworkError> {
        let mut inner = self.lock();
        inner.bandwidth.clear(&PolicyTarget::Global);
        inner.active_profile_id = None;
        inner.store.remove_setting(ACTIVE_PROFILE_KEY)
    }

    /// Simule une limite sur le dernier débit mesuré. `None` sans mesure.
    pub fn simulate(&self, policy: &BandwidthPolicy) -> Result<Option<Simulation>, NetworkError> {
        validate(policy, false)?;
        Ok(self
            .lock()
            .monitor
            .last_throughput()
            .map(|measured| simulate(policy, measured.download_bps, measured.upload_bps)))
    }

    /// Les dernières limites enregistrées (500 au plus), de la plus récente à la
    /// plus ancienne, chacune avec son statut réel.
    pub fn policy_history(&self, limit: u32) -> Result<Vec<PolicyRecord>, NetworkError> {
        self.lock().store.policy_history(limit.clamp(1, 500))
    }

    // ----- Historique -----

    /// Courbe d'historique entre `from_ms` inclus et `to_ms` exclu.
    pub fn history(
        &self,
        from_ms: i64,
        to_ms: i64,
        step: HistoryStep,
    ) -> Result<Vec<Aggregate>, NetworkError> {
        validation::period(from_ms, to_ms, step)?;
        let now = self.clock.wall_ms();
        let mut inner = self.lock();
        let offset = inner.utc_offset_ms;
        match step {
            HistoryStep::Minute => {
                let samples = inner.store.samples_between(from_ms, to_ms)?;
                Ok(aggregate(&samples, MINUTE_MS, offset))
            }
            HistoryStep::Hour | HistoryStep::Day => {
                inner.store.rollup(now, offset)?;
                let granularity = if step == HistoryStep::Hour {
                    Granularity::Hour
                } else {
                    Granularity::Day
                };
                inner.store.usage_between(granularity, from_ms, to_ms)
            }
        }
    }

    /// Bilan de consommation des heures commençant entre `from_ms` et `to_ms`.
    pub fn usage(&self, from_ms: i64, to_ms: i64) -> Result<Summary, NetworkError> {
        Ok(summarize(&self.history(
            from_ms,
            to_ms,
            HistoryStep::Hour,
        )?))
    }

    /// Épisodes pendant lesquels le débit descendant est resté proche de
    /// `capacity_bps` (au moins 90 % pendant dix secondes), sur sept jours au plus.
    pub fn saturation_episodes(
        &self,
        from_ms: i64,
        to_ms: i64,
        capacity_bps: u64,
    ) -> Result<Vec<Saturation>, NetworkError> {
        validation::period(from_ms, to_ms, HistoryStep::Minute)?;
        let samples = self.lock().store.samples_between(from_ms, to_ms)?;
        Ok(detect_saturation(
            &samples,
            SaturationRule::for_capacity(capacity_bps),
        ))
    }

    /// Met à jour les agrégats, applique les durées de conservation et retire les
    /// limites arrivées à échéance. À appeler régulièrement.
    pub fn run_maintenance(&self) -> Result<MaintenanceReport, NetworkError> {
        let now = self.clock.wall_ms();
        let mut inner = self.lock();
        let offset = inner.utc_offset_ms;
        inner.store.rollup(now, offset)?;
        let retention = inner.store.apply_retention(now)?;
        let expired = inner.bandwidth.expire(now);
        if expired
            .iter()
            .any(|applied| applied.configured.target == PolicyTarget::Global)
        {
            inner.active_profile_id = None;
            inner.store.remove_setting(ACTIVE_PROFILE_KEY)?;
        }
        if retention != RetentionReport::default() {
            inner.log(
                now,
                EventLevel::Info,
                format!(
                    "Purge : {} mesures, {} agrégats horaires, {} journaliers.",
                    retention.samples, retention.hourly, retention.daily
                ),
            );
        }
        Ok(MaintenanceReport {
            retention,
            expired_policies: expired.len(),
        })
    }

    /// Change le décalage du fuseau local (voyage, heure d'été).
    pub fn set_utc_offset_seconds(&self, seconds: i32) -> Result<(), NetworkError> {
        let seconds = validation::utc_offset(seconds)?;
        self.lock().utc_offset_ms = i64::from(seconds) * 1000;
        Ok(())
    }

    // ----- Préférences -----

    /// Hôte que l'adaptateur sonde pour la latence.
    pub fn latency_host(&self) -> Result<String, NetworkError> {
        Ok(self
            .lock()
            .store
            .setting(LATENCY_HOST_KEY)?
            .unwrap_or_else(|| DEFAULT_LATENCY_HOST.to_string()))
    }

    /// Change l'hôte sondé. Renvoie le nom retenu, nettoyé.
    pub fn set_latency_host(&self, host: &str) -> Result<String, NetworkError> {
        let host = validation::host(host)?;
        self.lock().store.set_setting(LATENCY_HOST_KEY, &host)?;
        Ok(host)
    }

    /// Durée de conservation de l'historique des limites, en jours. `None` : sans limite.
    pub fn policy_history_days(&self) -> Result<Option<u32>, NetworkError> {
        Ok(self
            .lock()
            .store
            .setting(POLICY_HISTORY_DAYS_KEY)?
            .and_then(|days| days.parse().ok())
            .filter(|days| *days > 0))
    }

    pub fn set_policy_history_days(&self, days: Option<u32>) -> Result<(), NetworkError> {
        match validation::history_days(days)? {
            Some(days) => self
                .lock()
                .store
                .set_setting(POLICY_HISTORY_DAYS_KEY, &days.to_string()),
            None => self.lock().store.remove_setting(POLICY_HISTORY_DAYS_KEY),
        }
    }

    // ----- Suppression et diagnostic -----

    /// Efface tout l'historique. Les profils et les préférences restent.
    pub fn erase_history(&self) -> Result<(), NetworkError> {
        let now = self.clock.wall_ms();
        let mut inner = self.lock();
        inner.store.erase_history()?;
        inner.events.clear();
        inner.log(now, EventLevel::Info, "Historique effacé.");
        // La session en cours a disparu avec le reste : une nouvelle prend la suite.
        if inner.monitor.is_running() {
            let kind = inner.monitor.kind();
            inner.session_id = Some(inner.store.start_session(now, kind)?);
        }
        Ok(())
    }

    /// Efface toutes les données et rétablit les préréglages d'origine.
    pub fn erase_all(&self) -> Result<(), NetworkError> {
        let now = self.clock.wall_ms();
        let mut inner = self.lock();
        inner.store.erase_all()?;
        inner.bandwidth = BandwidthManager::new(inner.capabilities.clone());
        inner.active_profile_id = None;
        inner.events.clear();
        inner.log(
            now,
            EventLevel::Info,
            "Toutes les données ont été effacées.",
        );
        if inner.monitor.is_running() {
            let kind = inner.monitor.kind();
            inner.session_id = Some(inner.store.start_session(now, kind)?);
        }
        Ok(())
    }

    pub fn diagnostics(&self) -> Result<Diagnostics, NetworkError> {
        let inner = self.lock();
        Ok(Diagnostics {
            engine_version: Self::version().to_string(),
            platform: inner.capabilities.platform().key().to_string(),
            monitoring: inner.monitor.is_running(),
            store: inner.store.stats()?,
            events: inner.events.iter().cloned().collect(),
        })
    }
}

impl NetworkMonitor for Engine {
    fn start(&self) -> Result<(), NetworkError> {
        let now = self.clock.wall_ms();
        let mut inner = self.lock();
        if inner.monitor.is_running() {
            return Ok(());
        }
        let kind = inner.monitor.kind();
        inner.session_id = Some(inner.store.start_session(now, kind)?);
        inner.monitor.start();
        inner.log(now, EventLevel::Info, "Surveillance démarrée.");
        Ok(())
    }

    fn stop(&self) -> Result<(), NetworkError> {
        let now = self.clock.wall_ms();
        let mut inner = self.lock();
        if !inner.monitor.is_running() {
            return Ok(());
        }
        inner.monitor.stop();
        if let Some(session_id) = inner.session_id.take() {
            inner.store.end_session(session_id, now)?;
        }
        inner.log(now, EventLevel::Info, "Surveillance arrêtée.");
        Ok(())
    }

    fn get_snapshot(&self) -> Result<NetworkSnapshot, NetworkError> {
        Ok(self.snapshot())
    }
}

impl BandwidthController for Engine {
    fn set_global_limit(&self, policy: BandwidthPolicy) -> Result<ApplyResult, NetworkError> {
        let now = self.clock.wall_ms();
        let mut inner = self.lock();
        let result = Self::apply(&mut inner, PolicyTarget::Global, policy, now)?;
        // Une limite réglée à la main remplace le profil actif.
        inner.active_profile_id = None;
        inner.store.remove_setting(ACTIVE_PROFILE_KEY)?;
        Ok(result)
    }

    fn set_device_limit(
        &self,
        device_id: DeviceId,
        policy: BandwidthPolicy,
    ) -> Result<ApplyResult, NetworkError> {
        let now = self.clock.wall_ms();
        let mut inner = self.lock();
        Self::apply(&mut inner, PolicyTarget::Device(device_id), policy, now)
    }
}

#[cfg(test)]
mod tests;
