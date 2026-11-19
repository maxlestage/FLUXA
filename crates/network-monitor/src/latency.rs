//! Latence, gigue et pertes sur une fenêtre glissante de sondes.

use std::collections::VecDeque;

/// Les dernières sondes de latence. `None` : sonde restée sans réponse.
#[derive(Debug, Clone)]
pub struct LatencyWindow {
    capacity: usize,
    probes: VecDeque<Option<f64>>,
}

impl LatencyWindow {
    pub fn new(capacity: usize) -> Self {
        LatencyWindow {
            capacity: capacity.max(1),
            probes: VecDeque::new(),
        }
    }

    pub fn clear(&mut self) {
        self.probes.clear();
    }

    /// Ajoute une sonde. Une valeur négative ou non finie compte comme perdue.
    pub fn push(&mut self, latency_ms: Option<f64>) {
        let probe = latency_ms.filter(|ms| ms.is_finite() && *ms >= 0.0);
        if self.probes.len() == self.capacity {
            self.probes.pop_front();
        }
        self.probes.push_back(probe);
    }

    /// Latence de la sonde la plus récente ayant répondu.
    pub fn latest(&self) -> Option<f64> {
        self.probes.iter().rev().find_map(|probe| *probe)
    }

    pub fn average(&self) -> Option<f64> {
        let answered: Vec<f64> = self.probes.iter().flatten().copied().collect();
        if answered.is_empty() {
            return None;
        }
        Some(answered.iter().sum::<f64>() / answered.len() as f64)
    }

    /// Gigue : écart moyen entre deux réponses successives. Il en faut au moins deux.
    pub fn jitter(&self) -> Option<f64> {
        let answered: Vec<f64> = self.probes.iter().flatten().copied().collect();
        if answered.len() < 2 {
            return None;
        }
        let total: f64 = answered
            .windows(2)
            .map(|pair| (pair[1] - pair[0]).abs())
            .sum();
        Some(total / (answered.len() - 1) as f64)
    }

    /// Part des sondes sans réponse, entre 0 et 1. `None` sans aucune sonde.
    pub fn loss_ratio(&self) -> Option<f64> {
        if self.probes.is_empty() {
            return None;
        }
        let lost = self.probes.iter().filter(|probe| probe.is_none()).count();
        Some(lost as f64 / self.probes.len() as f64)
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn empty_window_reports_nothing() {
        let window = LatencyWindow::new(5);
        assert_eq!(window.latest(), None);
        assert_eq!(window.average(), None);
        assert_eq!(window.jitter(), None);
        assert_eq!(window.loss_ratio(), None);
    }

    #[test]
    fn computes_latency_jitter_and_loss() {
        let mut window = LatencyWindow::new(10);
        for probe in [Some(20.0), Some(30.0), None, Some(24.0), Some(28.0)] {
            window.push(probe);
        }
        assert_eq!(window.latest(), Some(28.0));
        assert_eq!(window.average(), Some(25.5));
        // |30−20| + |24−30| + |28−24| = 20, sur 3 écarts.
        assert!((window.jitter().unwrap() - 20.0 / 3.0).abs() < 1e-9);
        assert_eq!(window.loss_ratio(), Some(0.2));
    }

    #[test]
    fn one_answer_is_not_enough_for_jitter() {
        let mut window = LatencyWindow::new(4);
        window.push(None);
        window.push(Some(18.0));
        assert_eq!(window.jitter(), None);
        assert_eq!(window.latest(), Some(18.0));
        assert_eq!(window.loss_ratio(), Some(0.5));
    }

    #[test]
    fn all_probes_lost() {
        let mut window = LatencyWindow::new(3);
        window.push(None);
        window.push(None);
        assert_eq!(window.latest(), None);
        assert_eq!(window.loss_ratio(), Some(1.0));
    }

    #[test]
    fn keeps_only_the_most_recent_probes() {
        let mut window = LatencyWindow::new(3);
        for probe in [None, Some(100.0), Some(10.0), Some(12.0), Some(14.0)] {
            window.push(probe);
        }
        assert_eq!(window.loss_ratio(), Some(0.0));
        assert_eq!(window.average(), Some(12.0));
        assert_eq!(window.jitter(), Some(2.0));
    }

    #[test]
    fn invalid_values_count_as_lost() {
        let mut window = LatencyWindow::new(4);
        window.push(Some(f64::NAN));
        window.push(Some(-5.0));
        window.push(Some(f64::INFINITY));
        window.push(Some(15.0));
        assert_eq!(window.loss_ratio(), Some(0.75));
        assert_eq!(window.latest(), Some(15.0));
    }
}
