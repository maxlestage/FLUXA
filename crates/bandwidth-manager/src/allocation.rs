//! Répartition d'une capacité entre plusieurs appareils.
//!
//! Remplissage progressif pondéré : chaque appareil reçoit une part de la capacité
//! proportionnelle à son poids, sans dépasser son plafond ni sa demande. Ce qu'un
//! appareil plafonné n'utilise pas est redistribué aux autres. Tout poids est
//! strictement positif : un appareil prioritaire ne peut pas en affamer un autre.

use shared_types::{DeviceId, LimitMode};

#[derive(Debug, Clone, Copy, PartialEq, Eq, Hash, PartialOrd, Ord)]
pub enum Priority {
    Low,
    Normal,
    High,
}

impl Priority {
    const fn weight(self) -> u128 {
        match self {
            Priority::Low => 1,
            Priority::Normal => 2,
            Priority::High => 4,
        }
    }
}

/// Ce qu'un appareil demande.
#[derive(Debug, Clone, PartialEq, Eq)]
pub struct Demand {
    pub device: DeviceId,
    /// Plafond configuré pour l'appareil. `None` : aucun.
    pub limit_bps: Option<u64>,
    pub priority: Priority,
    /// Débit que l'appareil cherche à utiliser. `None` : autant que possible.
    pub demand_bps: Option<u64>,
}

/// Ce qu'un appareil obtient.
#[derive(Debug, Clone, PartialEq, Eq)]
pub struct Allocation {
    pub device: DeviceId,
    pub allocated_bps: u64,
}

/// Répartit `capacity_bps` entre les demandes.
///
/// `FairShare` donne le même poids à tous. `Priority` pondère selon la priorité.
/// Les autres modes ne répartissent rien : chacun reçoit son plafond, dans la
/// limite de la capacité restante et dans l'ordre des demandes.
///
/// La somme des parts ne dépasse jamais la capacité.
pub fn allocate(capacity_bps: u64, mode: LimitMode, demands: &[Demand]) -> Vec<Allocation> {
    let ceilings: Vec<u64> = demands
        .iter()
        .map(|d| {
            d.limit_bps
                .unwrap_or(u64::MAX)
                .min(d.demand_bps.unwrap_or(u64::MAX))
        })
        .collect();
    let mut shares = vec![0u64; demands.len()];

    match mode {
        LimitMode::FairShare | LimitMode::Priority => {
            let weight = |index: usize| match mode {
                LimitMode::Priority => demands[index].priority.weight(),
                _ => 1,
            };
            let mut open: Vec<usize> = (0..demands.len()).collect();
            let mut remaining = u128::from(capacity_bps);
            loop {
                let total_weight: u128 = open.iter().map(|&i| weight(i)).sum();
                if open.is_empty() || total_weight == 0 {
                    break;
                }
                // Les appareils dont le plafond est sous leur part la reçoivent en entier.
                let saturated: Vec<usize> = open
                    .iter()
                    .copied()
                    .filter(|&i| u128::from(ceilings[i]) <= remaining * weight(i) / total_weight)
                    .collect();
                if saturated.is_empty() {
                    for &i in &open {
                        shares[i] =
                            u64::try_from(remaining * weight(i) / total_weight).unwrap_or(u64::MAX);
                    }
                    break;
                }
                for &i in &saturated {
                    shares[i] = ceilings[i];
                    remaining -= u128::from(ceilings[i]);
                }
                open.retain(|i| !saturated.contains(i));
            }
        }
        LimitMode::HardLimit | LimitMode::SoftLimit => {
            let mut remaining = capacity_bps;
            for (index, ceiling) in ceilings.iter().enumerate() {
                shares[index] = (*ceiling).min(remaining);
                remaining -= shares[index];
            }
        }
    }

    demands
        .iter()
        .zip(shares)
        .map(|(demand, allocated_bps)| Allocation {
            device: demand.device.clone(),
            allocated_bps,
        })
        .collect()
}

#[cfg(test)]
mod tests {
    use super::*;

    const MBPS: u64 = 1_000_000;

    fn demand(id: &str, limit_mbps: Option<u64>, priority: Priority) -> Demand {
        Demand {
            device: DeviceId::new(id).unwrap(),
            limit_bps: limit_mbps.map(|m| m * MBPS),
            priority,
            demand_bps: None,
        }
    }

    fn example() -> Vec<Demand> {
        vec![
            demand("ordinateur", Some(50), Priority::High),
            demand("smartphone", Some(30), Priority::Normal),
            demand("tablette", Some(20), Priority::Low),
        ]
    }

    fn mbps(allocations: &[Allocation]) -> Vec<f64> {
        allocations
            .iter()
            .map(|a| a.allocated_bps as f64 / MBPS as f64)
            .collect()
    }

    #[test]
    fn the_specification_example_fits_exactly() {
        // 100 Mb/s pour des plafonds de 50, 30 et 20 Mb/s.
        for mode in [
            LimitMode::Priority,
            LimitMode::FairShare,
            LimitMode::HardLimit,
        ] {
            let allocations = allocate(100 * MBPS, mode, &example());
            assert_eq!(mbps(&allocations), vec![50.0, 30.0, 20.0], "{mode:?}");
        }
    }

    #[test]
    fn priorities_weigh_the_shares_without_starving_anyone() {
        // 35 Mb/s à se partager : poids 4, 2 et 1.
        let allocations = allocate(35 * MBPS, LimitMode::Priority, &example());
        assert_eq!(mbps(&allocations), vec![20.0, 10.0, 5.0]);
        assert!(allocations.iter().all(|a| a.allocated_bps > 0));
    }

    #[test]
    fn fair_share_splits_equally_and_redistributes_unused_capacity() {
        let allocations = allocate(60 * MBPS, LimitMode::FairShare, &example());
        assert_eq!(mbps(&allocations), vec![20.0, 20.0, 20.0]);

        // La tablette est plafonnée à 20 : les 70 restants vont aux deux autres,
        // le smartphone s'arrête à son plafond de 30 et l'ordinateur prend la suite.
        let allocations = allocate(90 * MBPS, LimitMode::FairShare, &example());
        assert_eq!(mbps(&allocations), vec![40.0, 30.0, 20.0]);
    }

    #[test]
    fn never_exceeds_capacity_nor_any_limit() {
        let demands = example();
        for capacity in [
            0,
            1,
            7,
            999_999,
            13 * MBPS,
            64 * MBPS,
            100 * MBPS,
            500 * MBPS,
        ] {
            for mode in [
                LimitMode::Priority,
                LimitMode::FairShare,
                LimitMode::HardLimit,
            ] {
                let allocations = allocate(capacity, mode, &demands);
                let total: u64 = allocations.iter().map(|a| a.allocated_bps).sum();
                assert!(total <= capacity, "{mode:?} {capacity}: {total}");
                for (allocation, demand) in allocations.iter().zip(&demands) {
                    assert!(allocation.allocated_bps <= demand.limit_bps.unwrap());
                }
            }
        }
    }

    #[test]
    fn a_device_never_gets_more_than_it_asks_for() {
        let mut demands = example();
        demands[0].demand_bps = Some(4 * MBPS);
        let allocations = allocate(40 * MBPS, LimitMode::Priority, &demands);
        // L'ordinateur ne demande que 4 : les 36 restants se partagent à 2 contre 1.
        assert_eq!(mbps(&allocations), vec![4.0, 24.0, 12.0]);
    }

    #[test]
    fn devices_without_limits_share_everything() {
        let demands = vec![
            demand("a", None, Priority::Normal),
            demand("b", None, Priority::Normal),
        ];
        let allocations = allocate(100 * MBPS, LimitMode::FairShare, &demands);
        assert_eq!(mbps(&allocations), vec![50.0, 50.0]);
        assert!(allocate(100 * MBPS, LimitMode::FairShare, &[]).is_empty());
    }

    #[test]
    fn strict_limits_are_served_in_order_when_capacity_is_short() {
        let allocations = allocate(60 * MBPS, LimitMode::HardLimit, &example());
        assert_eq!(mbps(&allocations), vec![50.0, 10.0, 0.0]);
    }
}
