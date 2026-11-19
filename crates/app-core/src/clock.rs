//! Horloges. Le moteur ne lit l'heure qu'à travers ce trait, pour rester testable.

use std::sync::atomic::{AtomicI64, AtomicU64, Ordering};
use std::time::{Instant, SystemTime, UNIX_EPOCH};

pub trait Clock: Send + Sync {
    /// Millisecondes depuis l'époque Unix.
    fn wall_ms(&self) -> i64;
    /// Millisecondes d'une horloge qui ne recule jamais, pour mesurer des durées.
    fn monotonic_ms(&self) -> u64;
}

/// L'horloge du système.
#[derive(Debug)]
pub struct SystemClock {
    origin: Instant,
}

impl SystemClock {
    pub fn new() -> Self {
        SystemClock {
            origin: Instant::now(),
        }
    }
}

impl Default for SystemClock {
    fn default() -> Self {
        Self::new()
    }
}

impl Clock for SystemClock {
    fn wall_ms(&self) -> i64 {
        SystemTime::now()
            .duration_since(UNIX_EPOCH)
            .map(|elapsed| i64::try_from(elapsed.as_millis()).unwrap_or(i64::MAX))
            .unwrap_or(0)
    }

    fn monotonic_ms(&self) -> u64 {
        u64::try_from(self.origin.elapsed().as_millis()).unwrap_or(u64::MAX)
    }
}

/// Une horloge que l'on avance à la main, pour les tests.
#[derive(Debug, Default)]
pub struct ManualClock {
    wall_ms: AtomicI64,
    monotonic_ms: AtomicU64,
}

impl ManualClock {
    pub fn at(wall_ms: i64) -> Self {
        ManualClock {
            wall_ms: AtomicI64::new(wall_ms),
            monotonic_ms: AtomicU64::new(0),
        }
    }

    pub fn advance(&self, ms: u64) {
        self.wall_ms
            .fetch_add(i64::try_from(ms).unwrap_or(i64::MAX), Ordering::SeqCst);
        self.monotonic_ms.fetch_add(ms, Ordering::SeqCst);
    }
}

impl Clock for ManualClock {
    fn wall_ms(&self) -> i64 {
        self.wall_ms.load(Ordering::SeqCst)
    }

    fn monotonic_ms(&self) -> u64 {
        self.monotonic_ms.load(Ordering::SeqCst)
    }
}
