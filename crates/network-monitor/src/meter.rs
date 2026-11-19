//! Compteurs d'octets des interfaces : différences entre deux relevés.

use std::collections::HashMap;

use shared_types::InterfaceClass;

/// Largeur des compteurs fournis par le système. Sur iOS, `if_data` expose des
/// compteurs de 32 bits, qui repassent par zéro tous les 4 Gio.
#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub enum CounterWidth {
    Bits32,
    Bits64,
}

/// Compteurs cumulés d'une interface à un instant donné.
#[derive(Debug, Clone, PartialEq, Eq)]
pub struct InterfaceReading {
    pub name: String,
    pub class: InterfaceClass,
    pub rx_bytes: u64,
    pub tx_bytes: u64,
}

/// Octets échangés par une interface entre deux relevés.
#[derive(Debug, Clone, PartialEq, Eq)]
pub struct InterfaceDelta {
    pub name: String,
    pub class: InterfaceClass,
    pub rx_bytes: u64,
    pub tx_bytes: u64,
}

/// Différences de toutes les interfaces suivies, sur un même intervalle.
#[derive(Debug, Clone, PartialEq, Eq)]
pub struct Deltas {
    pub interval_ms: u64,
    pub interfaces: Vec<InterfaceDelta>,
}

/// Au-delà de ce débit, un compteur qui recule est considéré comme remis à zéro
/// et non comme ayant débordé : 20 Gb/s.
const MAX_PLAUSIBLE_BPS: u128 = 20_000_000_000;

/// Suit les compteurs de chaque interface d'un relevé à l'autre.
#[derive(Debug)]
pub struct InterfaceMeters {
    width: CounterWidth,
    previous: HashMap<String, (u64, u64)>,
    previous_ms: Option<u64>,
}

impl InterfaceMeters {
    pub fn new(width: CounterWidth) -> Self {
        InterfaceMeters {
            width,
            previous: HashMap::new(),
            previous_ms: None,
        }
    }

    pub fn reset(&mut self) {
        self.previous.clear();
        self.previous_ms = None;
    }

    /// Intègre un relevé. Renvoie `None` pour le premier relevé et quand l'horloge
    /// n'a pas avancé ; le relevé devient alors la nouvelle base.
    ///
    /// Une interface absente du relevé précédent, ou dont le compteur a été remis
    /// à zéro, ne compte pas dans cet intervalle.
    pub fn push(&mut self, readings: &[InterfaceReading], monotonic_ms: u64) -> Option<Deltas> {
        let interval_ms = match self.previous_ms {
            Some(previous_ms) if monotonic_ms > previous_ms => Some(monotonic_ms - previous_ms),
            _ => None,
        };
        let mut interfaces = Vec::new();
        if let Some(interval_ms) = interval_ms {
            for reading in readings {
                let Some(&(rx, tx)) = self.previous.get(&reading.name) else {
                    continue;
                };
                let rx_bytes = self.delta(rx, reading.rx_bytes, interval_ms);
                let tx_bytes = self.delta(tx, reading.tx_bytes, interval_ms);
                if let (Some(rx_bytes), Some(tx_bytes)) = (rx_bytes, tx_bytes) {
                    interfaces.push(InterfaceDelta {
                        name: reading.name.clone(),
                        class: reading.class,
                        rx_bytes,
                        tx_bytes,
                    });
                }
            }
        }
        self.previous = readings
            .iter()
            .map(|r| (r.name.clone(), (r.rx_bytes, r.tx_bytes)))
            .collect();
        self.previous_ms = Some(monotonic_ms);
        interval_ms.map(|interval_ms| Deltas {
            interval_ms,
            interfaces,
        })
    }

    /// Octets comptés entre deux valeurs d'un compteur. `None` si le compteur a
    /// été remis à zéro (interface relancée, redémarrage).
    fn delta(&self, previous: u64, current: u64, interval_ms: u64) -> Option<u64> {
        if current >= previous {
            return Some(current - previous);
        }
        match self.width {
            CounterWidth::Bits64 => None,
            CounterWidth::Bits32 => {
                let modulus = 1u64 << 32;
                if previous >= modulus {
                    return None;
                }
                // Débordement : le compteur est reparti de zéro après 2^32.
                let wrapped = modulus - previous + current;
                let bps = u128::from(wrapped) * 8 * 1000 / u128::from(interval_ms.max(1));
                (bps <= MAX_PLAUSIBLE_BPS).then_some(wrapped)
            }
        }
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    fn wifi(rx: u64, tx: u64) -> InterfaceReading {
        InterfaceReading {
            name: "en0".into(),
            class: InterfaceClass::Wifi,
            rx_bytes: rx,
            tx_bytes: tx,
        }
    }

    #[test]
    fn first_reading_is_only_a_baseline() {
        let mut meters = InterfaceMeters::new(CounterWidth::Bits64);
        assert_eq!(meters.push(&[wifi(500, 100)], 1000), None);
        let deltas = meters.push(&[wifi(1500, 400)], 2000).unwrap();
        assert_eq!(deltas.interval_ms, 1000);
        assert_eq!(
            (deltas.interfaces[0].rx_bytes, deltas.interfaces[0].tx_bytes),
            (1000, 300)
        );
    }

    #[test]
    fn a_32_bit_counter_that_wraps_keeps_counting() {
        let mut meters = InterfaceMeters::new(CounterWidth::Bits32);
        let near_max = u64::from(u32::MAX) - 999; // à 1000 octets du débordement
        meters.push(&[wifi(near_max, 0)], 0);
        let deltas = meters.push(&[wifi(4000, 0)], 1000).unwrap();
        assert_eq!(deltas.interfaces[0].rx_bytes, 5000);
    }

    #[test]
    fn a_counter_reset_is_not_mistaken_for_a_wrap() {
        // Le compteur repart de zéro alors qu'il était loin du débordement : le
        // débit que supposerait un débordement est invraisemblable.
        let mut meters = InterfaceMeters::new(CounterWidth::Bits32);
        meters.push(&[wifi(1_000_000, 1_000_000)], 0);
        let deltas = meters.push(&[wifi(200, 100)], 1000).unwrap();
        assert!(deltas.interfaces.is_empty(), "{deltas:?}");
        // Le relevé suivant repart de la nouvelle base.
        let deltas = meters.push(&[wifi(1200, 600)], 2000).unwrap();
        assert_eq!(
            (deltas.interfaces[0].rx_bytes, deltas.interfaces[0].tx_bytes),
            (1000, 500)
        );
    }

    #[test]
    fn a_64_bit_counter_never_wraps() {
        let mut meters = InterfaceMeters::new(CounterWidth::Bits64);
        meters.push(&[wifi(u64::from(u32::MAX) - 10, 0)], 0);
        assert!(
            meters
                .push(&[wifi(20, 0)], 1000)
                .unwrap()
                .interfaces
                .is_empty()
        );
    }

    #[test]
    fn a_clock_that_does_not_advance_gives_no_rate() {
        let mut meters = InterfaceMeters::new(CounterWidth::Bits64);
        meters.push(&[wifi(0, 0)], 5000);
        assert_eq!(meters.push(&[wifi(100, 0)], 5000), None);
        assert_eq!(
            meters.push(&[wifi(200, 0)], 4000),
            None,
            "horloge qui recule"
        );
        // La base suit quand même : 300 − 200 sur une seconde.
        let deltas = meters.push(&[wifi(300, 0)], 5000).unwrap();
        assert_eq!(deltas.interfaces[0].rx_bytes, 100);
    }

    #[test]
    fn a_new_interface_waits_for_its_second_reading() {
        let mut meters = InterfaceMeters::new(CounterWidth::Bits64);
        meters.push(&[wifi(0, 0)], 0);
        let cell = InterfaceReading {
            name: "pdp_ip0".into(),
            class: InterfaceClass::Cellular,
            rx_bytes: 7_000_000,
            tx_bytes: 0,
        };
        let deltas = meters.push(&[wifi(10, 0), cell.clone()], 1000).unwrap();
        assert_eq!(deltas.interfaces.len(), 1, "pdp_ip0 n'a pas encore de base");
        // en0 disparaît puis revient : pas de comparaison avec l'ancien relevé.
        meters.push(std::slice::from_ref(&cell), 2000);
        let deltas = meters.push(&[wifi(90_000, 0), cell], 3000).unwrap();
        assert_eq!(deltas.interfaces.len(), 1);
        assert_eq!(deltas.interfaces[0].name, "pdp_ip0");
        assert_eq!(deltas.interfaces[0].rx_bytes, 0);
    }

    #[test]
    fn reset_clears_everything() {
        let mut meters = InterfaceMeters::new(CounterWidth::Bits64);
        meters.push(&[wifi(0, 0)], 0);
        meters.reset();
        assert_eq!(meters.push(&[wifi(100, 0)], 1000), None);
    }
}
