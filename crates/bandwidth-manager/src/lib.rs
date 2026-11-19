//! Gestion des limites de débit.
//!
//! Règle fondamentale : une limite n'est jamais annoncée comme appliquée tant
//! que l'adaptateur natif n'a pas confirmé son application. Ce module garde donc
//! séparément ce qui est configuré ([`ConfiguredPolicy`]) et ce qu'il en est
//! réellement advenu ([`AppliedPolicy`]).

mod allocation;
mod profiles;
mod simulation;

pub use allocation::{Allocation, Demand, Priority, allocate};
pub use profiles::{Profile, builtin_profiles, validate_profile};
pub use simulation::{DirectionEffect, Simulation, simulate};

use std::collections::BTreeMap;

use capability_manager::CapabilitySet;
use shared_types::{
    ApplyResult, ApplyStatus, BandwidthPolicy, Capability, DeviceId, MAX_LIMIT_BPS,
    MIN_DURATION_SECONDS, MIN_LIMIT_BPS, NetworkError,
};

/// Ce qu'une limite vise.
#[derive(Debug, Clone, PartialEq, Eq, PartialOrd, Ord)]
pub enum PolicyTarget {
    /// Tout le trafic du partage de connexion.
    Global,
    /// Un appareil relié au partage.
    Device(DeviceId),
}

impl PolicyTarget {
    /// La capacité système nécessaire pour agir réellement sur cette cible.
    pub const fn capability(&self) -> Capability {
        match self {
            PolicyTarget::Global => Capability::HotspotShaping,
            PolicyTarget::Device(_) => Capability::PerDeviceShaping,
        }
    }
}

/// Une limite telle que l'utilisateur l'a réglée. Ne dit rien de son application.
#[derive(Debug, Clone, PartialEq, Eq)]
pub struct ConfiguredPolicy {
    pub target: PolicyTarget,
    pub policy: BandwidthPolicy,
    pub configured_at_ms: i64,
}

/// Une limite configurée et la réponse obtenue lors de la demande d'application.
#[derive(Debug, Clone, PartialEq, Eq)]
pub struct AppliedPolicy {
    pub configured: ConfiguredPolicy,
    pub result: ApplyResult,
}

impl AppliedPolicy {
    /// Vrai quand la durée demandée est écoulée.
    pub fn is_expired(&self, now_ms: i64) -> bool {
        match self.configured.policy.duration_seconds {
            None => false,
            Some(seconds) => {
                let end = self.configured.configured_at_ms.saturating_add(
                    i64::try_from(seconds)
                        .unwrap_or(i64::MAX)
                        .saturating_mul(1000),
                );
                now_ms >= end
            }
        }
    }
}

/// Réponse de l'adaptateur natif à une demande d'application.
#[derive(Debug, Clone, PartialEq, Eq)]
pub enum AdapterReply {
    /// Le système applique cette règle (qui peut différer de celle demandée).
    Confirmed(BandwidthPolicy),
    /// Le système a refusé.
    Refused(String),
}

/// L'adaptateur natif capable d'agir sur le trafic, quand la plateforme en a un.
pub trait ControlAdapter {
    fn apply(&self, target: &PolicyTarget, policy: &BandwidthPolicy) -> AdapterReply;
}

/// Vérifie une limite avant tout enregistrement.
///
/// `can_block` : le moteur a réellement la capacité de couper le flux visé. Sans
/// elle, un plafond à zéro (une suspension) est refusé.
pub fn validate(policy: &BandwidthPolicy, can_block: bool) -> Result<(), NetworkError> {
    for (label, limit) in [
        ("descendant", policy.download_bps),
        ("montant", policy.upload_bps),
    ] {
        match limit {
            None => {}
            Some(0) if can_block => {}
            Some(0) => {
                return Err(NetworkError::InvalidPolicy(format!(
                    "plafond {label} à zéro : la suspension n'est pas prise en charge ici"
                )));
            }
            Some(bps) if (MIN_LIMIT_BPS..=MAX_LIMIT_BPS).contains(&bps) => {}
            Some(_) => {
                return Err(NetworkError::InvalidPolicy(format!(
                    "plafond {label} hors de la plage 0,1 à 1 000 Mb/s"
                )));
            }
        }
    }
    match policy.duration_seconds {
        Some(seconds) if seconds < MIN_DURATION_SECONDS => Err(NetworkError::InvalidPolicy(
            "durée inférieure à une minute".to_string(),
        )),
        _ => Ok(()),
    }
}

/// Enregistre les limites et demande leur application quand c'est possible.
#[derive(Debug)]
pub struct BandwidthManager {
    capabilities: CapabilitySet,
    global: Option<AppliedPolicy>,
    devices: BTreeMap<DeviceId, AppliedPolicy>,
}

impl BandwidthManager {
    pub fn new(capabilities: CapabilitySet) -> Self {
        BandwidthManager {
            capabilities,
            global: None,
            devices: BTreeMap::new(),
        }
    }

    pub fn capabilities(&self) -> &CapabilitySet {
        &self.capabilities
    }

    /// Enregistre une limite et rend compte de ce qu'il en advient réellement.
    ///
    /// - Capacité absente, cible globale : la limite est gardée et simulée.
    /// - Capacité absente, cible « appareil » : la limite est gardée, sans effet
    ///   ni simulation (le trafic de l'appareil n'est pas observable).
    /// - Capacité présente : seule la confirmation de l'adaptateur donne le
    ///   statut « appliqué » ou « partiel ».
    pub fn apply(
        &mut self,
        target: PolicyTarget,
        policy: BandwidthPolicy,
        now_ms: i64,
        adapter: Option<&dyn ControlAdapter>,
    ) -> Result<ApplyResult, NetworkError> {
        let capability = target.capability();
        let supported = self.capabilities.is_supported(capability);
        validate(&policy, supported)?;

        let unsupported_reason = self.capabilities.status(capability).reason.clone();
        let reply = if supported {
            adapter.map(|adapter| adapter.apply(&target, &policy))
        } else {
            None
        };
        let (status, effective, reason) =
            decide(supported, &target, &policy, reply, unsupported_reason);

        let result = ApplyResult {
            requested: policy,
            effective,
            status,
            reason,
            capability,
            decided_at_ms: now_ms,
        };
        let applied = AppliedPolicy {
            configured: ConfiguredPolicy {
                target: target.clone(),
                policy,
                configured_at_ms: now_ms,
            },
            result: result.clone(),
        };
        match target {
            PolicyTarget::Global => self.global = Some(applied),
            PolicyTarget::Device(id) => {
                self.devices.insert(id, applied);
            }
        }
        Ok(result)
    }

    pub fn global(&self) -> Option<&AppliedPolicy> {
        self.global.as_ref()
    }

    pub fn device(&self, id: &DeviceId) -> Option<&AppliedPolicy> {
        self.devices.get(id)
    }

    /// Retire la limite d'une cible. Renvoie celle qui était enregistrée.
    pub fn clear(&mut self, target: &PolicyTarget) -> Option<AppliedPolicy> {
        match target {
            PolicyTarget::Global => self.global.take(),
            PolicyTarget::Device(id) => self.devices.remove(id),
        }
    }

    /// Retire les limites dont la durée est écoulée et les renvoie.
    pub fn expire(&mut self, now_ms: i64) -> Vec<AppliedPolicy> {
        let mut expired = Vec::new();
        if self.global.as_ref().is_some_and(|p| p.is_expired(now_ms)) {
            expired.extend(self.global.take());
        }
        let ids: Vec<DeviceId> = self
            .devices
            .iter()
            .filter(|(_, applied)| applied.is_expired(now_ms))
            .map(|(id, _)| id.clone())
            .collect();
        for id in ids {
            expired.extend(self.devices.remove(&id));
        }
        expired
    }
}

/// Décide du statut d'une demande. `reply` est la réponse de l'adaptateur, s'il
/// y en a un et si la capacité est prise en charge.
fn decide(
    supported: bool,
    target: &PolicyTarget,
    policy: &BandwidthPolicy,
    reply: Option<AdapterReply>,
    unsupported_reason: String,
) -> (ApplyStatus, Option<BandwidthPolicy>, Option<String>) {
    if !supported {
        let status = match target {
            PolicyTarget::Global => ApplyStatus::Simulated,
            PolicyTarget::Device(_) => ApplyStatus::Unsupported,
        };
        return (status, None, Some(unsupported_reason));
    }
    match reply {
        Some(AdapterReply::Confirmed(effective)) if effective == *policy => {
            (ApplyStatus::Applied, Some(effective), None)
        }
        Some(AdapterReply::Confirmed(effective)) => (
            ApplyStatus::Partial,
            Some(effective),
            Some("Le système applique une règle différente de celle demandée.".to_string()),
        ),
        Some(AdapterReply::Refused(reason)) => (ApplyStatus::Unsupported, None, Some(reason)),
        None => (
            ApplyStatus::Unsupported,
            None,
            Some("Aucun adaptateur n'a confirmé l'application.".to_string()),
        ),
    }
}

#[cfg(test)]
mod tests {
    use super::*;
    use capability_manager::PlatformContext;
    use shared_types::LimitMode;

    fn ios() -> BandwidthManager {
        BandwidthManager::new(CapabilitySet::detect(PlatformContext::ios()))
    }

    struct Confirming(BandwidthPolicy);
    impl ControlAdapter for Confirming {
        fn apply(&self, _: &PolicyTarget, _: &BandwidthPolicy) -> AdapterReply {
            AdapterReply::Confirmed(self.0)
        }
    }

    #[test]
    fn accepts_the_documented_range() {
        assert!(validate(&BandwidthPolicy::hard(MIN_LIMIT_BPS, MIN_LIMIT_BPS), false).is_ok());
        assert!(validate(&BandwidthPolicy::hard(MAX_LIMIT_BPS, MAX_LIMIT_BPS), false).is_ok());
        assert!(validate(&BandwidthPolicy::unlimited(), false).is_ok());
        let one_direction = BandwidthPolicy {
            upload_bps: None,
            ..BandwidthPolicy::hard(25_000_000, 1)
        };
        assert!(validate(&one_direction, false).is_ok());
    }

    #[test]
    fn rejects_limits_outside_the_range() {
        for (down, up) in [
            (MIN_LIMIT_BPS - 1, 1_000_000),
            (1_000_000, MIN_LIMIT_BPS - 1),
            (MAX_LIMIT_BPS + 1, 1_000_000),
            (1_000_000, u64::MAX),
        ] {
            let error = validate(&BandwidthPolicy::hard(down, up), true).unwrap_err();
            assert!(
                matches!(error, NetworkError::InvalidPolicy(_)),
                "{down} {up}"
            );
        }
    }

    #[test]
    fn zero_means_suspension_only_when_blocking_is_possible() {
        let suspend = BandwidthPolicy::hard(0, 0);
        assert!(validate(&suspend, true).is_ok());
        assert!(validate(&suspend, false).is_err());
    }

    #[test]
    fn rejects_durations_under_a_minute() {
        let mut policy = BandwidthPolicy::hard(5_000_000, 2_000_000);
        policy.duration_seconds = Some(59);
        assert!(validate(&policy, false).is_err());
        policy.duration_seconds = Some(60);
        assert!(validate(&policy, false).is_ok());
        policy.duration_seconds = Some(u64::MAX);
        assert!(validate(&policy, false).is_ok());
    }

    #[test]
    fn on_ios_a_global_limit_is_simulated_never_applied() {
        let mut manager = ios();
        let policy = BandwidthPolicy::hard(25_000_000, 10_000_000);
        // Même un adaptateur qui « confirmerait » ne change rien : la capacité manque.
        let adapter = Confirming(policy);
        let result = manager
            .apply(PolicyTarget::Global, policy, 1_000, Some(&adapter))
            .unwrap();
        assert_eq!(result.status, ApplyStatus::Simulated);
        assert_eq!(result.effective, None);
        assert_eq!(result.requested, policy);
        assert_eq!(result.capability, Capability::HotspotShaping);
        assert!(result.reason.unwrap().contains("iOS"));
        assert_eq!(result.decided_at_ms, 1_000);
        // La limite reste configurée.
        assert_eq!(manager.global().unwrap().configured.policy, policy);
    }

    #[test]
    fn on_ios_a_device_limit_is_recorded_as_unsupported() {
        let mut manager = ios();
        let device = DeviceId::new("device_001").unwrap();
        let policy = BandwidthPolicy::hard(20_000_000, 5_000_000);
        let result = manager
            .apply(PolicyTarget::Device(device.clone()), policy, 5, None)
            .unwrap();
        assert_eq!(result.status, ApplyStatus::Unsupported);
        assert_eq!(result.effective, None);
        assert_eq!(result.capability, Capability::PerDeviceShaping);
        assert_eq!(manager.device(&device).unwrap().configured.policy, policy);
        assert!(!result.status.is_effective());
    }

    #[test]
    fn an_invalid_policy_is_not_recorded() {
        let mut manager = ios();
        let error = manager
            .apply(PolicyTarget::Global, BandwidthPolicy::hard(1, 1), 0, None)
            .unwrap_err();
        assert!(matches!(error, NetworkError::InvalidPolicy(_)));
        assert!(manager.global().is_none());
        // Suspension : refusée, iOS ne peut pas bloquer le partage.
        assert!(
            manager
                .apply(PolicyTarget::Global, BandwidthPolicy::hard(0, 0), 0, None)
                .is_err()
        );
    }

    #[test]
    fn policies_expire_after_their_duration() {
        let mut manager = ios();
        let mut timed = BandwidthPolicy::hard(5_000_000, 2_000_000);
        timed.duration_seconds = Some(120);
        timed.mode = LimitMode::SoftLimit;
        manager
            .apply(PolicyTarget::Global, timed, 10_000, None)
            .unwrap();
        let device = DeviceId::new("tablette").unwrap();
        manager
            .apply(
                PolicyTarget::Device(device.clone()),
                BandwidthPolicy::hard(1_000_000, 500_000),
                10_000,
                None,
            )
            .unwrap();

        assert!(manager.expire(129_999).is_empty());
        let expired = manager.expire(130_000);
        assert_eq!(expired.len(), 1);
        assert_eq!(expired[0].configured.target, PolicyTarget::Global);
        assert!(manager.global().is_none());
        // Sans durée, la limite de l'appareil reste.
        assert!(manager.device(&device).is_some());
        assert!(
            manager
                .clear(&PolicyTarget::Device(device.clone()))
                .is_some()
        );
        assert!(manager.device(&device).is_none());
    }

    #[test]
    fn only_an_adapter_confirmation_makes_a_policy_applied() {
        let policy = BandwidthPolicy::hard(25_000_000, 10_000_000);
        let target = PolicyTarget::Global;
        let none = String::new;

        // Capacité présente, adaptateur qui confirme la règle demandée.
        let (status, effective, reason) = decide(
            true,
            &target,
            &policy,
            Some(AdapterReply::Confirmed(policy)),
            none(),
        );
        assert_eq!(
            (status, effective, reason),
            (ApplyStatus::Applied, Some(policy), None)
        );

        // L'adaptateur confirme autre chose : partiel, avec la règle réelle.
        let weaker = BandwidthPolicy::hard(30_000_000, 10_000_000);
        let (status, effective, reason) = decide(
            true,
            &target,
            &policy,
            Some(AdapterReply::Confirmed(weaker)),
            none(),
        );
        assert_eq!(status, ApplyStatus::Partial);
        assert_eq!(effective, Some(weaker));
        assert!(reason.is_some());

        // Refus, ou silence : jamais « appliqué ».
        let refused = AdapterReply::Refused("refusé par le système".to_string());
        let (status, effective, reason) = decide(true, &target, &policy, Some(refused), none());
        assert_eq!((status, effective), (ApplyStatus::Unsupported, None));
        assert_eq!(reason.as_deref(), Some("refusé par le système"));
        let (status, effective, _) = decide(true, &target, &policy, None, none());
        assert_eq!((status, effective), (ApplyStatus::Unsupported, None));

        // Capacité absente : la réponse d'un adaptateur ne compte pas.
        let (status, effective, _) = decide(
            false,
            &target,
            &policy,
            Some(AdapterReply::Confirmed(policy)),
            "iOS".to_string(),
        );
        assert_eq!((status, effective), (ApplyStatus::Simulated, None));
    }
}
