//! Vérification des entrées venues de l'interface, avant qu'elles n'atteignent les modules.

use std::collections::HashSet;

use network_monitor::InterfaceReading;
use shared_types::NetworkError;
use traffic_analytics::DAY_MS;

use crate::HistoryStep;

fn invalid(message: &str) -> NetworkError {
    NetworkError::InvalidInput(message.to_string())
}

/// Décalage horaire : au plus 18 heures de part et d'autre d'UTC.
pub fn utc_offset(seconds: i32) -> Result<i32, NetworkError> {
    if (-18 * 3600..=18 * 3600).contains(&seconds) {
        Ok(seconds)
    } else {
        Err(invalid("décalage horaire hors de ±18 heures"))
    }
}

/// Un relevé : 64 interfaces au plus, des noms courts et uniques.
pub fn readings(readings: &[InterfaceReading]) -> Result<(), NetworkError> {
    if readings.len() > 64 {
        return Err(invalid("trop d'interfaces dans le relevé"));
    }
    let mut names = HashSet::new();
    for reading in readings {
        let name = reading.name.as_str();
        let well_formed = (1..=32).contains(&name.len())
            && name
                .bytes()
                .all(|b| b.is_ascii_alphanumeric() || matches!(b, b'_' | b'-' | b'.'));
        if !well_formed {
            return Err(invalid("nom d'interface invalide"));
        }
        if !names.insert(name) {
            return Err(invalid("interface présente deux fois dans le relevé"));
        }
    }
    Ok(())
}

/// Latence : un nombre fini entre 0 et 60 secondes.
pub fn latency(latency_ms: Option<f64>) -> Result<Option<f64>, NetworkError> {
    match latency_ms {
        Some(ms) if !ms.is_finite() || !(0.0..=60_000.0).contains(&ms) => {
            Err(invalid("latence hors de la plage 0 à 60 000 ms"))
        }
        other => Ok(other),
    }
}

/// Période d'historique : dates positives, dans l'ordre, d'une longueur raisonnable
/// pour le pas demandé.
pub fn period(from_ms: i64, to_ms: i64, step: HistoryStep) -> Result<(), NetworkError> {
    if from_ms < 0 || to_ms < from_ms {
        return Err(invalid("période inversée ou antérieure à 1970"));
    }
    let longest = match step {
        HistoryStep::Minute => 7 * DAY_MS,
        HistoryStep::Hour => 31 * DAY_MS,
        HistoryStep::Day => 366 * DAY_MS,
    };
    if to_ms - from_ms > longest {
        return Err(invalid("période trop longue pour ce niveau de détail"));
    }
    Ok(())
}

/// Nom d'hôte : lettres, chiffres, points et tirets, sans schéma ni chemin.
/// Renvoie le nom nettoyé, en minuscules.
pub fn host(host: &str) -> Result<String, NetworkError> {
    let host = host.trim().to_ascii_lowercase();
    let labels_ok = host.split('.').all(|label| {
        (1..=63).contains(&label.len())
            && label
                .bytes()
                .all(|b| b.is_ascii_alphanumeric() || b == b'-')
            && !label.starts_with('-')
            && !label.ends_with('-')
    });
    if (1..=253).contains(&host.len()) && labels_ok {
        Ok(host)
    } else {
        Err(invalid("nom d'hôte invalide"))
    }
}

/// Conservation de l'historique des limites : 1 à 3 650 jours, ou sans limite.
pub fn history_days(days: Option<u32>) -> Result<Option<u32>, NetworkError> {
    match days {
        Some(days) if !(1..=3650).contains(&days) => {
            Err(invalid("durée de conservation hors de 1 à 3 650 jours"))
        }
        other => Ok(other),
    }
}

#[cfg(test)]
mod tests {
    use super::*;
    use shared_types::InterfaceClass;

    fn reading(name: &str) -> InterfaceReading {
        InterfaceReading {
            name: name.to_string(),
            class: InterfaceClass::Wifi,
            rx_bytes: 0,
            tx_bytes: 0,
        }
    }

    #[test]
    fn checks_readings() {
        assert!(readings(&[reading("en0"), reading("pdp_ip0")]).is_ok());
        assert!(readings(&[]).is_ok());
        assert!(readings(&[reading("")]).is_err());
        assert!(readings(&[reading("en 0")]).is_err());
        assert!(readings(&[reading(&"e".repeat(33))]).is_err());
        assert!(readings(&[reading("en0"), reading("en0")]).is_err());
        let many: Vec<_> = (0..65).map(|i| reading(&format!("if{i}"))).collect();
        assert!(readings(&many).is_err());
        assert!(readings(&many[..64]).is_ok());
    }

    #[test]
    fn checks_latencies_and_offsets() {
        assert_eq!(latency(Some(28.0)), Ok(Some(28.0)));
        assert_eq!(latency(None), Ok(None));
        for bad in [f64::NAN, f64::INFINITY, -1.0, 60_001.0] {
            assert!(latency(Some(bad)).is_err(), "{bad}");
        }
        assert_eq!(utc_offset(-36_000), Ok(-36_000));
        assert!(utc_offset(70_000).is_err());
    }

    #[test]
    fn checks_periods() {
        assert!(period(0, 7 * DAY_MS, HistoryStep::Minute).is_ok());
        assert!(period(0, 7 * DAY_MS + 1, HistoryStep::Minute).is_err());
        assert!(period(0, 31 * DAY_MS, HistoryStep::Hour).is_ok());
        assert!(period(0, 366 * DAY_MS, HistoryStep::Day).is_ok());
        assert!(period(0, 400 * DAY_MS, HistoryStep::Day).is_err());
        assert!(period(-1, DAY_MS, HistoryStep::Hour).is_err());
        assert!(period(DAY_MS, 0, HistoryStep::Hour).is_err());
    }

    #[test]
    fn checks_hosts_and_retention() {
        assert_eq!(host("  One.One.One.One ").unwrap(), "one.one.one.one");
        for bad in [
            "",
            "https://exemple.fr",
            "a b",
            "-a.fr",
            "a..fr",
            "exemple.fr/chemin",
        ] {
            assert!(host(bad).is_err(), "{bad}");
        }
        assert_eq!(history_days(Some(30)), Ok(Some(30)));
        assert_eq!(history_days(None), Ok(None));
        assert!(history_days(Some(0)).is_err());
        assert!(history_days(Some(3651)).is_err());
    }
}
