//! Mesure réseau.
//!
//! L'adaptateur natif relève les compteurs d'octets des interfaces et le résultat
//! des sondes de latence. Ce module en tire les débits, la latence, la gigue et
//! les pertes. Il ne lit ni l'horloge ni le système : tout lui est passé.

mod latency;
mod meter;

pub use latency::LatencyWindow;
pub use meter::{CounterWidth, InterfaceMeters, InterfaceReading};

use shared_types::{InterfaceClass, MeasurementScope, NetworkKind, NetworkSnapshot, Throughput};

/// Famille d'interfaces qui porte le trafic pour un type de réseau donné.
pub fn class_for(kind: NetworkKind) -> Option<InterfaceClass> {
    match kind {
        NetworkKind::Wifi => Some(InterfaceClass::Wifi),
        NetworkKind::Cellular | NetworkKind::Cellular4G | NetworkKind::Cellular5G => {
            Some(InterfaceClass::Cellular)
        }
        NetworkKind::Wired => Some(InterfaceClass::Wired),
        NetworkKind::Other => Some(InterfaceClass::Other),
        NetworkKind::None => None,
    }
}

/// État de la surveillance : type de réseau, compteurs, sondes de latence.
#[derive(Debug)]
pub struct Monitor {
    running: bool,
    kind: NetworkKind,
    online: bool,
    meters: InterfaceMeters,
    latency: LatencyWindow,
    last: Option<Throughput>,
}

impl Monitor {
    pub fn new(width: CounterWidth) -> Self {
        Monitor {
            running: false,
            kind: NetworkKind::None,
            online: false,
            meters: InterfaceMeters::new(width),
            latency: LatencyWindow::new(12),
            last: None,
        }
    }

    pub fn is_running(&self) -> bool {
        self.running
    }

    pub fn kind(&self) -> NetworkKind {
        self.kind
    }

    pub fn start(&mut self) {
        self.running = true;
    }

    /// Arrête la surveillance et oublie les relevés : au redémarrage, le premier
    /// relevé ne sert que de point de départ.
    pub fn stop(&mut self) {
        self.running = false;
        self.meters.reset();
        self.latency.clear();
        self.last = None;
    }

    /// Le système signale un changement de réseau.
    pub fn set_path(&mut self, kind: NetworkKind, online: bool) {
        if kind != self.kind {
            // Les mesures de l'ancien réseau ne décrivent pas le nouveau.
            self.latency.clear();
            self.last = None;
        }
        self.kind = kind;
        self.online = online;
    }

    /// Intègre un relevé des compteurs de toutes les interfaces. Renvoie le débit
    /// de la famille d'interfaces active, ou `None` tant qu'il n'est pas calculable.
    pub fn ingest(
        &mut self,
        readings: &[InterfaceReading],
        monotonic_ms: u64,
    ) -> Option<Throughput> {
        if !self.running {
            return None;
        }
        let class = class_for(self.kind);
        let deltas = self.meters.push(readings, monotonic_ms);
        let (class, deltas) = (class?, deltas?);
        let mut rx_bytes = 0u64;
        let mut tx_bytes = 0u64;
        let mut measured = false;
        for delta in deltas.interfaces.iter().filter(|d| d.class == class) {
            rx_bytes = rx_bytes.saturating_add(delta.rx_bytes);
            tx_bytes = tx_bytes.saturating_add(delta.tx_bytes);
            measured = true;
        }
        if !measured {
            self.last = None;
            return None;
        }
        let throughput = Throughput {
            download_bps: rate_bps(rx_bytes, deltas.interval_ms),
            upload_bps: rate_bps(tx_bytes, deltas.interval_ms),
            rx_bytes,
            tx_bytes,
            interval_ms: deltas.interval_ms,
            scope: MeasurementScope::DeviceInterfaces(class),
        };
        self.last = Some(throughput);
        self.last
    }

    /// Résultat d'une sonde de latence. `None` : la sonde est restée sans réponse.
    pub fn record_latency(&mut self, latency_ms: Option<f64>) {
        if self.running {
            self.latency.push(latency_ms);
        }
    }

    pub fn last_throughput(&self) -> Option<Throughput> {
        self.last
    }

    pub fn snapshot(&self, timestamp_ms: i64) -> NetworkSnapshot {
        NetworkSnapshot {
            timestamp_ms,
            monitoring: self.running,
            kind: self.kind,
            online: self.online,
            throughput: self.last,
            latency_ms: self.latency.latest(),
            jitter_ms: self.latency.jitter(),
            loss_ratio: self.latency.loss_ratio(),
        }
    }
}

/// Débit = octets × 8 / durée. Zéro si la durée est nulle.
pub fn rate_bps(bytes: u64, interval_ms: u64) -> u64 {
    if interval_ms == 0 {
        return 0;
    }
    let bits = u128::from(bytes) * 8 * 1000;
    u64::try_from(bits / u128::from(interval_ms)).unwrap_or(u64::MAX)
}

#[cfg(test)]
mod tests {
    use super::*;

    fn reading(name: &str, class: InterfaceClass, rx: u64, tx: u64) -> InterfaceReading {
        InterfaceReading {
            name: name.to_string(),
            class,
            rx_bytes: rx,
            tx_bytes: tx,
        }
    }

    #[test]
    fn computes_rate_from_the_formula() {
        // (octets2 − octets1) × 8 / (t2 − t1)
        assert_eq!(rate_bps(1_000_000, 1000), 8_000_000);
        assert_eq!(rate_bps(5_350_000, 1000), 42_800_000);
        assert_eq!(rate_bps(125_000, 500), 2_000_000);
        assert_eq!(rate_bps(10, 0), 0);
        assert_eq!(rate_bps(u64::MAX, 1), u64::MAX);
    }

    #[test]
    fn measures_only_the_active_interface_family() {
        let mut monitor = Monitor::new(CounterWidth::Bits32);
        monitor.start();
        monitor.set_path(NetworkKind::Cellular5G, true);
        let first = [
            reading("en0", InterfaceClass::Wifi, 1_000, 1_000),
            reading("pdp_ip0", InterfaceClass::Cellular, 10_000, 2_000),
            reading("pdp_ip1", InterfaceClass::Cellular, 500, 500),
        ];
        assert_eq!(
            monitor.ingest(&first, 10_000),
            None,
            "le premier relevé sert de base"
        );

        let second = [
            reading("en0", InterfaceClass::Wifi, 9_001_000, 1_000),
            reading("pdp_ip0", InterfaceClass::Cellular, 5_010_000, 1_002_000),
            reading("pdp_ip1", InterfaceClass::Cellular, 350_500, 50_500),
        ];
        let throughput = monitor.ingest(&second, 11_000).unwrap();
        assert_eq!(throughput.rx_bytes, 5_350_000);
        assert_eq!(throughput.tx_bytes, 1_050_000);
        assert_eq!(throughput.download_bps, 42_800_000);
        assert_eq!(throughput.upload_bps, 8_400_000);
        assert_eq!(throughput.interval_ms, 1000);
        assert_eq!(
            throughput.scope,
            MeasurementScope::DeviceInterfaces(InterfaceClass::Cellular)
        );
    }

    #[test]
    fn reports_nothing_without_a_network_or_when_stopped() {
        let mut monitor = Monitor::new(CounterWidth::Bits64);
        let a = [reading("en0", InterfaceClass::Wifi, 0, 0)];
        let b = [reading("en0", InterfaceClass::Wifi, 1000, 1000)];
        assert_eq!(monitor.ingest(&a, 0), None, "arrêté");
        monitor.start();
        assert_eq!(monitor.ingest(&a, 1000), None);
        assert_eq!(monitor.ingest(&b, 2000), None, "aucun réseau actif");
        monitor.set_path(NetworkKind::Wifi, true);
        let c = [reading("en0", InterfaceClass::Wifi, 2000, 1000)];
        assert_eq!(monitor.ingest(&c, 3000).unwrap().download_bps, 8000);
        // Wi-Fi actif, mais aucune interface de cette famille dans le relevé.
        let d = [reading("pdp_ip0", InterfaceClass::Cellular, 5, 5)];
        assert_eq!(monitor.ingest(&d, 4000), None);
        assert_eq!(monitor.last_throughput(), None);
    }

    #[test]
    fn stop_forgets_the_baseline() {
        let mut monitor = Monitor::new(CounterWidth::Bits64);
        monitor.start();
        monitor.set_path(NetworkKind::Wifi, true);
        monitor.ingest(&[reading("en0", InterfaceClass::Wifi, 0, 0)], 0);
        monitor.ingest(&[reading("en0", InterfaceClass::Wifi, 1000, 0)], 1000);
        monitor.record_latency(Some(20.0));
        monitor.stop();
        let snapshot = monitor.snapshot(5);
        assert!(!snapshot.monitoring);
        assert_eq!(snapshot.throughput, None);
        assert_eq!(snapshot.latency_ms, None);

        monitor.start();
        // Une heure plus tard : ce relevé ne doit pas être comparé à l'ancien.
        let later = [reading("en0", InterfaceClass::Wifi, 900_000_000, 0)];
        assert_eq!(monitor.ingest(&later, 3_600_000), None);
    }

    #[test]
    fn snapshot_carries_latency_statistics_and_path() {
        let mut monitor = Monitor::new(CounterWidth::Bits64);
        monitor.start();
        monitor.set_path(NetworkKind::Wifi, true);
        for sample in [Some(20.0), Some(30.0), None, Some(26.0)] {
            monitor.record_latency(sample);
        }
        let snapshot = monitor.snapshot(42);
        assert_eq!(snapshot.timestamp_ms, 42);
        assert_eq!(snapshot.kind, NetworkKind::Wifi);
        assert!(snapshot.online && snapshot.monitoring);
        assert_eq!(snapshot.latency_ms, Some(26.0));
        assert_eq!(snapshot.loss_ratio, Some(0.25));
        assert!(snapshot.jitter_ms.is_some());

        // Un changement de réseau efface les mesures de l'ancien.
        monitor.set_path(NetworkKind::Cellular4G, true);
        let snapshot = monitor.snapshot(43);
        assert_eq!(snapshot.latency_ms, None);
        assert_eq!(snapshot.loss_ratio, None);
    }
}
