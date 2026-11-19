//! Simulation : ce qu'une limite donnerait sur un débit mesuré, sans agir sur le trafic.

use shared_types::{BandwidthPolicy, LimitMode};

/// Effet simulé d'un plafond dans un sens.
#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub struct DirectionEffect {
    pub measured_bps: u64,
    pub cap_bps: Option<u64>,
    /// Le débit qui resterait si la limite était appliquée.
    pub resulting_bps: u64,
    /// Vrai si la limite réduirait le débit mesuré.
    pub limited: bool,
}

/// Effet simulé d'une limite dans les deux sens.
#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub struct Simulation {
    pub mode: LimitMode,
    pub download: DirectionEffect,
    pub upload: DirectionEffect,
}

/// Simule une limite sur un débit mesuré.
///
/// Un débit cible (`SoftLimit`) laisse utiliser la bande passante disponible : sur
/// un flux seul, il ne réduit rien. Les autres modes plafonnent le débit mesuré.
pub fn simulate(
    policy: &BandwidthPolicy,
    measured_down_bps: u64,
    measured_up_bps: u64,
) -> Simulation {
    let effect = |measured_bps: u64, cap_bps: Option<u64>| {
        let binding = policy.mode != LimitMode::SoftLimit;
        let resulting_bps = match cap_bps {
            Some(cap) if binding => measured_bps.min(cap),
            _ => measured_bps,
        };
        DirectionEffect {
            measured_bps,
            cap_bps,
            resulting_bps,
            limited: resulting_bps < measured_bps,
        }
    };
    Simulation {
        mode: policy.mode,
        download: effect(measured_down_bps, policy.download_bps),
        upload: effect(measured_up_bps, policy.upload_bps),
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn a_cap_below_the_measured_rate_limits_it() {
        // Profil Streaming sur 42,8 / 8,4 Mb/s mesurés.
        let simulation = simulate(
            &BandwidthPolicy::hard(25_000_000, 10_000_000),
            42_800_000,
            8_400_000,
        );
        assert_eq!(simulation.download.resulting_bps, 25_000_000);
        assert!(simulation.download.limited);
        assert_eq!(simulation.upload.resulting_bps, 8_400_000);
        assert!(
            !simulation.upload.limited,
            "le montant est déjà sous le plafond"
        );
    }

    #[test]
    fn no_cap_changes_nothing() {
        let simulation = simulate(&BandwidthPolicy::unlimited(), 42_800_000, 8_400_000);
        assert_eq!(simulation.download.resulting_bps, 42_800_000);
        assert_eq!(simulation.download.cap_bps, None);
        assert!(!simulation.download.limited && !simulation.upload.limited);
    }

    #[test]
    fn a_soft_limit_does_not_reduce_a_lone_flow() {
        let mut policy = BandwidthPolicy::hard(5_000_000, 2_000_000);
        policy.mode = LimitMode::SoftLimit;
        let simulation = simulate(&policy, 42_800_000, 8_400_000);
        assert_eq!(simulation.download.resulting_bps, 42_800_000);
        assert!(!simulation.download.limited);
        assert_eq!(simulation.download.cap_bps, Some(5_000_000));
    }

    #[test]
    fn nothing_measured_gives_nothing() {
        let simulation = simulate(&BandwidthPolicy::hard(1_000_000, 500_000), 0, 0);
        assert_eq!(simulation.download.resulting_bps, 0);
        assert!(!simulation.download.limited);
    }

    #[test]
    fn a_cap_equal_to_the_measured_rate_is_not_a_reduction() {
        let simulation = simulate(
            &BandwidthPolicy::hard(8_400_000, 8_400_000),
            8_400_000,
            8_400_000,
        );
        assert!(!simulation.download.limited && !simulation.upload.limited);
    }
}
