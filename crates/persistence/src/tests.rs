use super::*;
use shared_types::Capability;
use traffic_analytics::MINUTE_MS;

/// 1er mars 2026 à 12 h UTC.
const NOON: i64 = 1_772_366_400_000;

fn sample(timestamp_ms: i64, down_mbps: u64, up_mbps: u64) -> Sample {
    Sample {
        timestamp_ms,
        interval_ms: 1000,
        download_bps: down_mbps * 1_000_000,
        upload_bps: up_mbps * 1_000_000,
        rx_bytes: down_mbps * 125_000,
        tx_bytes: up_mbps * 125_000,
    }
}

fn store() -> Store {
    Store::open_in_memory().unwrap()
}

fn simulated(policy: BandwidthPolicy, at: i64) -> ApplyResult {
    ApplyResult {
        requested: policy,
        effective: None,
        status: ApplyStatus::Simulated,
        reason: Some("iOS ne laisse aucune application agir sur le partage.".into()),
        capability: Capability::HotspotShaping,
        decided_at_ms: at,
    }
}

#[test]
fn a_new_base_has_the_schema_and_the_seven_presets() {
    let store = store();
    let stats = store.stats().unwrap();
    assert_eq!(stats.schema_version, schema::CURRENT_VERSION);
    assert_eq!(stats.profiles, 7);
    assert_eq!(stats.samples, 0);
    assert_eq!(stats.oldest_sample_ms, None);
    let names: Vec<String> = store
        .profiles()
        .unwrap()
        .into_iter()
        .map(|p| p.name)
        .collect();
    assert_eq!(names[0], "Économie");
    assert_eq!(names[6], "Maximum");
}

#[test]
fn reopening_a_file_keeps_data_and_does_not_duplicate_presets() {
    let dir = std::env::temp_dir().join(format!("fluxa-test-{}-{NOON}", std::process::id()));
    std::fs::create_dir_all(&dir).unwrap();
    let path = dir.join("fluxa.sqlite");
    {
        let store = Store::open(&path).unwrap();
        let session = store.start_session(NOON, NetworkKind::Wifi).unwrap();
        store
            .insert_sample(
                Some(session),
                &sample(NOON + 1000, 42, 8),
                NetworkKind::Wifi,
            )
            .unwrap();
        store.set_setting("latency_host", "www.apple.com").unwrap();
    }
    let store = Store::open(&path).unwrap();
    let stats = store.stats().unwrap();
    assert_eq!((stats.samples, stats.profiles, stats.sessions), (1, 7, 1));
    assert_eq!(
        store.setting("latency_host").unwrap().as_deref(),
        Some("www.apple.com")
    );
    assert_eq!(
        store.samples_between(NOON, NOON + 2000).unwrap(),
        vec![sample(NOON + 1000, 42, 8)]
    );
    drop(store);
    std::fs::remove_dir_all(&dir).unwrap();
}

#[test]
fn samples_are_read_back_in_order_within_bounds() {
    let store = store();
    for offset in [3000, 1000, 2000] {
        store
            .insert_sample(None, &sample(NOON + offset, 10, 1), NetworkKind::Cellular5G)
            .unwrap();
    }
    let read = store.samples_between(NOON + 1000, NOON + 3000).unwrap();
    let times: Vec<i64> = read.iter().map(|s| s.timestamp_ms - NOON).collect();
    assert_eq!(times, vec![1000, 2000], "borne haute exclue");
}

#[test]
fn stale_sessions_are_closed_at_their_last_sample() {
    let store = store();
    let crashed = store.start_session(NOON, NetworkKind::Wifi).unwrap();
    store
        .insert_sample(Some(crashed), &sample(NOON + 5000, 1, 1), NetworkKind::Wifi)
        .unwrap();
    let empty = store
        .start_session(NOON + 10_000, NetworkKind::Wifi)
        .unwrap();
    let clean = store
        .start_session(NOON + 20_000, NetworkKind::Wifi)
        .unwrap();
    store.end_session(clean, NOON + 30_000).unwrap();

    assert_eq!(store.close_stale_sessions().unwrap(), 2);
    let ended = |id: i64| -> i64 {
        store
            .connection
            .query_row(
                "SELECT ended_at_ms FROM network_sessions WHERE id = ?1",
                params![id],
                |r| r.get(0),
            )
            .unwrap()
    };
    assert_eq!(ended(crashed), NOON + 5000);
    assert_eq!(ended(empty), NOON + 10_000);
    assert_eq!(ended(clean), NOON + 30_000);
}

#[test]
fn rollup_builds_hourly_then_daily_records() {
    let mut store = store();
    // Trois heures de mesures : 11 h, 12 h et 13 h UTC.
    for (hour_offset, mbps) in [(-1i64, 10u64), (0, 20), (1, 40)] {
        for second in 1..=10 {
            let at = NOON + hour_offset * HOUR_MS + second * 1000;
            store
                .insert_sample(None, &sample(at, mbps, 2), NetworkKind::Wifi)
                .unwrap();
        }
    }
    let now = NOON + 2 * HOUR_MS;
    store.rollup(now, 0).unwrap();

    let hours = store
        .usage_between(Granularity::Hour, NOON - DAY_MS, now)
        .unwrap();
    assert_eq!(hours.len(), 3);
    assert_eq!(hours[0].bucket_start_ms, NOON - HOUR_MS);
    assert_eq!(hours[1].avg_download_bps, 20_000_000);
    assert_eq!(hours[2].peak_download_bps, 40_000_000);
    assert_eq!(hours[2].samples, 10);

    let days = store
        .usage_between(Granularity::Day, NOON - DAY_MS, now)
        .unwrap();
    assert_eq!(days.len(), 1);
    assert_eq!(days[0].bucket_start_ms, NOON - 12 * HOUR_MS);
    assert_eq!(days[0].samples, 30);
    assert_eq!(days[0].rx_bytes, (10 + 20 + 40) * 10 * 125_000);
    assert_eq!(days[0].peak_download_bps, 40_000_000);
}

#[test]
fn rollup_is_incremental_and_idempotent() {
    let mut store = store();
    for second in 1..=5 {
        store
            .insert_sample(
                None,
                &sample(NOON + second * 1000, 10, 1),
                NetworkKind::Wifi,
            )
            .unwrap();
    }
    store.rollup(NOON + MINUTE_MS, 0).unwrap();
    store.rollup(NOON + MINUTE_MS, 0).unwrap();
    let first = store
        .usage_between(Granularity::Hour, NOON, NOON + HOUR_MS)
        .unwrap();
    assert_eq!(first[0].samples, 5);

    // De nouvelles mesures dans la même heure complètent le même agrégat.
    for second in 6..=10 {
        store
            .insert_sample(
                None,
                &sample(NOON + second * 1000, 30, 1),
                NetworkKind::Wifi,
            )
            .unwrap();
    }
    store.rollup(NOON + 2 * MINUTE_MS, 0).unwrap();
    let hours = store
        .usage_between(Granularity::Hour, NOON, NOON + HOUR_MS)
        .unwrap();
    assert_eq!(hours.len(), 1);
    assert_eq!(hours[0].samples, 10);
    assert_eq!(hours[0].avg_download_bps, 20_000_000);
    let days = store
        .usage_between(Granularity::Day, NOON - DAY_MS, NOON + DAY_MS)
        .unwrap();
    assert_eq!(days[0].samples, 10);
}

#[test]
fn days_start_at_local_midnight() {
    let mut store = store();
    // 23 h 30 UTC le 1er mars : déjà le 2 mars à UTC+1.
    let late = NOON + 11 * HOUR_MS + 30 * MINUTE_MS;
    store
        .insert_sample(None, &sample(late, 10, 1), NetworkKind::Wifi)
        .unwrap();
    store.rollup(late + MINUTE_MS, HOUR_MS).unwrap();
    let days = store
        .usage_between(Granularity::Day, NOON - 2 * DAY_MS, NOON + 2 * DAY_MS)
        .unwrap();
    assert_eq!(days.len(), 1);
    assert_eq!(
        days[0].bucket_start_ms,
        NOON + 11 * HOUR_MS,
        "minuit local = 23 h UTC"
    );
}

#[test]
fn retention_keeps_7_days_30_days_and_12_months() {
    let mut store = store();
    let now = NOON + 400 * DAY_MS;
    let day = |n: i64| now - n * DAY_MS;

    // Une mesure à différents âges, agrégée au fil de l'eau comme le ferait l'app.
    for age in [400, 366, 364, 31, 29, 8, 6, 0] {
        let at = day(age) - HOUR_MS;
        store
            .insert_sample(None, &sample(at, 10, 1), NetworkKind::Wifi)
            .unwrap();
        store.rollup(at + MINUTE_MS, 0).unwrap();
    }
    assert_eq!(store.stats().unwrap().samples, 8);
    assert_eq!(store.stats().unwrap().hourly_records, 8);
    assert_eq!(store.stats().unwrap().daily_records, 8);

    let report = store.apply_retention(now).unwrap();
    assert_eq!(
        report.samples, 6,
        "seules les mesures de moins de 7 jours restent"
    );
    assert_eq!(report.hourly, 4, "agrégats horaires : 30 jours");
    assert_eq!(report.daily, 2, "agrégats journaliers : 12 mois");

    let stats = store.stats().unwrap();
    assert_eq!(
        (stats.samples, stats.hourly_records, stats.daily_records),
        (2, 4, 6)
    );
    // Un second passage ne supprime plus rien.
    assert_eq!(
        store.apply_retention(now).unwrap(),
        RetentionReport::default()
    );
}

#[test]
fn daily_records_survive_the_purge_of_their_details() {
    let mut store = store();
    let old = NOON;
    for second in 1..=3 {
        store
            .insert_sample(None, &sample(old + second * 1000, 20, 4), NetworkKind::Wifi)
            .unwrap();
    }
    // L'app reste fermée 40 jours : l'agrégation passe avant la purge.
    let now = old + 40 * DAY_MS;
    store.rollup(now, 0).unwrap();
    store.apply_retention(now).unwrap();
    let stats = store.stats().unwrap();
    assert_eq!(
        (stats.samples, stats.hourly_records, stats.daily_records),
        (0, 0, 1)
    );
    // Un passage ultérieur ne doit pas écraser le jour avec des données purgées.
    store.rollup(now + DAY_MS, 0).unwrap();
    let days = store
        .usage_between(Granularity::Day, old - DAY_MS, now + 2 * DAY_MS)
        .unwrap();
    assert_eq!(days.len(), 1);
    assert_eq!(days[0].samples, 3);
}

#[test]
fn profiles_can_be_added_edited_and_removed_but_presets_stay() {
    let store = store();
    let custom = Profile {
        id: "visio".into(),
        name: "Visio".into(),
        download_bps: Some(8_000_000),
        upload_bps: Some(4_000_000),
        builtin: false,
    };
    store.save_profile(&custom).unwrap();
    assert_eq!(store.profiles().unwrap().last().unwrap(), &custom);

    // Modifier un préréglage change ses valeurs, pas sa nature.
    let mut streaming = store.profile("streaming").unwrap().unwrap();
    streaming.download_bps = Some(30_000_000);
    streaming.builtin = false; // ignoré
    store.save_profile(&streaming).unwrap();
    let saved = store.profile("streaming").unwrap().unwrap();
    assert_eq!(saved.download_bps, Some(30_000_000));
    assert!(saved.builtin);
    assert_eq!(
        store.profiles().unwrap()[4].id,
        "streaming",
        "l'ordre ne change pas"
    );

    assert!(matches!(
        store.delete_profile("streaming"),
        Err(NetworkError::InvalidInput(_))
    ));
    assert!(matches!(
        store.delete_profile("absent"),
        Err(NetworkError::NotFound(_))
    ));
    store.delete_profile("visio").unwrap();
    assert_eq!(store.profiles().unwrap().len(), 7);

    store.reset_builtin_profiles().unwrap();
    assert_eq!(
        store.profile("streaming").unwrap().unwrap().download_bps,
        Some(25_000_000)
    );
}

#[test]
fn the_policy_log_keeps_what_was_asked_and_what_happened() {
    let mut store = store();
    let mut timed = BandwidthPolicy::hard(25_000_000, 10_000_000);
    timed.duration_seconds = Some(600);
    timed.mode = LimitMode::Priority;
    store
        .record_policy("global", &simulated(timed, NOON))
        .unwrap();

    let partial = ApplyResult {
        requested: BandwidthPolicy::hard(5_000_000, 2_000_000),
        effective: Some(BandwidthPolicy {
            download_bps: Some(6_000_000),
            upload_bps: None,
            mode: LimitMode::HardLimit,
            duration_seconds: None,
        }),
        status: ApplyStatus::Partial,
        reason: None,
        capability: Capability::PerDeviceShaping,
        decided_at_ms: NOON + 1000,
    };
    store.record_policy("device:device_001", &partial).unwrap();

    let history = store.policy_history(10).unwrap();
    assert_eq!(history.len(), 2);
    assert_eq!(history[0].target, "device:device_001");
    assert_eq!(history[0].result, partial);
    assert_eq!(history[1].target, "global");
    assert_eq!(history[1].result, simulated(timed, NOON));
    assert_eq!(store.policy_history(1).unwrap().len(), 1);
}

#[test]
fn the_policy_log_is_kept_until_a_duration_is_chosen() {
    let mut store = store();
    let policy = BandwidthPolicy::hard(5_000_000, 2_000_000);
    store
        .record_policy("global", &simulated(policy, NOON))
        .unwrap();
    store
        .record_policy("global", &simulated(policy, NOON + 20 * DAY_MS))
        .unwrap();
    let now = NOON + 25 * DAY_MS;

    assert_eq!(store.apply_retention(now).unwrap().policies, 0);
    store.set_setting(POLICY_HISTORY_DAYS_KEY, "10").unwrap();
    assert_eq!(store.apply_retention(now).unwrap().policies, 1);
    let history = store.policy_history(10).unwrap();
    assert_eq!(history.len(), 1);
    assert_eq!(history[0].result.decided_at_ms, NOON + 20 * DAY_MS);
    // Le résultat d'application part avec sa règle.
    let applications: i64 = store
        .connection
        .query_row("SELECT COUNT(*) FROM policy_applications", [], |r| r.get(0))
        .unwrap();
    assert_eq!(applications, 1);
}

#[test]
fn settings_are_upserted_and_removed() {
    let store = store();
    assert_eq!(store.setting("k").unwrap(), None);
    store.set_setting("k", "1").unwrap();
    store.set_setting("k", "2").unwrap();
    assert_eq!(store.setting("k").unwrap().as_deref(), Some("2"));
    store.remove_setting("k").unwrap();
    assert_eq!(store.setting("k").unwrap(), None);
}

fn fill(store: &mut Store) {
    let session = store.start_session(NOON, NetworkKind::Wifi).unwrap();
    store
        .insert_sample(
            Some(session),
            &sample(NOON + 1000, 10, 1),
            NetworkKind::Wifi,
        )
        .unwrap();
    store.rollup(NOON + MINUTE_MS, 0).unwrap();
    store
        .record_policy(
            "global",
            &simulated(BandwidthPolicy::hard(5_000_000, 2_000_000), NOON),
        )
        .unwrap();
    store
        .save_profile(&Profile {
            id: "visio".into(),
            name: "Visio".into(),
            download_bps: None,
            upload_bps: None,
            builtin: false,
        })
        .unwrap();
    store.set_setting("active_profile_id", "visio").unwrap();
}

#[test]
fn erasing_the_history_keeps_profiles_and_settings() {
    let mut store = store();
    fill(&mut store);
    store.erase_history().unwrap();
    let stats = store.stats().unwrap();
    assert_eq!(
        (
            stats.samples,
            stats.sessions,
            stats.hourly_records,
            stats.daily_records,
            stats.policies
        ),
        (0, 0, 0, 0, 0)
    );
    assert_eq!(stats.profiles, 8);
    assert_eq!(
        store.setting("active_profile_id").unwrap().as_deref(),
        Some("visio")
    );
    // L'agrégation repart de zéro sans erreur.
    store.rollup(NOON + HOUR_MS, 0).unwrap();
    assert_eq!(store.stats().unwrap().hourly_records, 0);
}

#[test]
fn erasing_everything_leaves_only_the_original_presets() {
    let mut store = store();
    fill(&mut store);
    let mut streaming = store.profile("streaming").unwrap().unwrap();
    streaming.download_bps = Some(1_000_000);
    store.save_profile(&streaming).unwrap();

    store.erase_all().unwrap();
    let stats = store.stats().unwrap();
    assert_eq!((stats.samples, stats.policies, stats.profiles), (0, 0, 7));
    assert_eq!(store.setting("active_profile_id").unwrap(), None);
    assert_eq!(store.profiles().unwrap(), builtin_profiles());
}
