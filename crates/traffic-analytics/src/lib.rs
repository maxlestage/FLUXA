//! Analyse du trafic mesuré : agrégats par période, moyennes, pics, comparaisons
//! et détection des saturations. Fonctions pures sur des séries de mesures.

use serde::{Deserialize, Serialize};

pub const MINUTE_MS: i64 = 60_000;
pub const HOUR_MS: i64 = 3_600_000;
pub const DAY_MS: i64 = 86_400_000;

/// Une mesure de débit, couvrant `interval_ms` avant `timestamp_ms`.
#[derive(Debug, Clone, Copy, PartialEq, Eq, Serialize, Deserialize)]
pub struct Sample {
    pub timestamp_ms: i64,
    pub interval_ms: u64,
    pub download_bps: u64,
    pub upload_bps: u64,
    pub rx_bytes: u64,
    pub tx_bytes: u64,
}

/// Mesures regroupées sur une période.
#[derive(Debug, Clone, Copy, PartialEq, Eq, Serialize, Deserialize)]
pub struct Aggregate {
    pub bucket_start_ms: i64,
    pub bucket_ms: i64,
    pub samples: u32,
    /// Temps réellement mesuré dans la période. L'app ne mesure pas en continu.
    pub measured_ms: u64,
    /// Moyennes sur le temps mesuré : octets × 8 / temps mesuré.
    pub avg_download_bps: u64,
    pub avg_upload_bps: u64,
    pub peak_download_bps: u64,
    pub peak_upload_bps: u64,
    pub rx_bytes: u64,
    pub tx_bytes: u64,
}

/// Début de la période qui contient `timestamp_ms`. `offset_ms` est le décalage du
/// fuseau local par rapport à UTC, pour que les jours commencent à minuit local.
pub fn bucket_start(timestamp_ms: i64, bucket_ms: i64, offset_ms: i64) -> i64 {
    let bucket_ms = bucket_ms.max(1);
    (timestamp_ms + offset_ms).div_euclid(bucket_ms) * bucket_ms - offset_ms
}

fn average_bps(bytes: u64, measured_ms: u64) -> u64 {
    if measured_ms == 0 {
        return 0;
    }
    u64::try_from(u128::from(bytes) * 8 * 1000 / u128::from(measured_ms)).unwrap_or(u64::MAX)
}

#[derive(Default)]
struct Accumulator {
    samples: u32,
    measured_ms: u64,
    peak_download_bps: u64,
    peak_upload_bps: u64,
    rx_bytes: u64,
    tx_bytes: u64,
}

impl Accumulator {
    fn finish(self, bucket_start_ms: i64, bucket_ms: i64) -> Aggregate {
        Aggregate {
            bucket_start_ms,
            bucket_ms,
            samples: self.samples,
            measured_ms: self.measured_ms,
            avg_download_bps: average_bps(self.rx_bytes, self.measured_ms),
            avg_upload_bps: average_bps(self.tx_bytes, self.measured_ms),
            peak_download_bps: self.peak_download_bps,
            peak_upload_bps: self.peak_upload_bps,
            rx_bytes: self.rx_bytes,
            tx_bytes: self.tx_bytes,
        }
    }
}

fn group<T>(
    items: &[T],
    bucket_ms: i64,
    offset_ms: i64,
    timestamp: impl Fn(&T) -> i64,
    mut add: impl FnMut(&mut Accumulator, &T),
) -> Vec<Aggregate> {
    let mut buckets: std::collections::BTreeMap<i64, Accumulator> =
        std::collections::BTreeMap::new();
    for item in items {
        let start = bucket_start(timestamp(item), bucket_ms, offset_ms);
        add(buckets.entry(start).or_default(), item);
    }
    buckets
        .into_iter()
        .map(|(start, accumulator)| accumulator.finish(start, bucket_ms))
        .collect()
}

/// Regroupe des mesures par période. Le résultat est trié ; une période sans
/// mesure n'apparaît pas.
pub fn aggregate(samples: &[Sample], bucket_ms: i64, offset_ms: i64) -> Vec<Aggregate> {
    group(
        samples,
        bucket_ms,
        offset_ms,
        |sample| sample.timestamp_ms,
        |acc, sample| {
            acc.samples = acc.samples.saturating_add(1);
            acc.measured_ms = acc.measured_ms.saturating_add(sample.interval_ms);
            acc.peak_download_bps = acc.peak_download_bps.max(sample.download_bps);
            acc.peak_upload_bps = acc.peak_upload_bps.max(sample.upload_bps);
            acc.rx_bytes = acc.rx_bytes.saturating_add(sample.rx_bytes);
            acc.tx_bytes = acc.tx_bytes.saturating_add(sample.tx_bytes);
        },
    )
}

/// Regroupe des agrégats en périodes plus longues (des heures en jours, par exemple).
pub fn merge(aggregates: &[Aggregate], bucket_ms: i64, offset_ms: i64) -> Vec<Aggregate> {
    group(
        aggregates,
        bucket_ms,
        offset_ms,
        |aggregate| aggregate.bucket_start_ms,
        |acc, aggregate| {
            acc.samples = acc.samples.saturating_add(aggregate.samples);
            acc.measured_ms = acc.measured_ms.saturating_add(aggregate.measured_ms);
            acc.peak_download_bps = acc.peak_download_bps.max(aggregate.peak_download_bps);
            acc.peak_upload_bps = acc.peak_upload_bps.max(aggregate.peak_upload_bps);
            acc.rx_bytes = acc.rx_bytes.saturating_add(aggregate.rx_bytes);
            acc.tx_bytes = acc.tx_bytes.saturating_add(aggregate.tx_bytes);
        },
    )
}

/// Bilan d'une période : consommation, moyennes et pics.
#[derive(Debug, Clone, Copy, PartialEq, Eq, Default, Serialize, Deserialize)]
pub struct Summary {
    pub samples: u32,
    pub measured_ms: u64,
    pub rx_bytes: u64,
    pub tx_bytes: u64,
    pub avg_download_bps: u64,
    pub avg_upload_bps: u64,
    pub peak_download_bps: u64,
    pub peak_upload_bps: u64,
}

impl Summary {
    pub fn total_bytes(&self) -> u64 {
        self.rx_bytes.saturating_add(self.tx_bytes)
    }
}

/// Fait le bilan d'une suite d'agrégats.
pub fn summarize(aggregates: &[Aggregate]) -> Summary {
    let mut acc = Accumulator::default();
    for aggregate in aggregates {
        acc.samples = acc.samples.saturating_add(aggregate.samples);
        acc.measured_ms = acc.measured_ms.saturating_add(aggregate.measured_ms);
        acc.peak_download_bps = acc.peak_download_bps.max(aggregate.peak_download_bps);
        acc.peak_upload_bps = acc.peak_upload_bps.max(aggregate.peak_upload_bps);
        acc.rx_bytes = acc.rx_bytes.saturating_add(aggregate.rx_bytes);
        acc.tx_bytes = acc.tx_bytes.saturating_add(aggregate.tx_bytes);
    }
    let total = acc.finish(0, 0);
    Summary {
        samples: total.samples,
        measured_ms: total.measured_ms,
        rx_bytes: total.rx_bytes,
        tx_bytes: total.tx_bytes,
        avg_download_bps: total.avg_download_bps,
        avg_upload_bps: total.avg_upload_bps,
        peak_download_bps: total.peak_download_bps,
        peak_upload_bps: total.peak_upload_bps,
    }
}

/// Évolution de la consommation entre deux périodes : +0,25 pour 25 % de plus.
/// `None` quand la période précédente est vide.
pub fn usage_change(current: &Summary, previous: &Summary) -> Option<f64> {
    let before = previous.total_bytes();
    if before == 0 {
        return None;
    }
    Some((current.total_bytes() as f64 - before as f64) / before as f64)
}

/// Un épisode pendant lequel le débit descendant est resté proche de la capacité.
#[derive(Debug, Clone, Copy, PartialEq, Eq, Serialize, Deserialize)]
pub struct Saturation {
    pub start_ms: i64,
    pub end_ms: i64,
    pub peak_download_bps: u64,
}

/// Réglages de la détection de saturation.
#[derive(Debug, Clone, Copy, PartialEq)]
pub struct SaturationRule {
    /// Capacité de référence : un plafond configuré ou le débit maximal observé.
    pub capacity_bps: u64,
    /// Part de la capacité à partir de laquelle le lien est considéré saturé.
    pub threshold: f64,
    /// Durée minimale d'un épisode.
    pub min_duration_ms: i64,
    /// Écart maximal entre deux mesures d'un même épisode.
    pub max_gap_ms: i64,
}

impl SaturationRule {
    /// 90 % de la capacité pendant au moins dix secondes.
    pub const fn for_capacity(capacity_bps: u64) -> Self {
        SaturationRule {
            capacity_bps,
            threshold: 0.9,
            min_duration_ms: 10_000,
            max_gap_ms: 5_000,
        }
    }
}

/// Repère les épisodes de saturation dans des mesures triées par date.
pub fn detect_saturation(samples: &[Sample], rule: SaturationRule) -> Vec<Saturation> {
    if rule.capacity_bps == 0 {
        return Vec::new();
    }
    let limit = rule.capacity_bps as f64 * rule.threshold;
    let mut episodes = Vec::new();
    let mut current: Option<Saturation> = None;
    let close = |episode: Option<Saturation>, episodes: &mut Vec<Saturation>| {
        if let Some(episode) = episode
            && episode.end_ms - episode.start_ms >= rule.min_duration_ms
        {
            episodes.push(episode);
        }
    };
    for sample in samples {
        let saturated = sample.download_bps as f64 >= limit;
        let start_ms = sample.timestamp_ms - i64::try_from(sample.interval_ms).unwrap_or(0);
        match current {
            Some(mut episode) if saturated && start_ms - episode.end_ms <= rule.max_gap_ms => {
                episode.end_ms = sample.timestamp_ms;
                episode.peak_download_bps = episode.peak_download_bps.max(sample.download_bps);
                current = Some(episode);
            }
            _ => {
                close(current.take(), &mut episodes);
                if saturated {
                    current = Some(Saturation {
                        start_ms,
                        end_ms: sample.timestamp_ms,
                        peak_download_bps: sample.download_bps,
                    });
                }
            }
        }
    }
    close(current, &mut episodes);
    episodes
}

#[cfg(test)]
mod tests {
    use super::*;

    /// Une mesure d'une seconde à `second`, à `down`/`up` Mb/s.
    fn sample(second: i64, down_mbps: u64, up_mbps: u64) -> Sample {
        Sample {
            timestamp_ms: second * 1000,
            interval_ms: 1000,
            download_bps: down_mbps * 1_000_000,
            upload_bps: up_mbps * 1_000_000,
            rx_bytes: down_mbps * 125_000,
            tx_bytes: up_mbps * 125_000,
        }
    }

    #[test]
    fn buckets_start_on_local_boundaries() {
        assert_eq!(bucket_start(3_725_000, HOUR_MS, 0), 3_600_000);
        assert_eq!(bucket_start(-1, HOUR_MS, 0), -HOUR_MS, "avant l'époque");
        // À UTC+2, le 2 janvier 1970 local commence le 1er à 22 h UTC.
        let offset = 2 * HOUR_MS;
        assert_eq!(bucket_start(DAY_MS, DAY_MS, offset), DAY_MS - offset);
        assert_eq!(bucket_start(DAY_MS - offset - 1, DAY_MS, offset), -offset);
        // Fuseau à la demi-heure (UTC+5:30).
        let offset = 5 * HOUR_MS + 30 * MINUTE_MS;
        assert_eq!(bucket_start(0, HOUR_MS, offset), -30 * MINUTE_MS);
    }

    #[test]
    fn aggregates_average_peak_and_volume_per_minute() {
        let samples = [
            sample(1, 10, 2),
            sample(2, 30, 4),
            sample(59, 20, 6),
            sample(61, 40, 8),
        ];
        let minutes = aggregate(&samples, MINUTE_MS, 0);
        assert_eq!(minutes.len(), 2);
        let first = minutes[0];
        assert_eq!(first.bucket_start_ms, 0);
        assert_eq!(first.samples, 3);
        assert_eq!(first.measured_ms, 3000);
        assert_eq!(first.avg_download_bps, 20_000_000);
        assert_eq!(first.avg_upload_bps, 4_000_000);
        assert_eq!(first.peak_download_bps, 30_000_000);
        assert_eq!(first.peak_upload_bps, 6_000_000);
        assert_eq!(first.rx_bytes, 60 * 125_000);
        assert_eq!(minutes[1].bucket_start_ms, MINUTE_MS);
        assert_eq!(minutes[1].avg_download_bps, 40_000_000);
    }

    #[test]
    fn averages_are_weighted_by_measured_time() {
        // 10 Mb/s pendant 9 s puis 100 Mb/s pendant 1 s : 19 Mb/s, pas 55.
        let long = Sample {
            timestamp_ms: 9000,
            interval_ms: 9000,
            download_bps: 10_000_000,
            upload_bps: 0,
            rx_bytes: 9 * 1_250_000,
            tx_bytes: 0,
        };
        let short = Sample {
            timestamp_ms: 10_000,
            interval_ms: 1000,
            download_bps: 100_000_000,
            upload_bps: 0,
            rx_bytes: 12_500_000,
            tx_bytes: 0,
        };
        let minute = aggregate(&[long, short], MINUTE_MS, 0)[0];
        assert_eq!(minute.avg_download_bps, 19_000_000);
        assert_eq!(minute.peak_download_bps, 100_000_000);
    }

    #[test]
    fn merging_hours_into_days_matches_direct_aggregation() {
        let samples: Vec<Sample> = (0..5000)
            .map(|i| sample(i * 37, (i % 50 + 1) as u64, (i % 7) as u64))
            .collect();
        let offset = HOUR_MS; // UTC+1
        let hours = aggregate(&samples, HOUR_MS, offset);
        let days_from_hours = merge(&hours, DAY_MS, offset);
        let days = aggregate(&samples, DAY_MS, offset);
        assert!(days.len() >= 2);
        assert_eq!(days_from_hours, days);
        assert_eq!(summarize(&hours), summarize(&days));
    }

    #[test]
    fn empty_input_gives_empty_output() {
        assert!(aggregate(&[], HOUR_MS, 0).is_empty());
        assert!(merge(&[], DAY_MS, 0).is_empty());
        assert_eq!(summarize(&[]), Summary::default());
    }

    #[test]
    fn summarizes_and_compares_two_periods() {
        let today = aggregate(&[sample(1, 40, 8), sample(2, 20, 4)], HOUR_MS, 0);
        let yesterday = aggregate(&[sample(1, 40, 8)], HOUR_MS, 0);
        let (today, yesterday) = (summarize(&today), summarize(&yesterday));
        assert_eq!(today.total_bytes(), 72 * 125_000);
        assert_eq!(today.avg_download_bps, 30_000_000);
        assert_eq!(today.peak_download_bps, 40_000_000);
        assert_eq!(usage_change(&today, &yesterday), Some(0.5));
        assert_eq!(usage_change(&yesterday, &today), Some(-1.0 / 3.0));
        assert_eq!(usage_change(&today, &Summary::default()), None);
    }

    #[test]
    fn detects_sustained_saturation_only() {
        let rule = SaturationRule::for_capacity(50_000_000);
        let mut samples = Vec::new();
        // 3 s proches de la capacité : trop court.
        samples.extend((1..=3).map(|s| sample(s, 48, 1)));
        samples.extend((4..=20).map(|s| sample(s, 10, 1)));
        // 15 s à 45–50 Mb/s : un épisode.
        samples.extend((21..=35).map(|s| sample(s, 45 + (s % 6) as u64, 1)));
        samples.extend((36..=40).map(|s| sample(s, 5, 1)));

        let episodes = detect_saturation(&samples, rule);
        assert_eq!(episodes.len(), 1, "{episodes:?}");
        assert_eq!(episodes[0].start_ms, 20_000);
        assert_eq!(episodes[0].end_ms, 35_000);
        assert_eq!(episodes[0].peak_download_bps, 50_000_000);
    }

    #[test]
    fn a_gap_in_the_measurements_splits_an_episode() {
        let rule = SaturationRule::for_capacity(50_000_000);
        let mut samples: Vec<Sample> = (1..=12).map(|s| sample(s, 50, 1)).collect();
        // L'app est restée fermée une minute.
        samples.extend((73..=84).map(|s| sample(s, 50, 1)));
        let episodes = detect_saturation(&samples, rule);
        assert_eq!(episodes.len(), 2);
        assert_eq!((episodes[0].start_ms, episodes[0].end_ms), (0, 12_000));
        assert_eq!((episodes[1].start_ms, episodes[1].end_ms), (72_000, 84_000));
    }

    #[test]
    fn no_capacity_means_no_saturation() {
        let samples: Vec<Sample> = (1..=30).map(|s| sample(s, 50, 1)).collect();
        assert!(detect_saturation(&samples, SaturationRule::for_capacity(0)).is_empty());
        // Sous le seuil de 90 %.
        assert!(detect_saturation(&samples, SaturationRule::for_capacity(60_000_000)).is_empty());
    }
}
