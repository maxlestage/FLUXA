//! Types partagés par tous les modules du moteur.
//!
//! Les débits sont toujours exprimés en bits par seconde, les instants en
//! millisecondes depuis l'époque Unix. Aucune fonction ici ne touche au système.

use serde::{Deserialize, Serialize};
use thiserror::Error;

/// Plus petit plafond réglable : 0,1 Mb/s.
pub const MIN_LIMIT_BPS: u64 = 100_000;
/// Plus grand plafond réglable : 1 000 Mb/s.
pub const MAX_LIMIT_BPS: u64 = 1_000_000_000;
/// Plus courte durée de limitation : une minute.
pub const MIN_DURATION_SECONDS: u64 = 60;

/// Convertit des Mb/s en bit/s, arrondi au bit.
pub fn mbps_to_bps(mbps: f64) -> u64 {
    if !mbps.is_finite() || mbps <= 0.0 {
        return 0;
    }
    (mbps * 1_000_000.0).round() as u64
}

/// Convertit des bit/s en Mb/s.
pub fn bps_to_mbps(bps: u64) -> f64 {
    bps as f64 / 1_000_000.0
}

/// Façon d'interpréter un plafond.
#[derive(Debug, Clone, Copy, PartialEq, Eq, Hash, Serialize, Deserialize)]
#[serde(rename_all = "snake_case")]
pub enum LimitMode {
    /// Débit maximum strict.
    HardLimit,
    /// Débit cible, dépassable quand de la bande passante est disponible.
    SoftLimit,
    /// Partage équitable entre appareils.
    FairShare,
    /// Répartition selon les priorités.
    Priority,
}

/// Une limite de débit demandée. `None` signifie « sans plafond configuré ».
#[derive(Debug, Clone, Copy, PartialEq, Eq, Serialize, Deserialize)]
pub struct BandwidthPolicy {
    pub download_bps: Option<u64>,
    pub upload_bps: Option<u64>,
    pub mode: LimitMode,
    /// `None` : sans limite de durée.
    pub duration_seconds: Option<u64>,
}

impl BandwidthPolicy {
    /// Politique sans aucun plafond.
    pub const fn unlimited() -> Self {
        BandwidthPolicy {
            download_bps: None,
            upload_bps: None,
            mode: LimitMode::HardLimit,
            duration_seconds: None,
        }
    }

    /// Plafond strict dans les deux sens, sans limite de durée.
    pub const fn hard(download_bps: u64, upload_bps: u64) -> Self {
        BandwidthPolicy {
            download_bps: Some(download_bps),
            upload_bps: Some(upload_bps),
            mode: LimitMode::HardLimit,
            duration_seconds: None,
        }
    }
}

/// Fonction du système dont dépend une opération.
#[derive(Debug, Clone, Copy, PartialEq, Eq, Hash, PartialOrd, Ord, Serialize, Deserialize)]
#[serde(rename_all = "snake_case")]
pub enum Capability {
    /// Mesurer la connexion du téléphone.
    InternetMonitoring,
    /// Activer ou couper le partage de connexion.
    HotspotActivation,
    /// Lister les appareils reliés au partage.
    HotspotClientDiscovery,
    /// Plafonner le trafic transféré par le partage, tous appareils confondus.
    HotspotShaping,
    /// Plafonner le trafic d'un appareil relié au partage.
    PerDeviceShaping,
    /// Créer un VPN local qui traite le trafic du téléphone.
    LocalVpn,
}

impl Capability {
    pub const ALL: [Capability; 6] = [
        Capability::InternetMonitoring,
        Capability::HotspotActivation,
        Capability::HotspotClientDiscovery,
        Capability::HotspotShaping,
        Capability::PerDeviceShaping,
        Capability::LocalVpn,
    ];

    /// Nom stable, utilisé dans le JSON des capacités et dans la base.
    pub const fn key(self) -> &'static str {
        match self {
            Capability::InternetMonitoring => "internet_monitoring",
            Capability::HotspotActivation => "hotspot_activation",
            Capability::HotspotClientDiscovery => "hotspot_client_discovery",
            Capability::HotspotShaping => "hotspot_shaping",
            Capability::PerDeviceShaping => "per_device_shaping",
            Capability::LocalVpn => "local_vpn",
        }
    }
}

/// Ce qu'il est advenu d'une règle demandée.
#[derive(Debug, Clone, Copy, PartialEq, Eq, Hash, Serialize, Deserialize)]
#[serde(rename_all = "snake_case")]
pub enum ApplyStatus {
    /// Le système a confirmé l'application de la règle telle que demandée.
    Applied,
    /// Le système a confirmé une règle différente de celle demandée.
    Partial,
    /// La règle est enregistrée et son effet est calculé, sans agir sur le trafic.
    Simulated,
    /// La règle est enregistrée, mais ni appliquée ni simulable.
    Unsupported,
}

impl ApplyStatus {
    pub const fn key(self) -> &'static str {
        match self {
            ApplyStatus::Applied => "applied",
            ApplyStatus::Partial => "partial",
            ApplyStatus::Simulated => "simulated",
            ApplyStatus::Unsupported => "unsupported",
        }
    }

    pub fn from_key(key: &str) -> Option<Self> {
        match key {
            "applied" => Some(ApplyStatus::Applied),
            "partial" => Some(ApplyStatus::Partial),
            "simulated" => Some(ApplyStatus::Simulated),
            "unsupported" => Some(ApplyStatus::Unsupported),
            _ => None,
        }
    }

    /// Vrai seulement quand le système agit réellement sur le trafic.
    pub const fn is_effective(self) -> bool {
        matches!(self, ApplyStatus::Applied | ApplyStatus::Partial)
    }
}

/// Réponse à une demande d'application : ce qui était demandé, ce qui est réel.
#[derive(Debug, Clone, PartialEq, Eq, Serialize, Deserialize)]
pub struct ApplyResult {
    pub requested: BandwidthPolicy,
    /// La règle réellement en vigueur, confirmée par l'adaptateur. `None` sinon.
    pub effective: Option<BandwidthPolicy>,
    pub status: ApplyStatus,
    /// Motif du refus ou de l'écart, en clair.
    pub reason: Option<String>,
    /// La capacité système dont dépendait la demande.
    pub capability: Capability,
    pub decided_at_ms: i64,
}

/// Identifiant local d'un appareil : 1 à 64 caractères parmi `a-z A-Z 0-9 _ -`.
#[derive(Debug, Clone, PartialEq, Eq, Hash, PartialOrd, Ord, Serialize, Deserialize)]
pub struct DeviceId(String);

impl DeviceId {
    pub fn new(raw: &str) -> Result<Self, NetworkError> {
        let valid = (1..=64).contains(&raw.len())
            && raw
                .bytes()
                .all(|b| b.is_ascii_alphanumeric() || b == b'_' || b == b'-');
        if valid {
            Ok(DeviceId(raw.to_string()))
        } else {
            Err(NetworkError::InvalidDeviceId)
        }
    }

    pub fn as_str(&self) -> &str {
        &self.0
    }
}

/// Type de réseau actif, tel que le système le rapporte.
#[derive(Debug, Clone, Copy, PartialEq, Eq, Hash, Serialize, Deserialize)]
#[serde(rename_all = "snake_case")]
pub enum NetworkKind {
    Wifi,
    Cellular4G,
    Cellular5G,
    /// Réseau mobile dont la génération n'est pas connue.
    Cellular,
    Wired,
    Other,
    /// Aucun réseau.
    None,
}

impl NetworkKind {
    pub const fn key(self) -> &'static str {
        match self {
            NetworkKind::Wifi => "wifi",
            NetworkKind::Cellular4G => "cellular_4g",
            NetworkKind::Cellular5G => "cellular_5g",
            NetworkKind::Cellular => "cellular",
            NetworkKind::Wired => "wired",
            NetworkKind::Other => "other",
            NetworkKind::None => "none",
        }
    }

    pub const fn is_cellular(self) -> bool {
        matches!(
            self,
            NetworkKind::Cellular | NetworkKind::Cellular4G | NetworkKind::Cellular5G
        )
    }
}

/// Famille d'une interface réseau, déterminée par l'adaptateur natif.
#[derive(Debug, Clone, Copy, PartialEq, Eq, Hash, Serialize, Deserialize)]
#[serde(rename_all = "snake_case")]
pub enum InterfaceClass {
    Wifi,
    Cellular,
    Wired,
    Other,
}

/// Périmètre de ce qu'un débit mesure réellement.
#[derive(Debug, Clone, Copy, PartialEq, Eq, Hash, Serialize, Deserialize)]
#[serde(rename_all = "snake_case")]
pub enum MeasurementScope {
    /// Tout le trafic passé par les interfaces du téléphone de la famille indiquée.
    DeviceInterfaces(InterfaceClass),
    /// Le seul trafic passé par un tunnel VPN local.
    Tunnel,
}

/// Débits calculés entre deux relevés de compteurs.
#[derive(Debug, Clone, Copy, PartialEq, Eq, Serialize, Deserialize)]
pub struct Throughput {
    pub download_bps: u64,
    pub upload_bps: u64,
    /// Octets reçus et émis pendant l'intervalle.
    pub rx_bytes: u64,
    pub tx_bytes: u64,
    pub interval_ms: u64,
    pub scope: MeasurementScope,
}

/// État du réseau à un instant donné. Une mesure absente reste `None`.
#[derive(Debug, Clone, Copy, PartialEq, Serialize, Deserialize)]
pub struct NetworkSnapshot {
    pub timestamp_ms: i64,
    pub monitoring: bool,
    pub kind: NetworkKind,
    pub online: bool,
    pub throughput: Option<Throughput>,
    pub latency_ms: Option<f64>,
    pub jitter_ms: Option<f64>,
    /// Part des sondes de latence restées sans réponse, entre 0 et 1.
    pub loss_ratio: Option<f64>,
}

/// Erreurs du moteur.
#[derive(Debug, Clone, PartialEq, Eq, Error)]
pub enum NetworkError {
    #[error("politique invalide : {0}")]
    InvalidPolicy(String),
    #[error("identifiant d'appareil invalide")]
    InvalidDeviceId,
    #[error("entrée invalide : {0}")]
    InvalidInput(String),
    #[error("élément introuvable : {0}")]
    NotFound(String),
    #[error("la surveillance n'est pas démarrée")]
    NotMonitoring,
    #[error("stockage : {0}")]
    Storage(String),
}

/// Contrat de surveillance entre le moteur et les interfaces natives.
pub trait NetworkMonitor {
    fn start(&self) -> Result<(), NetworkError>;
    fn stop(&self) -> Result<(), NetworkError>;
    fn get_snapshot(&self) -> Result<NetworkSnapshot, NetworkError>;
}

/// Contrat de limitation. La réponse dit toujours ce qui est réellement advenu.
pub trait BandwidthController {
    fn set_global_limit(&self, policy: BandwidthPolicy) -> Result<ApplyResult, NetworkError>;
    fn set_device_limit(
        &self,
        device_id: DeviceId,
        policy: BandwidthPolicy,
    ) -> Result<ApplyResult, NetworkError>;
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn converts_units() {
        assert_eq!(mbps_to_bps(0.1), MIN_LIMIT_BPS);
        assert_eq!(mbps_to_bps(1000.0), MAX_LIMIT_BPS);
        assert_eq!(mbps_to_bps(42.8), 42_800_000);
        assert_eq!(mbps_to_bps(f64::NAN), 0);
        assert_eq!(mbps_to_bps(-3.0), 0);
        assert!((bps_to_mbps(8_400_000) - 8.4).abs() < 1e-9);
    }

    #[test]
    fn validates_device_ids() {
        assert_eq!(DeviceId::new("device_001").unwrap().as_str(), "device_001");
        assert!(DeviceId::new("").is_err());
        assert!(DeviceId::new("a b").is_err());
        assert!(DeviceId::new("é").is_err());
        assert!(DeviceId::new(&"x".repeat(65)).is_err());
        assert!(DeviceId::new(&"x".repeat(64)).is_ok());
    }

    #[test]
    fn status_keys_round_trip() {
        for status in [
            ApplyStatus::Applied,
            ApplyStatus::Partial,
            ApplyStatus::Simulated,
            ApplyStatus::Unsupported,
        ] {
            assert_eq!(ApplyStatus::from_key(status.key()), Some(status));
        }
        assert_eq!(ApplyStatus::from_key("done"), None);
        assert!(ApplyStatus::Applied.is_effective());
        assert!(!ApplyStatus::Simulated.is_effective());
        assert!(!ApplyStatus::Unsupported.is_effective());
    }

    #[test]
    fn capability_keys_are_unique() {
        let mut keys: Vec<_> = Capability::ALL.iter().map(|c| c.key()).collect();
        keys.sort_unstable();
        keys.dedup();
        assert_eq!(keys.len(), Capability::ALL.len());
    }
}
