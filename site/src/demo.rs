//! Les données de démonstration du tableau de bord : un débit fictif qui varie autour
//! d'une valeur de repos, une mesure par seconde, comme dans l'app.

/// Le nombre de points visibles sur la courbe : les trente dernières secondes.
pub const POINTS: usize = 30;
/// Le haut de l'échelle de la courbe, en Mb/s.
pub const SCALE_MAX: f64 = 60.0;
/// Les valeurs de repos, affichées avant que la démonstration ne démarre.
pub const REST_DOWN: f64 = 42.8;
pub const REST_UP: f64 = 8.4;
pub const REST_LATENCY: u32 = 28;
pub const REST_JITTER: u32 = 4;

/// Une suite de mesures fictives, reproductible à partir de sa graine.
#[derive(Debug, Clone)]
pub struct Flow {
    rng: u32,
    down: Vec<f64>,
    up: Vec<f64>,
    ticks: u32,
    latency: u32,
    jitter: u32,
}

impl Flow {
    /// Une suite déjà remplie, qui se termine sur les valeurs de repos.
    pub fn new(seed: u32) -> Self {
        let mut flow = Flow {
            rng: seed | 1,
            down: vec![REST_DOWN],
            up: vec![REST_UP],
            ticks: 0,
            latency: REST_LATENCY,
            jitter: REST_JITTER,
        };
        for _ in 0..POINTS {
            flow.push();
        }
        flow.down.push(REST_DOWN);
        flow.up.push(REST_UP);
        flow.trim();
        flow
    }

    /// Un nombre entre 0 et 1 (xorshift32).
    fn random(&mut self) -> f64 {
        self.rng ^= self.rng << 13;
        self.rng ^= self.rng >> 17;
        self.rng ^= self.rng << 5;
        f64::from(self.rng) / f64::from(u32::MAX)
    }

    fn push(&mut self) {
        let down = self.down.last().copied().unwrap_or(REST_DOWN);
        let up = self.up.last().copied().unwrap_or(REST_UP);
        // Une marche aléatoire, rappelée vers la valeur de repos.
        let down = down + (self.random() - 0.5) * 8.0 + (REST_DOWN - down) * 0.18;
        let up = up + (self.random() - 0.5) * 2.4 + (REST_UP - up) * 0.2;
        self.down.push(down.clamp(26.0, 55.0));
        self.up.push(up.clamp(4.5, 13.0));
    }

    /// Garde un point de plus que la courbe n'en montre : celui qui entre par la droite.
    fn trim(&mut self) {
        let extra = self.down.len().saturating_sub(POINTS + 1);
        self.down.drain(..extra);
        self.up.drain(..extra);
    }

    /// Une seconde passe : une nouvelle mesure de débit, et, toutes les cinq secondes,
    /// une nouvelle mesure de latence et de gigue.
    pub fn step(&mut self) {
        self.push();
        self.trim();
        self.ticks += 1;
        if self.ticks.is_multiple_of(5) {
            self.latency = 24 + (self.random() * 9.0) as u32;
            self.jitter = 2 + (self.random() * 4.0) as u32;
        }
    }

    /// Les débits descendants, du plus ancien au plus récent.
    pub fn down(&self) -> &[f64] {
        &self.down
    }

    /// Les débits montants, du plus ancien au plus récent.
    pub fn up(&self) -> &[f64] {
        &self.up
    }

    /// La dernière mesure : descendant, montant.
    pub fn latest(&self) -> (f64, f64) {
        (
            self.down.last().copied().unwrap_or(REST_DOWN),
            self.up.last().copied().unwrap_or(REST_UP),
        )
    }

    pub fn latency(&self) -> u32 {
        self.latency
    }

    pub fn jitter(&self) -> u32 {
        self.jitter
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn starts_on_the_resting_values() {
        let flow = Flow::new(7);
        assert_eq!(flow.down().len(), POINTS + 1);
        assert_eq!(flow.up().len(), POINTS + 1);
        assert_eq!(flow.latest(), (REST_DOWN, REST_UP));
        assert_eq!((flow.latency(), flow.jitter()), (REST_LATENCY, REST_JITTER));
    }

    #[test]
    fn stays_inside_the_chart() {
        let mut flow = Flow::new(2026);
        for _ in 0..2000 {
            flow.step();
            let (down, up) = flow.latest();
            assert!((26.0..=55.0).contains(&down) && down < SCALE_MAX);
            assert!((4.5..=13.0).contains(&up));
            assert!((24..=33).contains(&flow.latency()));
            assert!((2..=6).contains(&flow.jitter()));
            assert_eq!(flow.down().len(), POINTS + 1);
        }
    }

    #[test]
    fn measures_latency_every_five_seconds() {
        let mut flow = Flow::new(11);
        let mut changes = 0;
        let mut last = (flow.latency(), flow.jitter());
        for tick in 1..=100 {
            flow.step();
            let now = (flow.latency(), flow.jitter());
            if now != last {
                assert_eq!(tick % 5, 0, "changement hors cadence à {tick}");
                changes += 1;
                last = now;
            }
        }
        assert!(changes > 5);
    }

    #[test]
    fn the_same_seed_gives_the_same_flow() {
        let (mut a, mut b) = (Flow::new(42), Flow::new(42));
        for _ in 0..50 {
            a.step();
            b.step();
        }
        assert_eq!(a.down(), b.down());
        assert_ne!(a.down(), Flow::new(43).down());
    }
}
