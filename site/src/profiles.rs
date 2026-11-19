//! Les profils de débit et la simulation d'un plafond sur un débit mesuré.
//!
//! Sur iPhone, un plafond réglé dans FLUXA n'est pas appliqué au partage de
//! connexion : l'app en montre l'effet simulé. Ce module calcule cette simulation,
//! pour la démonstration du site.

/// Un profil : des plafonds en Mb/s, `None` pour « sans plafond configuré ».
#[derive(Debug, Clone, Copy, PartialEq)]
pub struct Profile {
    pub name: &'static str,
    pub down: Option<f64>,
    pub up: Option<f64>,
}

/// Les sept préréglages de la V1.
pub const PROFILES: [Profile; 7] = [
    Profile {
        name: "Économie",
        down: Some(1.0),
        up: Some(0.5),
    },
    Profile {
        name: "Très lent",
        down: Some(2.0),
        up: Some(1.0),
    },
    Profile {
        name: "Navigation",
        down: Some(5.0),
        up: Some(2.0),
    },
    Profile {
        name: "Standard",
        down: Some(15.0),
        up: Some(5.0),
    },
    Profile {
        name: "Streaming",
        down: Some(25.0),
        up: Some(10.0),
    },
    Profile {
        name: "Performance",
        down: Some(50.0),
        up: Some(20.0),
    },
    Profile {
        name: "Maximum",
        down: None,
        up: None,
    },
];

/// Le profil affiché à l'ouverture de la page.
pub const DEFAULT: usize = 4;

/// Le débit mesuré de la démonstration, en Mb/s.
pub const MEASURED_DOWN: f64 = 42.8;
pub const MEASURED_UP: f64 = 8.4;

/// La plage réglable dans l'app, en Mb/s.
pub const MIN_MBPS: f64 = 0.1;
pub const MAX_MBPS: f64 = 1000.0;

/// La position d'un débit sur l'échelle logarithmique de 0,1 à 1 000 Mb/s, en pour cent.
pub fn scale_position(mbps: f64) -> f64 {
    let value = mbps.clamp(MIN_MBPS, MAX_MBPS);
    let span = (MAX_MBPS / MIN_MBPS).log10();
    (value / MIN_MBPS).log10() / span * 100.0
}

/// Le débit après un plafond : jamais plus que le débit mesuré.
pub fn simulate(measured: f64, cap: Option<f64>) -> f64 {
    cap.map_or(measured, |cap| measured.min(cap))
}

/// Un nombre à la française, avec une décimale au plus : `25`, `0,5`, `42,8`.
pub fn number(value: f64) -> String {
    let rounded = (value * 10.0).round() / 10.0;
    if rounded.fract() == 0.0 {
        format!("{rounded:.0}")
    } else {
        format!("{rounded:.1}").replace('.', ",")
    }
}

/// Un débit avec son unité, l'espace insécable comprise : `25 Mb/s`.
pub fn mbps(value: f64) -> String {
    format!("{}\u{a0}Mb/s", number(value))
}

/// Le texte d'un plafond.
pub fn cap_label(cap: Option<f64>) -> String {
    cap.map_or_else(|| "Sans plafond".to_owned(), mbps)
}

/// Un morceau de la phrase de simulation : du texte, ou une valeur mise en avant.
#[derive(Debug, Clone, PartialEq)]
pub enum Part {
    Text(String),
    Value(String),
}

fn direction(parts: &mut Vec<Part>, name: &str, article: &str, measured: f64, cap: Option<f64>) {
    let after = simulate(measured, cap);
    if after < measured {
        parts.push(Part::Text(format!("{article} {name} passerait de ")));
        parts.push(Part::Value(mbps(measured)));
        parts.push(Part::Text(" à ".to_owned()));
        parts.push(Part::Value(mbps(after)));
    } else {
        parts.push(Part::Text(format!("{article} {name} resterait à ")));
        parts.push(Part::Value(mbps(measured)));
        parts.push(Part::Text(", sous le plafond".to_owned()));
    }
}

/// La phrase qui décrit l'effet simulé d'un profil sur le débit de démonstration.
pub fn effect(profile: &Profile) -> Vec<Part> {
    if profile.down.is_none() && profile.up.is_none() {
        return vec![
            Part::Text("Aucun plafond configuré\u{a0}: le débit mesuré, ".to_owned()),
            Part::Value(mbps(MEASURED_DOWN)),
            Part::Text(" en descendant, resterait inchangé.".to_owned()),
        ];
    }
    let mut parts = vec![Part::Text(
        "Simulation sur le débit mesuré\u{a0}: ".to_owned(),
    )];
    direction(&mut parts, "descendant", "le", MEASURED_DOWN, profile.down);
    parts.push(Part::Text(" et ".to_owned()));
    direction(&mut parts, "montant", "le", MEASURED_UP, profile.up);
    parts.push(Part::Text(".".to_owned()));
    parts
}

#[cfg(test)]
mod tests {
    use super::*;

    fn sentence(profile: &Profile) -> String {
        effect(profile)
            .into_iter()
            .map(|part| match part {
                Part::Text(text) | Part::Value(text) => text,
            })
            .collect()
    }

    #[test]
    fn the_scale_is_logarithmic_from_a_tenth_to_a_thousand() {
        assert_eq!(scale_position(0.1), 0.0);
        assert!((scale_position(1.0) - 25.0).abs() < 1e-9);
        assert!((scale_position(10.0) - 50.0).abs() < 1e-9);
        assert!((scale_position(100.0) - 75.0).abs() < 1e-9);
        assert!((scale_position(1000.0) - 100.0).abs() < 1e-9);
        assert_eq!(scale_position(0.0), 0.0);
        assert_eq!(scale_position(5000.0), 100.0);
    }

    #[test]
    fn a_cap_never_raises_the_measured_rate() {
        assert_eq!(simulate(42.8, Some(25.0)), 25.0);
        assert_eq!(simulate(42.8, Some(50.0)), 42.8);
        assert_eq!(simulate(42.8, None), 42.8);
    }

    #[test]
    fn numbers_are_written_the_french_way() {
        assert_eq!(number(25.0), "25");
        assert_eq!(number(0.5), "0,5");
        assert_eq!(number(42.8), "42,8");
        assert_eq!(mbps(8.4), "8,4\u{a0}Mb/s");
        assert_eq!(cap_label(None), "Sans plafond");
    }

    #[test]
    fn the_sentence_says_what_the_cap_would_do() {
        assert_eq!(
            sentence(&PROFILES[DEFAULT]),
            "Simulation sur le débit mesuré\u{a0}: le descendant passerait de 42,8\u{a0}Mb/s à 25\u{a0}Mb/s et le montant resterait à 8,4\u{a0}Mb/s, sous le plafond."
        );
        assert!(
            sentence(&PROFILES[0])
                .contains("le montant passerait de 8,4\u{a0}Mb/s à 0,5\u{a0}Mb/s")
        );
        assert!(
            sentence(&PROFILES[5])
                .contains("le descendant resterait à 42,8\u{a0}Mb/s, sous le plafond")
        );
        assert!(sentence(&PROFILES[6]).starts_with("Aucun plafond configuré"));
    }

    #[test]
    fn the_presets_match_the_specification() {
        assert_eq!(PROFILES.len(), 7);
        assert_eq!(PROFILES[DEFAULT].name, "Streaming");
        for profile in &PROFILES {
            for cap in [profile.down, profile.up].into_iter().flatten() {
                assert!((MIN_MBPS..=MAX_MBPS).contains(&cap), "{}", profile.name);
            }
        }
    }
}
