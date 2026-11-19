use super::*;
use traffic_analytics::{DAY_MS, HOUR_MS};

/// 1er mars 2026 à 12 h UTC.
const NOON: i64 = 1_772_366_400_000;

fn config(path: Option<PathBuf>) -> EngineConfig {
    EngineConfig {
        database_path: path,
        context: PlatformContext::ios(),
        counter_width: CounterWidth::Bits32,
        utc_offset_seconds: 0,
    }
}

fn engine() -> (Engine, Arc<ManualClock>) {
    let clock = Arc::new(ManualClock::at(NOON));
    let engine = Engine::open_with_clock(config(None), clock.clone()).unwrap();
    (engine, clock)
}

fn cellular(rx: u64, tx: u64) -> Vec<InterfaceReading> {
    vec![InterfaceReading {
        name: "pdp_ip0".into(),
        class: InterfaceClass::Cellular,
        rx_bytes: rx,
        tx_bytes: tx,
    }]
}

/// Fait mesurer `seconds` secondes à `down`/`up` Mb/s sur le réseau mobile.
fn measure(
    engine: &Engine,
    clock: &ManualClock,
    counters: &mut (u64, u64),
    seconds: u64,
    down: u64,
    up: u64,
) {
    for _ in 0..seconds {
        clock.advance(1000);
        counters.0 += down * 125_000;
        counters.1 += up * 125_000;
        engine
            .ingest_counters(&cellular(counters.0, counters.1))
            .unwrap();
    }
}

fn started() -> (Engine, Arc<ManualClock>, (u64, u64)) {
    let (engine, clock) = engine();
    engine.update_path(NetworkKind::Cellular5G, true);
    engine.start().unwrap();
    let counters = (1_000_000, 1_000_000);
    assert_eq!(
        engine
            .ingest_counters(&cellular(counters.0, counters.1))
            .unwrap(),
        None
    );
    (engine, clock, counters)
}

#[test]
fn starts_quickly_with_ios_capabilities() {
    let began = std::time::Instant::now();
    let (engine, _) = engine();
    assert!(
        began.elapsed().as_millis() < 500,
        "objectif : démarrage en moins de 500 ms"
    );

    let capabilities = engine.capabilities();
    let support = |capability| {
        capabilities
            .iter()
            .find(|status| status.capability == capability)
            .unwrap()
            .support
    };
    assert_eq!(support(Capability::InternetMonitoring), Support::Supported);
    assert_eq!(support(Capability::HotspotActivation), Support::Unsupported);
    assert_eq!(support(Capability::PerDeviceShaping), Support::Unsupported);
    assert!(engine.capabilities_json().contains("\"platform\": \"ios\""));
    assert_eq!(engine.profiles().unwrap().len(), 7);
    assert!(!engine.is_monitoring());
}

#[test]
fn measures_stores_and_reports_throughput() {
    let (engine, clock, mut counters) = started();
    clock.advance(1000);
    counters.0 += 5_350_000;
    counters.1 += 1_050_000;
    let throughput = engine
        .ingest_counters(&cellular(counters.0, counters.1))
        .unwrap()
        .unwrap();
    assert_eq!(throughput.download_bps, 42_800_000);
    assert_eq!(throughput.upload_bps, 8_400_000);
    assert_eq!(
        throughput.scope,
        MeasurementScope::DeviceInterfaces(InterfaceClass::Cellular)
    );

    engine.record_latency(Some(28.0)).unwrap();
    engine.record_latency(Some(32.0)).unwrap();
    let snapshot = engine.get_snapshot().unwrap();
    assert_eq!(snapshot.timestamp_ms, NOON + 1000);
    assert_eq!(snapshot.kind, NetworkKind::Cellular5G);
    assert!(snapshot.monitoring && snapshot.online);
    assert_eq!(snapshot.throughput, Some(throughput));
    assert_eq!(snapshot.latency_ms, Some(32.0));
    assert_eq!(snapshot.jitter_ms, Some(4.0));
    assert_eq!(snapshot.loss_ratio, Some(0.0));

    assert_eq!(engine.diagnostics().unwrap().store.samples, 1);
}

#[test]
fn nothing_is_measured_or_stored_while_stopped() {
    let (engine, clock) = engine();
    engine.update_path(NetworkKind::Wifi, true);
    clock.advance(1000);
    assert_eq!(engine.ingest_counters(&cellular(10, 10)).unwrap(), None);
    engine.record_latency(Some(20.0)).unwrap();
    let snapshot = engine.snapshot();
    assert!(!snapshot.monitoring);
    assert_eq!(snapshot.throughput, None);
    assert_eq!(
        snapshot.latency_ms, None,
        "une valeur absente reste absente"
    );
    assert_eq!(engine.diagnostics().unwrap().store.samples, 0);
}

#[test]
fn start_and_stop_delimit_a_session() {
    let (engine, clock, mut counters) = started();
    engine.start().unwrap(); // sans effet
    measure(&engine, &clock, &mut counters, 3, 10, 1);
    engine.stop().unwrap();
    engine.stop().unwrap(); // sans effet
    let diagnostics = engine.diagnostics().unwrap();
    assert_eq!(diagnostics.store.sessions, 1);
    assert_eq!(diagnostics.store.samples, 3);
    assert!(!diagnostics.monitoring);
    assert_eq!(diagnostics.events[0].message, "Surveillance arrêtée.");

    // Après une pause, le premier relevé ne sert que de base.
    clock.advance(600_000);
    engine.start().unwrap();
    counters.0 += 900_000_000;
    assert_eq!(
        engine
            .ingest_counters(&cellular(counters.0, counters.1))
            .unwrap(),
        None
    );
    assert_eq!(engine.diagnostics().unwrap().store.sessions, 2);
}

#[test]
fn activating_a_profile_is_simulated_on_ios_and_remembered() {
    let dir = std::env::temp_dir().join(format!("fluxa-core-{}", std::process::id()));
    std::fs::create_dir_all(&dir).unwrap();
    let path = dir.join("fluxa.sqlite");
    let clock = Arc::new(ManualClock::at(NOON));
    {
        let engine = Engine::open_with_clock(config(Some(path.clone())), clock.clone()).unwrap();
        assert_eq!(engine.active_profile_id(), None);
        let result = engine.activate_profile("streaming").unwrap();
        assert_eq!(result.status, ApplyStatus::Simulated);
        assert_eq!(result.effective, None);
        assert_eq!(result.requested.download_bps, Some(25_000_000));
        assert!(result.reason.is_some());
        assert!(matches!(
            engine.activate_profile("absent"),
            Err(NetworkError::NotFound(_))
        ));
        assert_eq!(engine.active_profile_id().as_deref(), Some("streaming"));
    }
    // Au redémarrage : même profil actif, même statut, pas de doublon dans le journal.
    let engine = Engine::open_with_clock(config(Some(path)), clock).unwrap();
    assert_eq!(engine.active_profile_id().as_deref(), Some("streaming"));
    assert_eq!(
        engine.global_limit().unwrap().status,
        ApplyStatus::Simulated
    );
    assert_eq!(engine.policy_history(10).unwrap().len(), 1);
    drop(engine);
    std::fs::remove_dir_all(&dir).unwrap();
}

#[test]
fn limits_are_logged_with_their_real_status() {
    let (engine, clock) = engine();
    engine.activate_profile("navigation").unwrap();
    clock.advance(1000);
    let mut manual = BandwidthPolicy::hard(12_000_000, 3_000_000);
    manual.mode = LimitMode::SoftLimit;
    manual.duration_seconds = Some(300);
    let global = engine.set_global_limit(manual).unwrap();
    assert_eq!(global.status, ApplyStatus::Simulated);
    assert_eq!(
        engine.active_profile_id(),
        None,
        "une limite manuelle remplace le profil"
    );

    clock.advance(1000);
    let device = DeviceId::new("device_001").unwrap();
    let per_device = engine
        .set_device_limit(device, BandwidthPolicy::hard(20_000_000, 5_000_000))
        .unwrap();
    assert_eq!(per_device.status, ApplyStatus::Unsupported);
    assert_eq!(per_device.capability, Capability::PerDeviceShaping);

    let history = engine.policy_history(10).unwrap();
    let log: Vec<(&str, ApplyStatus)> = history
        .iter()
        .map(|r| (r.target.as_str(), r.result.status))
        .collect();
    assert_eq!(
        log,
        vec![
            ("device:device_001", ApplyStatus::Unsupported),
            ("global", ApplyStatus::Simulated),
            ("global", ApplyStatus::Simulated),
        ]
    );
    assert!(
        history
            .iter()
            .all(|record| !record.result.status.is_effective())
    );

    // Une politique invalide n'entre ni dans l'état ni dans le journal.
    assert!(
        engine
            .set_global_limit(BandwidthPolicy::hard(1, 1))
            .is_err()
    );
    assert!(
        engine
            .set_global_limit(BandwidthPolicy::hard(0, 0))
            .is_err()
    );
    assert_eq!(engine.policy_history(10).unwrap().len(), 3);
    assert_eq!(engine.global_limit().unwrap().requested, manual);
}

#[test]
fn a_timed_limit_expires_during_maintenance() {
    let (engine, clock) = engine();
    let mut timed = BandwidthPolicy::hard(5_000_000, 2_000_000);
    timed.duration_seconds = Some(60);
    engine.set_global_limit(timed).unwrap();
    clock.advance(59_000);
    assert_eq!(engine.run_maintenance().unwrap().expired_policies, 0);
    clock.advance(1000);
    assert_eq!(engine.run_maintenance().unwrap().expired_policies, 1);
    assert_eq!(engine.global_limit(), None);
}

#[test]
fn simulation_needs_a_measurement() {
    let (engine, clock, mut counters) = started();
    let streaming = BandwidthPolicy::hard(25_000_000, 10_000_000);
    assert_eq!(engine.simulate(&streaming).unwrap(), None);

    clock.advance(1000);
    counters.0 += 5_350_000;
    counters.1 += 1_050_000;
    engine
        .ingest_counters(&cellular(counters.0, counters.1))
        .unwrap();
    let simulation = engine.simulate(&streaming).unwrap().unwrap();
    assert_eq!(simulation.download.measured_bps, 42_800_000);
    assert_eq!(simulation.download.resulting_bps, 25_000_000);
    assert!(simulation.download.limited);
    assert!(!simulation.upload.limited);
    assert!(engine.simulate(&BandwidthPolicy::hard(5, 5)).is_err());
}

#[test]
fn custom_profiles_follow_validation_and_drive_the_active_limit() {
    let (engine, clock) = engine();
    assert!(engine.save_profile(None, "  ", None, None).is_err());
    assert!(engine.save_profile(None, "Trop", Some(5), None).is_err());
    assert!(
        engine
            .save_profile(Some("absent"), "Nom", None, None)
            .is_err()
    );

    let visio = engine
        .save_profile(None, " Visio ", Some(8_000_000), Some(4_000_000))
        .unwrap();
    assert_eq!(visio.name, "Visio");
    assert!(!visio.builtin);
    clock.advance(5);
    let second = engine.save_profile(None, "Jeu", None, None).unwrap();
    assert_ne!(visio.id, second.id);
    assert_eq!(engine.profiles().unwrap().len(), 9);

    engine.activate_profile(&visio.id).unwrap();
    // Modifier le profil actif met à jour la limite en vigueur.
    engine
        .save_profile(
            Some(&visio.id),
            "Visio HD",
            Some(12_000_000),
            Some(4_000_000),
        )
        .unwrap();
    assert_eq!(
        engine.global_limit().unwrap().requested.download_bps,
        Some(12_000_000)
    );

    engine.delete_profile(&visio.id).unwrap();
    assert_eq!(engine.active_profile_id(), None);
    assert_eq!(engine.global_limit(), None);
    assert!(
        engine.delete_profile("streaming").is_err(),
        "un préréglage ne se supprime pas"
    );
}

#[test]
fn history_comes_by_minute_hour_and_day() {
    let (engine, clock, mut counters) = started();
    measure(&engine, &clock, &mut counters, 90, 20, 4);
    clock.advance(HOUR_MS as u64);
    // Après une heure sans relevé, le premier relevé couvrirait l'heure entière.
    engine.stop().unwrap();
    engine.start().unwrap();
    engine
        .ingest_counters(&cellular(counters.0, counters.1))
        .unwrap();
    measure(&engine, &clock, &mut counters, 30, 40, 8);

    let now = NOON + 90_000 + HOUR_MS + 30_000;
    let minutes = engine
        .history(NOON, NOON + 120_000, HistoryStep::Minute)
        .unwrap();
    assert_eq!(minutes.len(), 2);
    assert_eq!(minutes[0].samples, 59, "de 12:00:01 à 12:00:59");
    assert_eq!(minutes[0].avg_download_bps, 20_000_000);

    let hours = engine.history(NOON, now + 1, HistoryStep::Hour).unwrap();
    assert_eq!(hours.len(), 2);
    assert_eq!(hours[0].samples, 90);
    assert_eq!(hours[1].avg_download_bps, 40_000_000);

    let days = engine
        .history(NOON - DAY_MS, now + 1, HistoryStep::Day)
        .unwrap();
    assert_eq!(days.len(), 1);
    assert_eq!(days[0].samples, 120);

    let usage = engine.usage(NOON, now + 1).unwrap();
    assert_eq!(usage.rx_bytes, (90 * 20 + 30 * 40) * 125_000);
    assert_eq!(usage.peak_download_bps, 40_000_000);
    assert!(engine.history(now, NOON, HistoryStep::Hour).is_err());
}

#[test]
fn maintenance_applies_retention() {
    let (engine, clock, mut counters) = started();
    measure(&engine, &clock, &mut counters, 5, 10, 1);
    assert_eq!(
        engine.run_maintenance().unwrap().retention,
        RetentionReport::default()
    );
    engine.stop().unwrap();

    clock.advance(8 * DAY_MS as u64);
    let report = engine.run_maintenance().unwrap();
    assert_eq!(report.retention.samples, 5);
    assert_eq!(report.retention.sessions, 1);
    let stats = engine.diagnostics().unwrap().store;
    assert_eq!(
        (stats.samples, stats.hourly_records, stats.daily_records),
        (0, 1, 1)
    );
}

#[test]
fn erasing_history_keeps_measuring() {
    let (engine, clock, mut counters) = started();
    measure(&engine, &clock, &mut counters, 5, 10, 1);
    engine.activate_profile("standard").unwrap();
    engine.erase_history().unwrap();

    let diagnostics = engine.diagnostics().unwrap();
    assert_eq!(diagnostics.store.samples, 0);
    assert_eq!(diagnostics.store.policies, 0);
    assert_eq!(
        diagnostics.store.sessions, 1,
        "la session en cours est rouverte"
    );
    assert_eq!(diagnostics.events.len(), 1);
    assert_eq!(engine.active_profile_id().as_deref(), Some("standard"));

    measure(&engine, &clock, &mut counters, 2, 10, 1);
    assert_eq!(engine.diagnostics().unwrap().store.samples, 2);
}

#[test]
fn erasing_everything_resets_profiles_and_limits() {
    let (engine, _, _) = started();
    engine
        .save_profile(None, "Visio", Some(8_000_000), None)
        .unwrap();
    engine.activate_profile("standard").unwrap();
    engine.set_latency_host("example.org").unwrap();
    engine.set_policy_history_days(Some(30)).unwrap();
    engine.erase_all().unwrap();

    assert_eq!(engine.profiles().unwrap().len(), 7);
    assert_eq!(engine.active_profile_id(), None);
    assert_eq!(engine.global_limit(), None);
    assert_eq!(engine.latency_host().unwrap(), DEFAULT_LATENCY_HOST);
    assert_eq!(engine.policy_history_days().unwrap(), None);
    assert_eq!(engine.policy_history(10).unwrap().len(), 0);
}

#[test]
fn the_event_log_is_bounded() {
    let (engine, _) = engine();
    for round in 0..150 {
        let kind = if round % 2 == 0 {
            NetworkKind::Wifi
        } else {
            NetworkKind::Cellular4G
        };
        engine.update_path(kind, true);
        engine
            .set_global_limit(BandwidthPolicy::hard(5_000_000, 2_000_000))
            .unwrap();
    }
    assert_eq!(engine.diagnostics().unwrap().events.len(), MAX_EVENTS);
}

#[test]
fn the_engine_is_shareable_between_threads() {
    fn assert_send_sync<T: Send + Sync>() {}
    assert_send_sync::<Engine>();
}

#[test]
fn inputs_are_checked_before_reaching_the_modules() {
    let (engine, clock, counters) = started();
    let mut twice = cellular(counters.0, counters.1);
    twice.extend(cellular(counters.0, counters.1));
    assert!(matches!(
        engine.ingest_counters(&twice),
        Err(NetworkError::InvalidInput(_))
    ));
    assert!(engine.record_latency(Some(f64::NAN)).is_err());
    assert!(engine.record_latency(Some(-3.0)).is_err());
    assert_eq!(
        engine.snapshot().loss_ratio,
        None,
        "une sonde refusée ne compte pas"
    );
    assert!(engine.set_utc_offset_seconds(90_000).is_err());
    assert!(engine.history(-5, 10, HistoryStep::Hour).is_err());
    assert!(engine.history(0, 40 * DAY_MS, HistoryStep::Hour).is_err());

    let far = EngineConfig {
        utc_offset_seconds: 100_000,
        ..config(None)
    };
    assert!(Engine::open_with_clock(far, clock).is_err());
}

#[test]
fn settings_are_typed_and_validated() {
    let (engine, _) = engine();
    assert_eq!(engine.latency_host().unwrap(), DEFAULT_LATENCY_HOST);
    assert_eq!(
        engine.set_latency_host(" One.One.One.One ").unwrap(),
        "one.one.one.one"
    );
    assert_eq!(engine.latency_host().unwrap(), "one.one.one.one");
    assert!(engine.set_latency_host("https://exemple.fr/").is_err());

    assert_eq!(engine.policy_history_days().unwrap(), None);
    engine.set_policy_history_days(Some(30)).unwrap();
    assert_eq!(engine.policy_history_days().unwrap(), Some(30));
    engine.set_policy_history_days(None).unwrap();
    assert_eq!(engine.policy_history_days().unwrap(), None);
    assert!(engine.set_policy_history_days(Some(0)).is_err());
}

#[test]
fn the_local_day_follows_the_utc_offset() {
    let (engine, clock, mut counters) = started();
    // 23 h 30 UTC : déjà le lendemain à UTC+1.
    clock.advance(11 * HOUR_MS as u64 + 30 * 60_000);
    engine.stop().unwrap();
    engine.start().unwrap();
    engine
        .ingest_counters(&cellular(counters.0, counters.1))
        .unwrap();
    measure(&engine, &clock, &mut counters, 5, 10, 1);
    engine.set_utc_offset_seconds(3600).unwrap();
    let days = engine
        .history(NOON - DAY_MS, NOON + 2 * DAY_MS, HistoryStep::Day)
        .unwrap();
    assert_eq!(days.len(), 1);
    assert_eq!(
        days[0].bucket_start_ms,
        NOON + 11 * HOUR_MS,
        "minuit local = 23 h UTC"
    );
}

#[test]
fn saturation_is_detected_against_a_capacity() {
    let (engine, clock, mut counters) = started();
    measure(&engine, &clock, &mut counters, 5, 10, 1);
    measure(&engine, &clock, &mut counters, 15, 48, 4);
    measure(&engine, &clock, &mut counters, 5, 10, 1);
    let episodes = engine
        .saturation_episodes(NOON, NOON + 60_000, 50_000_000)
        .unwrap();
    assert_eq!(episodes.len(), 1);
    assert_eq!(episodes[0].end_ms - episodes[0].start_ms, 15_000);
    assert_eq!(episodes[0].peak_download_bps, 48_000_000);
    assert!(
        engine
            .saturation_episodes(NOON, NOON + 60_000, 0)
            .unwrap()
            .is_empty()
    );
}

#[test]
fn the_ios_configuration_matches_the_v1() {
    let config = EngineConfig::ios(None);
    assert_eq!(config.context, PlatformContext::ios());
    assert_eq!(config.counter_width, CounterWidth::Bits32);
    assert_eq!(config.utc_offset_seconds, 0);
}
