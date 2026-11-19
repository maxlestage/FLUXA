//! Profils de connexion : des préréglages modifiables, pas des débits garantis.

use serde::{Deserialize, Serialize};
use shared_types::{BandwidthPolicy, LimitMode, MAX_LIMIT_BPS, MIN_LIMIT_BPS, NetworkError};

/// Un profil. `None` : sans plafond configuré dans ce sens.
#[derive(Debug, Clone, PartialEq, Eq, Serialize, Deserialize)]
pub struct Profile {
    pub id: String,
    pub name: String,
    pub download_bps: Option<u64>,
    pub upload_bps: Option<u64>,
    /// Préréglage fourni avec l'application.
    pub builtin: bool,
}

impl Profile {
    /// La limite que ce profil demande : un plafond strict, sans limite de durée.
    pub fn policy(&self) -> BandwidthPolicy {
        BandwidthPolicy {
            download_bps: self.download_bps,
            upload_bps: self.upload_bps,
            mode: LimitMode::HardLimit,
            duration_seconds: None,
        }
    }
}

/// Les sept préréglages de la V1.
pub fn builtin_profiles() -> Vec<Profile> {
    const MBPS: u64 = 1_000_000;
    let preset = |id: &str, name: &str, down: Option<u64>, up: Option<u64>| Profile {
        id: id.to_string(),
        name: name.to_string(),
        download_bps: down,
        upload_bps: up,
        builtin: true,
    };
    vec![
        preset("economie", "Économie", Some(MBPS), Some(MBPS / 2)),
        preset("tres-lent", "Très lent", Some(2 * MBPS), Some(MBPS)),
        preset("navigation", "Navigation", Some(5 * MBPS), Some(2 * MBPS)),
        preset("standard", "Standard", Some(15 * MBPS), Some(5 * MBPS)),
        preset("streaming", "Streaming", Some(25 * MBPS), Some(10 * MBPS)),
        preset(
            "performance",
            "Performance",
            Some(50 * MBPS),
            Some(20 * MBPS),
        ),
        preset("maximum", "Maximum", None, None),
    ]
}

/// Vérifie le nom et les plafonds d'un profil. Renvoie le nom nettoyé.
pub fn validate_profile(
    name: &str,
    download_bps: Option<u64>,
    upload_bps: Option<u64>,
) -> Result<String, NetworkError> {
    let name = name.trim();
    if name.is_empty() || name.chars().count() > 40 || name.chars().any(char::is_control) {
        return Err(NetworkError::InvalidInput(
            "le nom du profil doit faire de 1 à 40 caractères".to_string(),
        ));
    }
    for limit in [download_bps, upload_bps].into_iter().flatten() {
        if !(MIN_LIMIT_BPS..=MAX_LIMIT_BPS).contains(&limit) {
            return Err(NetworkError::InvalidPolicy(
                "plafond hors de la plage 0,1 à 1 000 Mb/s".to_string(),
            ));
        }
    }
    Ok(name.to_string())
}

#[cfg(test)]
mod tests {
    use super::*;
    use crate::validate;

    #[test]
    fn ships_the_seven_presets_of_the_specification() {
        let profiles = builtin_profiles();
        let table: Vec<(&str, Option<u64>, Option<u64>)> = profiles
            .iter()
            .map(|p| (p.name.as_str(), p.download_bps, p.upload_bps))
            .collect();
        assert_eq!(
            table,
            vec![
                ("Économie", Some(1_000_000), Some(500_000)),
                ("Très lent", Some(2_000_000), Some(1_000_000)),
                ("Navigation", Some(5_000_000), Some(2_000_000)),
                ("Standard", Some(15_000_000), Some(5_000_000)),
                ("Streaming", Some(25_000_000), Some(10_000_000)),
                ("Performance", Some(50_000_000), Some(20_000_000)),
                ("Maximum", None, None),
            ]
        );
        assert!(profiles.iter().all(|p| p.builtin));
    }

    #[test]
    fn every_preset_is_a_valid_policy_with_a_unique_id() {
        let profiles = builtin_profiles();
        for profile in &profiles {
            assert!(
                validate(&profile.policy(), false).is_ok(),
                "{}",
                profile.name
            );
        }
        let mut ids: Vec<_> = profiles.iter().map(|p| p.id.as_str()).collect();
        ids.sort_unstable();
        ids.dedup();
        assert_eq!(ids.len(), 7);
    }

    #[test]
    fn validates_custom_profiles() {
        assert_eq!(
            validate_profile("  Visio  ", Some(8_000_000), None).unwrap(),
            "Visio"
        );
        assert!(validate_profile("", Some(8_000_000), None).is_err());
        assert!(validate_profile("   ", None, None).is_err());
        assert!(validate_profile(&"a".repeat(41), None, None).is_err());
        assert!(validate_profile("Nom\navec saut", None, None).is_err());
        assert!(validate_profile("Trop bas", Some(99_999), None).is_err());
        assert!(validate_profile("Trop haut", None, Some(1_000_000_001)).is_err());
    }
}
