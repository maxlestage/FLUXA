//! Capacités du système : ce que le moteur a réellement le droit de faire.
//!
//! L'interface n'affiche une fonction comme disponible que si ce module la
//! déclare prise en charge. Sur iOS, le partage de connexion appartient au
//! système : aucune application ordinaire ne peut l'activer, lister ses
//! clients ou plafonner son trafic.

use std::collections::BTreeMap;

use serde::{Deserialize, Serialize};
use shared_types::Capability;

/// Plateforme sur laquelle tourne le moteur.
#[derive(Debug, Clone, Copy, PartialEq, Eq, Hash, Serialize, Deserialize)]
#[serde(rename_all = "snake_case")]
pub enum Platform {
    Ios,
    /// Hôte sans intégration native (tests, outils) : rien n'est pris en charge.
    Unknown,
}

impl Platform {
    pub const fn key(self) -> &'static str {
        match self {
            Platform::Ios => "ios",
            Platform::Unknown => "unknown",
        }
    }
}

/// Ce que l'adaptateur natif sait du contexte d'exécution.
#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub struct PlatformContext {
    pub platform: Platform,
    /// L'application embarque une extension réseau (Packet Tunnel) et son droit d'usage.
    pub vpn_extension_present: bool,
    /// L'utilisateur a accepté la configuration VPN proposée par l'application.
    pub vpn_permission_granted: bool,
}

impl PlatformContext {
    /// iOS sans extension réseau : le cas de la V1.
    pub const fn ios() -> Self {
        PlatformContext {
            platform: Platform::Ios,
            vpn_extension_present: false,
            vpn_permission_granted: false,
        }
    }

    pub const fn unknown() -> Self {
        PlatformContext {
            platform: Platform::Unknown,
            vpn_extension_present: false,
            vpn_permission_granted: false,
        }
    }
}

/// Niveau de prise en charge d'une capacité.
#[derive(Debug, Clone, Copy, PartialEq, Eq, Hash, Serialize, Deserialize)]
#[serde(rename_all = "snake_case")]
pub enum Support {
    /// Utilisable maintenant.
    Supported,
    /// Possible, mais une condition reste à remplir (un accord de l'utilisateur, par exemple).
    Conditional,
    /// Impossible dans ce contexte.
    Unsupported,
}

/// Une capacité, son niveau et l'explication à montrer à l'utilisateur.
#[derive(Debug, Clone, PartialEq, Eq, Serialize, Deserialize)]
pub struct CapabilityStatus {
    pub capability: Capability,
    pub support: Support,
    pub reason: String,
}

/// L'ensemble des capacités détectées pour un contexte.
#[derive(Debug, Clone, PartialEq, Eq)]
pub struct CapabilitySet {
    platform: Platform,
    entries: BTreeMap<Capability, CapabilityStatus>,
}

impl CapabilitySet {
    /// Détecte les capacités du contexte donné.
    pub fn detect(context: PlatformContext) -> Self {
        let entries = Capability::ALL
            .into_iter()
            .map(|capability| {
                let (support, reason) = assess(context, capability);
                (
                    capability,
                    CapabilityStatus {
                        capability,
                        support,
                        reason: reason.to_string(),
                    },
                )
            })
            .collect();
        CapabilitySet {
            platform: context.platform,
            entries,
        }
    }

    pub fn platform(&self) -> Platform {
        self.platform
    }

    pub fn status(&self, capability: Capability) -> &CapabilityStatus {
        // `detect` renseigne chaque capacité de `Capability::ALL`.
        &self.entries[&capability]
    }

    pub fn support(&self, capability: Capability) -> Support {
        self.status(capability).support
    }

    /// Vrai seulement si la capacité est utilisable maintenant.
    pub fn is_supported(&self, capability: Capability) -> bool {
        self.support(capability) == Support::Supported
    }

    pub fn all(&self) -> impl Iterator<Item = &CapabilityStatus> {
        self.entries.values()
    }

    /// Le JSON du cahier des charges : une capacité vaut `true` seulement si
    /// elle est utilisable maintenant.
    pub fn to_json(&self) -> String {
        let capabilities: serde_json::Map<String, serde_json::Value> = self
            .entries
            .values()
            .map(|status| {
                (
                    status.capability.key().to_string(),
                    serde_json::Value::Bool(status.support == Support::Supported),
                )
            })
            .collect();
        let document = serde_json::json!({
            "platform": self.platform.key(),
            "capabilities": capabilities,
        });
        serde_json::to_string_pretty(&document).unwrap_or_default()
    }
}

fn assess(context: PlatformContext, capability: Capability) -> (Support, &'static str) {
    match context.platform {
        Platform::Ios => assess_ios(context, capability),
        Platform::Unknown => (
            Support::Unsupported,
            "Aucune intégration native sur cette plateforme.",
        ),
    }
}

fn assess_ios(context: PlatformContext, capability: Capability) -> (Support, &'static str) {
    match capability {
        Capability::InternetMonitoring => (
            Support::Supported,
            "Compteurs des interfaces et état du réseau fournis par iOS.",
        ),
        Capability::HotspotActivation => (
            Support::Unsupported,
            "iOS réserve l'activation du partage de connexion à l'utilisateur, dans Réglages.",
        ),
        Capability::HotspotClientDiscovery => (
            Support::Unsupported,
            "iOS ne fournit pas la liste des appareils reliés au partage de connexion.",
        ),
        Capability::HotspotShaping => (
            Support::Unsupported,
            "iOS ne laisse aucune application agir sur le trafic du partage de connexion.",
        ),
        Capability::PerDeviceShaping => (
            Support::Unsupported,
            "iOS ne laisse aucune application limiter un appareil relié au partage.",
        ),
        Capability::LocalVpn => {
            if !context.vpn_extension_present {
                (
                    Support::Unsupported,
                    "Cette version de l'application n'embarque pas d'extension VPN.",
                )
            } else if !context.vpn_permission_granted {
                (
                    Support::Conditional,
                    "Le VPN local demande votre accord. Il ne traite que le trafic de l'iPhone.",
                )
            } else {
                (
                    Support::Supported,
                    "VPN local autorisé. Il ne traite que le trafic de l'iPhone, pas celui du partage.",
                )
            }
        }
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn ios_never_controls_the_hotspot() {
        // Quel que soit l'état du VPN, le partage de connexion reste hors de portée.
        for (extension, permission) in [(false, false), (true, false), (true, true)] {
            let set = CapabilitySet::detect(PlatformContext {
                platform: Platform::Ios,
                vpn_extension_present: extension,
                vpn_permission_granted: permission,
            });
            assert!(set.is_supported(Capability::InternetMonitoring));
            for capability in [
                Capability::HotspotActivation,
                Capability::HotspotClientDiscovery,
                Capability::HotspotShaping,
                Capability::PerDeviceShaping,
            ] {
                assert_eq!(
                    set.support(capability),
                    Support::Unsupported,
                    "{capability:?}"
                );
                assert!(!set.status(capability).reason.is_empty());
            }
        }
    }

    #[test]
    fn local_vpn_depends_on_extension_and_consent() {
        let support = |extension, permission| {
            CapabilitySet::detect(PlatformContext {
                platform: Platform::Ios,
                vpn_extension_present: extension,
                vpn_permission_granted: permission,
            })
            .support(Capability::LocalVpn)
        };
        assert_eq!(support(false, false), Support::Unsupported);
        // Un accord sans extension ne rend rien possible.
        assert_eq!(support(false, true), Support::Unsupported);
        assert_eq!(support(true, false), Support::Conditional);
        assert_eq!(support(true, true), Support::Supported);
    }

    #[test]
    fn unknown_platform_supports_nothing() {
        let set = CapabilitySet::detect(PlatformContext::unknown());
        assert!(
            set.all()
                .all(|status| status.support == Support::Unsupported)
        );
        assert_eq!(set.all().count(), Capability::ALL.len());
    }

    #[test]
    fn json_marks_only_usable_capabilities_as_true() {
        let set = CapabilitySet::detect(PlatformContext {
            platform: Platform::Ios,
            vpn_extension_present: true,
            vpn_permission_granted: false,
        });
        let json: serde_json::Value = serde_json::from_str(&set.to_json()).unwrap();
        assert_eq!(json["platform"], "ios");
        assert_eq!(json["capabilities"]["internet_monitoring"], true);
        assert_eq!(json["capabilities"]["hotspot_activation"], false);
        assert_eq!(json["capabilities"]["hotspot_client_discovery"], false);
        assert_eq!(json["capabilities"]["per_device_shaping"], false);
        // « Sous conditions » n'est pas « utilisable maintenant ».
        assert_eq!(json["capabilities"]["local_vpn"], false);
        assert_eq!(
            json["capabilities"].as_object().unwrap().len(),
            Capability::ALL.len()
        );
    }
}
