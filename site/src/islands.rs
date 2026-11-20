//! Les îlots : les parties de la page qui réagissent dans le navigateur. Le serveur les
//! rend en HTML ; le bundle WebAssembly, compilé à partir des mêmes fonctions, les rend
//! interactifs.

use paquets::active::Dom;
use paquets::prelude::*;

use crate::demo::{REST_DOWN, REST_JITTER, REST_LATENCY, REST_UP};
use crate::profiles::{self, PROFILES, Part};

/// Un îlot : une fonction qui reçoit ses props et renvoie sa vue.
pub type Island = fn(&str) -> Node;

/// Les îlots du site, par nom : la liste que le navigateur hydrate.
pub const ISLANDS: [(&str, Island); 3] = [
    ("menu", menu),
    ("dashboard", dashboard),
    ("profile-lab", profile_lab),
];

/// Les liens du menu : l'ancre de la page d'accueil et son libellé.
const MENU: [(&str, &str); 5] = [
    ("#fonctions", "Fonctions"),
    ("#profils", "Profils"),
    ("#transparence", "Transparence"),
    ("#confidentialite", "Confidentialité"),
    ("#faq", "Questions"),
];

/// Le menu de l'en-tête. C'est un `<details>` : il s'ouvre et se ferme sans script.
/// L'îlot ajoute une seule chose, le refermer quand on suit un de ses liens.
///
/// Les props sont le préfixe des liens : vide sur la page d'accueil, l'adresse de
/// l'accueil ailleurs.
pub fn menu(props: &str) -> Node {
    let prefix = props.to_owned();
    let open = use_state(false);
    let links = MENU.map(|(anchor, label)| {
        li().child(
            a().href(format!("{prefix}{anchor}"))
                .on_click(move |_| open.set(false))
                .text(label),
        )
    });
    details()
        .class("menu")
        .bool_attr("open", move || open.get())
        .on("toggle", move |event| open.set(is_open(&event)))
        .child(
            summary()
                .class("menu-btn")
                .child(span().class("menu-btn__bars").attr("aria-hidden", "true"))
                .child(span().class("menu-btn__label--open").text("Menu"))
                .child(span().class("menu-btn__label--close").text("Fermer")),
        )
        .child(
            nav()
                .class("nav")
                .attr("aria-label", "Navigation principale")
                .child(ul().children(links))
                .child(
                    a().class("btn btn--primary btn--sm")
                        .href(format!("{prefix}#telecharger"))
                        .on_click(move |_| open.set(false))
                        .text("Disponibilité"),
                ),
        )
        .into()
}

/// Si le `<details>` qui a émis l'événement est ouvert.
#[cfg(target_arch = "wasm32")]
fn is_open(event: &Event) -> bool {
    use wasm_bindgen::JsCast;
    event
        .raw()
        .target()
        .and_then(|target| target.dyn_into::<web_sys::Element>().ok())
        .is_some_and(|details| details.has_attribute("open"))
}

#[cfg(not(target_arch = "wasm32"))]
fn is_open(_event: &Event) -> bool {
    false
}

/// Les mesures affichées par le tableau de bord de démonstration.
#[derive(Clone, Copy)]
pub struct Readings {
    pub down: State<f64>,
    pub up: State<f64>,
    pub latency: State<u32>,
    pub jitter: State<u32>,
}

/// Un débit à une décimale, à la française : `42,8`.
fn one_decimal(value: f64) -> String {
    format!("{value:.1}").replace('.', ",")
}

/// Une tuile du tableau de bord : un libellé, une valeur et son unité.
fn tile(label: &'static str, value: Element, unit: &'static str) -> Element {
    div()
        .child(dt().text(label))
        .child(dd().child(value).child(text(" ")).child(small().text(unit)))
}

/// L'écran de l'app dans le téléphone de démonstration : débits, courbe, latence et
/// gigue. Le serveur le rend avec les valeurs de repos ; dans le navigateur, une mesure
/// fictive arrive chaque seconde.
pub fn dashboard(_props: &str) -> Node {
    let readings = Readings {
        down: use_state(REST_DOWN),
        up: use_state(REST_UP),
        latency: use_state(REST_LATENCY),
        jitter: use_state(REST_JITTER),
    };
    let Readings {
        down,
        up,
        latency,
        jitter,
    } = readings;
    div()
        .class("app")
        .child(
            div()
                .class("app__bar")
                .child(span().class("app__title").text("Tableau de bord"))
                .child(span().class("pill pill--ok").text("Connecté")),
        )
        .child(
            div()
                .class("app__net")
                .child(span().class("tag").text("5G"))
                .child(span().text("Réseau mobile")),
        )
        .child(p().class("app__label").text("Débit descendant"))
        .child(
            p().class("app__big")
                .child(span().text_dyn(move || one_decimal(down.get())))
                .child(small().text("Mb/s")),
        )
        .child(
            p().class("app__up")
                .child(text("↑ "))
                .child(span().text_dyn(move || one_decimal(up.get())))
                .child(text(" Mb/s montant")),
        )
        .child(
            canvas()
                .class("app__chart")
                .attr("role", "img")
                .attr(
                    "aria-label",
                    "Courbe de démonstration des débits descendant et montant sur les trente dernières secondes, échelle de 0 à 60 Mb/s",
                )
                .use_action(move |canvas| play(canvas, readings)),
        )
        .child(
            dl().class("app__tiles")
                .child(tile(
                    "Latence",
                    span().text_dyn(move || latency.get().to_string()),
                    "ms",
                ))
                .child(tile(
                    "Gigue",
                    span().text_dyn(move || jitter.get().to_string()),
                    "ms",
                ))
                .child(tile("Aujourd’hui", span().text("1,2"), "Go"))
                .child(tile("Profil", span().text("Streaming"), "simulé")),
        )
        .child(
            ul().class("app__tabs")
                .attr("aria-hidden", "true")
                .child(li().attr("aria-current", "page").text("Réseau"))
                .child(li().text("Partage"))
                .child(li().text("Profils"))
                .child(li().text("Historique")),
        )
        .child(div().class("app__home").attr("aria-hidden", "true"))
        .into()
}

/// Dans le navigateur : dessine la courbe et fait arriver les mesures.
#[cfg(target_arch = "wasm32")]
fn play(canvas: &Dom, readings: Readings) -> impl FnOnce() + use<> {
    crate::client::chart::start(canvas, readings)
}

/// Sur le serveur, le canvas reste vide.
#[cfg(not(target_arch = "wasm32"))]
fn play(_canvas: &Dom, _readings: Readings) -> impl FnOnce() + use<> {
    || {}
}

/// Une jauge de plafond : son nom, sa valeur et sa position sur l'échelle.
fn meter(
    kind: &'static str,
    label: &'static str,
    value_class: &'static str,
    cap: impl Fn() -> Option<f64> + Copy + 'static,
) -> Element {
    div()
        .class("meter")
        .class(kind)
        .child(
            div()
                .class("meter__row")
                .child(span().class("meter__name").text(label))
                .child(
                    span()
                        .class("meter__val")
                        .class(value_class)
                        .text_dyn(move || profiles::cap_label(cap())),
                ),
        )
        .child(
            div().class("meter__track").child(
                div()
                    .class("meter__fill")
                    .class_if("is-open", move || cap().is_none())
                    .style_dyn("width", move || {
                        let position = cap().map_or(100.0, profiles::scale_position);
                        format!("{position:.1}%")
                    }),
            ),
        )
}

/// Une ligne du verdict : ce qui est demandé, et le statut réel.
fn verdict(label: &'static str, pill: &'static str, status: &'static str) -> Element {
    div()
        .child(dt().text(label))
        .child(dd().child(span().class("pill").class(pill).text(status)))
}

/// Le laboratoire des profils : on choisit un profil, la page montre le plafond
/// enregistré, ce qu'iOS en fait, et l'effet simulé sur le débit mesuré.
///
/// Les props sont le numéro du profil affiché à l'ouverture.
pub fn profile_lab(props: &str) -> Node {
    let first = props
        .parse::<usize>()
        .ok()
        .filter(|index| *index < PROFILES.len())
        .unwrap_or(profiles::DEFAULT);
    let selected = use_state(first);
    let profile = move || PROFILES[selected.get()];
    let chips = PROFILES.iter().enumerate().map(move |(index, preset)| {
        button()
            .class("chip")
            .attr("type", "button")
            .attr_dyn("aria-pressed", move || {
                (selected.get() == index).to_string()
            })
            .on_click(move |_| selected.set(index))
            .text(preset.name)
    });
    div()
        .class("lab")
        .id("lab")
        .child(
            div()
                .class("lab__chips")
                .attr("role", "group")
                .attr("aria-label", "Profil de connexion")
                .children(chips),
        )
        .child(
            div()
                .class("lab__panel")
                .child(
                    div()
                        .class("meters")
                        .child(meter("meter--down", "↓ Plafond descendant", "dn", move || {
                            profile().down
                        }))
                        .child(meter("meter--up", "↑ Plafond montant", "upc", move || {
                            profile().up
                        }))
                        .child(
                            div()
                                .child(
                                    div().class("scale").attr("aria-hidden", "true").children(
                                        ["0,1", "1", "10", "100", "1 000"]
                                            .map(|tick| span().text(tick)),
                                    ),
                                )
                                .child(
                                    p().class("scale__unit")
                                        .text("Mb/s, échelle logarithmique"),
                                ),
                        ),
                )
                .child(
                    dl().class("verdict")
                        .child(verdict("Enregistré dans FLUXA", "pill--ok", "Configuré"))
                        .child(verdict(
                            "Appliqué au partage de connexion",
                            "pill--no",
                            "Réservé à iOS",
                        ))
                        .child(verdict("Statut affiché dans l’app", "pill--sim", "Simulé")),
                )
                .child(
                    p().class("lab__effect")
                        .id("lab-effect")
                        .attr("aria-live", "polite")
                        .children_dyn(move || {
                            profiles::effect(&profile())
                                .into_iter()
                                .map(|part| match part {
                                    Part::Text(words) => text(words),
                                    Part::Value(value) => strong().text(value).into(),
                                })
                                .collect()
                        }),
                ),
        )
        .child(
            div()
                .class("lab__side")
                .child(h3().text("Des préréglages, pas des promesses"))
                .child(p().text(
                    "Les valeurs d’un profil sont des points de départ que vous modifiez librement. Ce ne sont pas des débits garantis.",
                ))
                .child(p().text(
                    "Vous réglez aussi la façon de limiter et la durée, d’une minute à sans limite de temps.",
                ))
                .child(
                    ul().class("modes")
                        .attr("aria-label", "Modes de limitation configurables")
                        .children(
                            [
                                "Plafond strict",
                                "Débit cible",
                                "Partage équitable",
                                "Priorités",
                                "Plage horaire",
                                "Réduction d’urgence",
                            ]
                            .map(|mode| li().text(mode)),
                        ),
                ),
        )
        .into()
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn the_menu_prefixes_its_links() {
        let home = menu("").render();
        assert!(home.contains(r##"href="#fonctions""##));
        let elsewhere = menu("/FLUXA/").render();
        assert!(elsewhere.contains(r##"href="/FLUXA/#telecharger""##));
        assert!(!elsewhere.contains(" open"), "le menu est fermé au départ");
    }

    #[test]
    fn the_dashboard_renders_the_resting_values() {
        let html = dashboard("").render();
        assert!(html.contains("42,8"));
        assert!(html.contains("8,4"));
        assert!(html.contains("<canvas"));
    }

    #[test]
    fn the_lab_opens_on_the_default_profile() {
        let html = profile_lab("").render();
        assert_eq!(html.matches(r#"aria-pressed="true""#).count(), 1);
        assert!(html.contains("25\u{a0}Mb/s"));
        assert!(
            html.contains("width:59.9%") || html.contains("width: 59.9%"),
            "{html}"
        );
        let maximum = profile_lab("6").render();
        assert!(maximum.contains("Sans plafond"));
        assert!(maximum.contains("is-open"));
    }
}
