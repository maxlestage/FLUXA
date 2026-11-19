//! Les pages du site : l'accueil, les deux pages légales et la page « introuvable ».
//! Tout est rendu par le serveur ; trois îlots prennent vie dans le navigateur.

use paquets::prelude::*;

use super::Site;
use crate::demo::{Flow, POINTS, SCALE_MAX};
use crate::islands;
use crate::profiles;
use crate::routes::{FONTS, HOME, LEGAL, PRIVACY, SHARE_IMAGE, link};

/// Ce qu'une page doit savoir pour écrire ses liens.
pub struct Ctx<'a> {
    pub site: &'a Site,
    /// Le chemin de la page (`/`, `/confidentialite/`…).
    pub path: &'static str,
    /// L'adresse publique du site, sous-chemin compris.
    pub origin: String,
}

impl Ctx<'_> {
    fn is_home(&self) -> bool {
        self.path == HOME
    }

    /// Le préfixe des ancres de l'accueil : vide sur l'accueil, son adresse ailleurs.
    fn anchors(&self) -> String {
        if self.is_home() {
            String::new()
        } else {
            link(HOME)
        }
    }

    /// Un lien du pied de page ou du texte : une ancre de l'accueil (`#faq`), une page
    /// du site (`/confidentialite/`, avec ou sans ancre) ou une adresse externe.
    fn href(&self, target: &str) -> String {
        if target.starts_with('#') {
            format!("{}{target}", self.anchors())
        } else if target.starts_with('/') {
            link(target)
        } else {
            target.to_owned()
        }
    }
}

const LOGO: &str = r##"<svg width="30" height="30" viewBox="0 0 32 32" aria-hidden="true"><rect width="32" height="32" rx="8" fill="#171b2e"/><path d="M6 13c4 0 4-5 8-5s4 9 8 9 3-3 4-3" fill="none" stroke="#7cd4fd" stroke-width="2.4" stroke-linecap="round"/><path d="M6 22c3 0 4-3 7-3s4 4 7 4 4-2 6-2" fill="none" stroke="#ffb37a" stroke-width="2.4" stroke-linecap="round"/></svg>"##;

const STORE_ICON: &str = r#"<svg width="26" height="26" viewBox="0 0 24 24" fill="none" stroke="currentColor" stroke-width="1.7" stroke-linecap="round" stroke-linejoin="round" aria-hidden="true"><path d="M12 4v10"/><path d="m8 10 4 4 4-4"/><path d="M5 18h14"/></svg>"#;

/// Ce que montre la carte de partage, pour qui ne voit pas l'image.
const SHARE_ALT: &str = "FLUXA pour iPhone : « Votre connexion, mesurée à la seconde. », à côté d’un tableau de bord qui affiche 42,8 Mb/s en débit descendant.";

const DESCRIPTION: &str = "FLUXA mesure le débit, la latence et la consommation de votre iPhone, gère vos profils de débit et vous guide pour partager votre connexion. Sans compte, sans cloud.";

// ---------- Morceaux communs ----------

fn brand(href: String, label: &'static str) -> Element {
    a().class("brand")
        .href(href)
        .attr("aria-label", label)
        .child(span().class("brand__mark").html(LOGO))
        .child(span().class("brand__name").text("FLUXA"))
}

fn pill(kind: &'static str, label: &'static str) -> Element {
    span().class("pill").class(kind).text(label)
}

fn eyebrow(label: &'static str) -> Element {
    p().class("eyebrow").text(label)
}

/// Le pavé « Bientôt sur l'App Store » : une annonce, pas un lien.
fn store_badge() -> Element {
    div()
        .class("store")
        .attr("role", "img")
        .attr("aria-label", "Bientôt disponible sur l’App Store")
        .child(span().class("store__icon").html(STORE_ICON))
        .child(
            span()
                .class("store__txt")
                .child(small().text("Bientôt sur"))
                .child(strong().text("l’App Store")),
        )
}

fn section_head(
    label: &'static str,
    id: &'static str,
    title: &'static str,
    lead: Option<&'static str>,
) -> Element {
    div()
        .class("section__head")
        .child(eyebrow(label))
        .child(h2().id(id).text(title))
        .child(lead.map(|lead| p().text(lead)))
}

fn site_header(ctx: &Ctx) -> Element {
    header().class("header").id("haut").child(
        div()
            .class("wrap header__row")
            .child(brand(
                if ctx.is_home() {
                    "#haut".to_owned()
                } else {
                    link(HOME)
                },
                "FLUXA, accueil",
            ))
            .child(island("menu", ctx.anchors(), islands::menu)),
    )
}

/// La mise en page commune : le `<head>`, l'en-tête, le contenu et le pied de page.
fn layout(ctx: &Ctx, title: &'static str, description: &'static str, content: Element) -> Page {
    let stylesheet = ctx.site.stylesheet();
    // Ce que le navigateur garde pour lire le site hors ligne dès la première visite :
    // les trois pages, la feuille de style, les polices et l'icône.
    let mut offline = vec![link(HOME), link(PRIVACY), link(LEGAL), stylesheet.clone()];
    offline.extend(FONTS.map(link));
    offline.push(link("/favicon.svg"));
    let head = format!(
        r##"<meta name="apple-mobile-web-app-status-bar-style" content="black-translucent"/><meta name="fluxa-offline" content="{offline}"/><link rel="icon" href="{icon}" type="image/svg+xml"/><link rel="preload" href="{font}" as="font" type="font/woff2" crossorigin/>"##,
        offline = offline.join(" "),
        icon = link("/favicon.svg"),
        font = link(FONTS[0]),
    );
    Page::new(title)
        .lang("fr")
        .description(description)
        .plain()
        .stylesheet(stylesheet)
        .head(head)
        .seo(
            Seo::new()
                .site_name("FLUXA")
                .locale("fr_FR")
                .canonical(format!("{}{}", ctx.origin, ctx.path))
                // La carte de partage : une grande image, avec ses dimensions et son texte.
                .image(format!("{}{SHARE_IMAGE}", ctx.origin))
                .meta_property("og:image:type", "image/png")
                .meta_property("og:image:width", "1200")
                .meta_property("og:image:height", "630")
                .meta_property("og:image:alt", SHARE_ALT)
                .meta_name("twitter:image:alt", SHARE_ALT),
        )
        .body(a().class("skip").href("#contenu").text("Aller au contenu"))
        .body(site_header(ctx))
        .body(content)
        .body(site_footer(ctx))
}

// ---------- Accueil ----------

fn hero() -> Element {
    section().class("hero").attr("aria-labelledby", "titre").child(
        div()
            .class("wrap hero__grid")
            .child(
                div()
                    .class("hero__copy")
                    .child(eyebrow("Pour iPhone · V1 en développement"))
                    .child(h1().id("titre").text("Votre connexion, mesurée à la seconde."))
                    .child(p().class("hero__lead").text(
                        "FLUXA suit le débit, la latence et la consommation de votre iPhone, garde vos profils de débit sous la main et vous guide pour partager votre connexion. Tout reste sur l’appareil.",
                    ))
                    .child(
                        div()
                            .class("hero__cta")
                            .child(
                                a().class("btn btn--primary")
                                    .href("#telecharger")
                                    .text("Bientôt sur l’App Store"),
                            )
                            .child(
                                a().class("btn btn--ghost")
                                    .href("#fonctions")
                                    .text("Voir les fonctions"),
                            ),
                    )
                    .child(
                        ul().class("hero__facts")
                            .child(li().text("Sans compte"))
                            .child(li().text("Sans cloud"))
                            .child(li().text("Statut réel de chaque fonction")),
                    ),
            )
            .child(
                figure()
                    .class("phone")
                    .child(
                        div().class("phone__body").child(
                            div()
                                .class("phone__screen")
                                .child(div().class("phone__island").attr("aria-hidden", "true"))
                                .child(island("dashboard", "", islands::dashboard)),
                        ),
                    )
                    .child(figcaption().text(
                        "Aperçu de l’interface avec des données de démonstration, rafraîchies chaque seconde comme dans l’app.",
                    )),
            ),
    )
}

fn cadence() -> Element {
    let rates = [
        ("1 s", "Débit instantané", "dn"),
        ("5 s", "Latence et gigue", ""),
        ("1 à 5 s", "Consommation", ""),
        ("1 min", "Historique", ""),
    ];
    section()
        .class("cadence")
        .attr("aria-label", "Cadences de mesure")
        .child(
            div()
                .class("wrap")
                .child(dl().children(rates.map(|(rate, what, class)| {
                    div()
                        .child(dt().class(class).text(rate))
                        .child(dd().text(what))
                })))
                .child(p().class("cadence__note").text(
                    "Cadences visées quand l’app est au premier plan. iOS limite l’exécution en arrière-plan, et FLUXA ne prétend pas le contraire.",
                )),
        )
}

const OK: (&str, &str) = ("pill--ok", "Pris en charge");
const SIMULATED: (&str, &str) = ("pill--sim", "Simulé");
const GUIDE: (&str, &str) = ("pill--sys", "Guide");
const RESERVED: (&str, &str) = ("pill--no", "Réservé à iOS");

/// Une fonction de l'app : son ancre, son nom, son statut sur iPhone, ce qu'elle
/// fait, et un repère concret (cadence, plage, source).
struct Feature {
    id: &'static str,
    name: &'static str,
    status: (&'static str, &'static str),
    text: &'static str,
    meta: &'static str,
}

const FEATURES: [Feature; 9] = [
    Feature {
        id: "f-tableau",
        name: "Tableau de bord",
        status: OK,
        text: "Débit descendant et montant, latence, gigue, type de réseau et consommation sur un seul écran.",
        meta: "Rafraîchi chaque seconde au premier plan",
    },
    Feature {
        id: "f-test",
        name: "Test de débit",
        status: OK,
        text: "Lancez une mesure quand vous voulez et retrouvez-la dans l’historique, à côté des précédentes.",
        meta: "À la demande",
    },
    Feature {
        id: "f-reseau",
        name: "Mon réseau",
        status: OK,
        text: "Wi-Fi, 4G ou 5G. FLUXA suit les changements de réseau signalés par iOS et vérifie qu’Internet répond.",
        meta: "Sur événement système",
    },
    Feature {
        id: "f-partage",
        name: "Partage de connexion",
        status: GUIDE,
        text: "iOS garde la main sur le partage. Un bouton ouvre les Réglages et un guide vous accompagne jusqu’à l’activation.",
        meta: "Activation dans Réglages iOS",
    },
    Feature {
        id: "f-profils",
        name: "Profils",
        status: OK,
        text: "Sept préréglages, d’Économie à Maximum, tous modifiables. Ajoutez les vôtres et changez de profil d’un geste.",
        meta: "7 préréglages modifiables",
    },
    Feature {
        id: "f-limiteur",
        name: "Limiteur de débit",
        status: SIMULATED,
        text: "Réglez un plafond dans chaque sens. Sur iPhone, FLUXA en simule l’effet sur votre débit mesuré et ne l’annonce jamais comme appliqué au partage.",
        meta: "De 0,1 à 1 000 Mb/s",
    },
    Feature {
        id: "f-historique",
        name: "Historique",
        status: OK,
        text: "Débit et consommation par heure, par jour et par semaine, avec les pics et les saturations repérés.",
        meta: "Agrégé chaque minute",
    },
    Feature {
        id: "f-automatisations",
        name: "Automatisations",
        status: OK,
        text: "Une alerte après un seuil de consommation, un profil selon l’heure, le retour au profil précédent après une durée.",
        meta: "Sur les données locales, pas sur le partage",
    },
    Feature {
        id: "f-diagnostic",
        name: "Centre de diagnostic",
        status: OK,
        text: "Les capacités détectées sur votre iPhone, le journal du moteur et les erreurs, réunis au même endroit.",
        meta: "Capacités vérifiées au démarrage",
    },
];

fn features() -> Element {
    let legend = [OK, SIMULATED, GUIDE, RESERVED].map(|(kind, label)| pill(kind, label));
    section()
        .class("section")
        .id("fonctions")
        .attr("aria-labelledby", "h-fonctions")
        .child(
            div()
                .class("wrap")
                .child(
                    section_head(
                        "Fonctions",
                        "h-fonctions",
                        "Ce que l’app fait sur iPhone",
                        Some(
                            "Chaque fonction porte son statut, comme dans l’app. Vous savez ce qui est pris en charge, ce qui est simulé et ce qu’iOS garde pour lui.",
                        ),
                    )
                    .child(
                        div()
                            .class("legend")
                            .attr("aria-label", "Légende des statuts")
                            .children(legend),
                    ),
                )
                .child(ul().class("feats").children(FEATURES.iter().map(|feature| {
                    li().class("feat")
                        .id(feature.id)
                        .child(
                            div()
                                .class("feat__head")
                                .child(h3().text(feature.name))
                                .child(pill(feature.status.0, feature.status.1)),
                        )
                        .child(p().text(feature.text))
                        .child(p().class("feat__meta").text(feature.meta))
                }))),
        )
}

fn profiles_section() -> Element {
    section()
        .class("section section--alt")
        .id("profils")
        .attr("aria-labelledby", "h-profils")
        .child(
            div()
                .class("wrap")
                .child(section_head(
                    "Profils et limites",
                    "h-profils",
                    "Configuré ne veut pas dire appliqué",
                    Some(
                        "Choisissez un profil. FLUXA enregistre le plafond, vérifie ce que l’iPhone autorise, puis affiche le statut exact.",
                    ),
                ))
                .child(island(
                    "profile-lab",
                    profiles::DEFAULT.to_string(),
                    islands::profile_lab,
                )),
        )
}

fn capability_list(
    title: &'static str,
    rows: &[(&'static str, &'static str, &'static str)],
    note: &'static str,
) -> Element {
    div()
        .child(h3().text(title))
        .child(ul().class("caps__list").children(
            rows.iter().map(|(what, kind, answer)| {
                li().child(span().text(*what)).child(pill(kind, answer))
            }),
        ))
        .child(p().class("caps__note").text(note))
}

/// L'exemple de capacités détectées : la clé, sa valeur et la classe de sa couleur.
const CAPABILITIES: [(&str, &str, &str); 5] = [
    ("internet_monitoring", "true", "t"),
    ("hotspot_activation", "false", "f"),
    ("hotspot_client_discovery", "false", "f"),
    ("per_device_shaping", "false", "f"),
    ("local_vpn", "true", "t"),
];

fn capabilities_json() -> String {
    let mut json = String::from(
        "{\n  <span class=\"k\">\"platform\"</span>: <span class=\"s\">\"ios\"</span>,\n  <span class=\"k\">\"capabilities\"</span>: {\n",
    );
    for (index, (key, value, class)) in CAPABILITIES.iter().enumerate() {
        let comma = if index + 1 < CAPABILITIES.len() {
            ","
        } else {
            ""
        };
        json.push_str(&format!(
            "    <span class=\"k\">\"{key}\"</span>: <span class=\"{class}\">{value}</span>{comma}\n"
        ));
    }
    json.push_str("  }\n}");
    json
}

fn transparency() -> Element {
    section()
        .class("section")
        .id("transparence")
        .attr("aria-labelledby", "h-transparence")
        .child(
            div()
                .class("wrap")
                .child(section_head(
                    "Transparence",
                    "h-transparence",
                    "Ce qu’iOS autorise, sans détour",
                    Some(
                        "Le partage de connexion appartient à iOS. Apple ne l’ouvre pas aux apps, et FLUXA ne cherche pas à contourner cette règle.",
                    ),
                ))
                .child(
                    blockquote()
                        .class("rule")
                        .id("regle")
                        .child(p().text(
                            "Aucune limitation de débit n’est annoncée comme effective tant que le système n’a pas confirmé son application.",
                        ))
                        .child(footer().text("La règle que suit chaque écran de l’app")),
                )
                .child(
                    div()
                        .class("caps")
                        .id("capacites")
                        .child(capability_list(
                            "Ce que FLUXA fait",
                            &[
                                ("Mesurer la connexion de l’iPhone", "pill--ok", "Oui"),
                                ("Tester le débit Internet", "pill--ok", "Oui"),
                                ("Tracer les graphiques et l’historique", "pill--ok", "Oui"),
                                ("Gérer des profils de débit", "pill--ok", "Oui, dans l’app"),
                                ("Créer un VPN local facultatif", "pill--sim", "Sous conditions"),
                            ],
                            "Le VPN local ne traite que le trafic de l’iPhone passé par le tunnel, jamais celui des appareils reliés au partage.",
                        ))
                        .child(capability_list(
                            "Ce qu’iOS garde pour lui",
                            &[
                                ("Activer le partage depuis une app", "pill--no", "Non"),
                                ("Limiter le débit du partage", "pill--no", "Non"),
                                ("Déconnecter un appareil du partage", "pill--no", "Non"),
                                (
                                    "Identifier tous les appareils connectés",
                                    "pill--sim",
                                    "Non garanti",
                                ),
                            ],
                            "Quand une information est inconnue, l’app l’indique. Elle n’invente ni nom d’appareil ni adresse MAC.",
                        )),
                )
                .child(
                    div()
                        .class("code")
                        .child(p().class("code__label").text(
                            "Au démarrage, le moteur détecte ce que votre iPhone permet. L’interface n’affiche que ce qui en découle. Exemple illustratif :",
                        ))
                        .child(pre().child(code().html(capabilities_json()))),
                ),
        )
}

fn commitment(title: &'static str, detail: &'static str) -> Element {
    li().child(div().child(strong().text(title)).child(span().text(detail)))
}

fn privacy_section() -> Element {
    let retention = [
        ("Mesures détaillées", "7 jours", "w-7j"),
        ("Agrégats horaires", "30 jours", "w-30j"),
        ("Agrégats journaliers", "12 mois", "w-12m"),
    ];
    section()
        .class("section section--alt")
        .id("confidentialite")
        .attr("aria-labelledby", "h-confidentialite")
        .child(
            div()
                .class("wrap")
                .child(section_head(
                    "Confidentialité",
                    "h-confidentialite",
                    "Vos mesures restent sur votre iPhone",
                    Some(
                        "FLUXA fonctionne sans compte et sans serveur. Les statistiques sont enregistrées dans une base locale et y restent.",
                    ),
                ))
                .child(
                    div()
                        .class("privacy")
                        .child(
                            div()
                                .child(
                                    ul().class("never")
                                        .child(commitment(
                                            "Aucun contenu de communication collecté",
                                            "L’app compte des octets. Elle ne lit pas ce qu’ils transportent.",
                                        ))
                                        .child(commitment(
                                            "Aucun mot de passe Wi-Fi enregistré",
                                            "FLUXA n’en a pas besoin et n’y accède pas.",
                                        ))
                                        .child(commitment(
                                            "Aucun envoi automatique vers un serveur",
                                            "Il n’y a pas de cloud dans la V1.",
                                        )),
                                )
                                .child(
                                    ul().class("never never--yes")
                                        .child(commitment(
                                            "Autorisations demandées au moment utile",
                                            "Jamais en bloc au premier lancement.",
                                        ))
                                        .child(commitment(
                                            "Informations sensibles chiffrées",
                                            "Par la protection des fichiers d’iOS, dans le stockage de l’app.",
                                        ))
                                        .child(
                                            commitment(
                                                "Tout l’historique effaçable à la demande",
                                                "Une action dans les réglages de l’app supprime l’ensemble.",
                                            )
                                            .id("suppression"),
                                        ),
                                ),
                        )
                        .child(
                            div()
                                .class("retention")
                                .id("conservation")
                                .child(h3().text("Durées de conservation"))
                                .child(ul().class("retention__bars").children(retention.map(
                                    |(what, duration, width)| {
                                        li().child(
                                            div()
                                                .class("row")
                                                .child(span().text(what))
                                                .child(span().text(duration)),
                                        )
                                        .child(div().class("bar").child(i().class(width)))
                                    },
                                )))
                                .child(p().text(
                                    "Barres à l’échelle d’une année. L’historique des profils suit une durée que vous réglez.",
                                ))
                                .child(
                                    p().child(
                                        a().class("btn btn--ghost btn--sm")
                                            .href(link(PRIVACY))
                                            .text("Lire la politique de confidentialité"),
                                    ),
                                ),
                        ),
                ),
        )
}

fn layer(id: &'static str, role: &'static str, name: &'static str) -> Element {
    div()
        .class("stack__layer")
        .id(id)
        .child(span().class("stack__role").text(role))
        .child(span().class("stack__name").text(name))
}

fn stack_link() -> Element {
    div().class("stack__link").attr("aria-hidden", "true")
}

fn technology() -> Element {
    let modules = [
        "Mesure du débit",
        "Latence et gigue",
        "Profils",
        "Limites et simulation",
        "Capacités",
        "Historique",
        "Diagnostic",
    ];
    let goals = [
        ("Démarrage du moteur", "< 500 ms"),
        ("Délai d’affichage d’une mesure", "1 à 2 s"),
        ("Écart sur les compteurs, test contrôlé", "< 5 %"),
        ("Perte de données après fermeture normale", "aucune"),
    ];
    section()
        .class("section")
        .id("technologie")
        .attr("aria-labelledby", "h-technologie")
        .child(
            div()
                .class("wrap")
                .child(section_head(
                    "Sous le capot",
                    "h-technologie",
                    "Une app en Swift natif, de l’interface au moteur",
                    Some(
                        "L’interface est en SwiftUI. La logique de mesure et de règles vit dans un paquet Swift à part, testé sans l’interface. Tout ce qui touche au système passe par les API natives d’Apple.",
                    ),
                ))
                .child(
                    div()
                        .class("tech")
                        .child(
                            div()
                                .class("stack")
                                .attr(
                                    "aria-label",
                                    "Architecture de l’application, de l’interface au système",
                                )
                                .child(
                                    layer("t-swiftui", "Interface", "SwiftUI")
                                        .child(p().text("Écrans natifs et graphiques Swift Charts.")),
                                )
                                .child(stack_link())
                                .child(
                                    layer("t-moteur", "Moteur", "FluxaCore")
                                        .class("stack__layer--core")
                                        .child(p().text(
                                            "Un paquet Swift sans interface : chaque valeur est validée, chaque limite reçoit son statut réel.",
                                        ))
                                        .child(
                                            ul().class("stack__mods")
                                                .children(modules.map(|module| li().text(module)))
                                                .child(
                                                    li().id("t-stockage")
                                                        .text("Stockage local"),
                                                ),
                                        ),
                                )
                                .child(stack_link())
                                .child(layer("t-ios", "Système", "Adaptateur iOS").child(p().text(
                                    "Network.framework pour le type de réseau et la latence, les compteurs d’octets des interfaces, CoreTelephony pour la 4G et la 5G.",
                                ))),
                        )
                        .child(
                            div()
                                .class("tech__side")
                                .child(
                                    div()
                                        .class("formula")
                                        .child(h3().text("Comment le débit est calculé"))
                                        .child(p().text(
                                            "Deux relevés des compteurs d’octets, une soustraction, une division par le temps écoulé. Chaque compteur garde sa source et son périmètre.",
                                        ))
                                        .child(
                                            div()
                                                .class("formula__eq")
                                                .attr("role", "math")
                                                .attr(
                                                    "aria-label",
                                                    "Débit égale octets au second relevé moins octets au premier relevé, multiplié par huit, divisé par le temps écoulé entre les deux relevés",
                                                )
                                                .child(
                                                    div()
                                                        .child(span().text("débit"))
                                                        .child(span().text("="))
                                                        .child(
                                                            span()
                                                                .class("frac")
                                                                .child(span().text(
                                                                    "(octets₂ − octets₁) × 8",
                                                                ))
                                                                .child(span().text("t₂ − t₁")),
                                                        )
                                                        .child(span().text("bit/s")),
                                                ),
                                        ),
                                )
                                .child(
                                    div()
                                        .child(h3().text("Objectifs de qualité de la V1"))
                                        .child(dl().class("goals").children(goals.map(
                                            |(goal, target)| {
                                                div().child(dt().text(goal)).child(dd().text(target))
                                            },
                                        )))
                                        .child(p().class("goals__note").text(
                                            "Objectifs à valider sur des iPhone réels, dans des conditions réseau documentées.",
                                        )),
                                ),
                        ),
                ),
        )
}

fn roadmap() -> Element {
    let steps = [
        (
            "Moteur réseau",
            "Mesure du débit, de la latence et de la connectivité, historique et statistiques.",
        ),
        (
            "Application iPhone",
            "Tableau de bord, réseau, guide du partage, profils et historique en SwiftUI.",
        ),
        (
            "Profils, simulation et automatisations",
            "Limites configurables, programmation, seuils et alertes.",
        ),
        (
            "Qualité et confidentialité",
            "Tests sur iPhone réels en Wi-Fi, 4G et 5G, en arrière-plan et en mode économie d’énergie.",
        ),
        (
            "Bêta TestFlight, puis App Store",
            "Une bêta ouverte aux premiers testeurs avant la publication.",
        ),
    ];
    section()
        .class("section section--alt")
        .id("feuille-de-route")
        .attr("aria-labelledby", "h-route")
        .child(
            div()
                .class("wrap")
                .child(section_head(
                    "Feuille de route",
                    "h-route",
                    "Le chemin jusqu’à l’App Store",
                    Some("La V1 est en développement. Voici les étapes prévues, dans l’ordre."),
                ))
                .child(ol().class("steps").children(
                    steps.map(|(step, detail)| li().child(h3().text(step)).child(p().text(detail))),
                ))
                .child(
                    p().class("steps__note")
                        .text("Aucune date n’est annoncée pour l’instant."),
                ),
        )
}

const FAQ: [(&str, &str); 7] = [
    (
        "FLUXA peut-il activer mon partage de connexion ?",
        "Non. Sur iPhone, seul l’utilisateur active le partage, dans Réglages. FLUXA ouvre les Réglages et vous guide, mais ne bascule pas l’interrupteur à votre place.",
    ),
    (
        "Peut-il limiter le débit des appareils connectés à mon iPhone ?",
        "Non. iOS ne donne à aucune app le contrôle du trafic du partage de connexion. Vous pouvez configurer des plafonds et voir leur effet simulé sur votre débit mesuré. L’app affiche alors le statut « Simulé », jamais « Appliqué ».",
    ),
    (
        "À quoi sert un profil s’il n’est pas appliqué au partage ?",
        "À préparer vos réglages, à comparer des scénarios sur votre débit réel et à déclencher des alertes ou des automatisations sur vos données locales. Si une fonction devient applicable, l’app le signale seulement après confirmation du système.",
    ),
    (
        "Mes données quittent-elles mon iPhone ?",
        "Non. Il n’y a ni compte ni cloud dans la V1. Les mesures sont stockées dans une base locale, et vous pouvez tout effacer depuis les réglages de l’app.",
    ),
    (
        "L’app mesure-t-elle en arrière-plan ?",
        "Les cadences annoncées valent quand l’app est au premier plan. iOS restreint l’exécution en arrière-plan, et la fréquence des mesures peut alors baisser.",
    ),
    (
        "Faut-il installer un VPN ?",
        "Non. Le VPN local est facultatif et demande votre accord. Il traite uniquement le trafic de l’iPhone passé par le tunnel, pas celui des appareils reliés au partage.",
    ),
    (
        "Est-ce un simple test de vitesse ?",
        "Non. Le test de débit est une fonction parmi d’autres. FLUXA réunit le suivi continu de la connexion, l’historique de consommation, les profils et le guide du partage.",
    ),
];

fn faq() -> Element {
    section()
        .class("section")
        .id("faq")
        .attr("aria-labelledby", "h-faq")
        .child(
            div()
                .class("wrap")
                .child(section_head(
                    "Questions fréquentes",
                    "h-faq",
                    "Ce qu’on nous demande en premier",
                    None,
                ))
                .child(div().class("faq").children(FAQ.map(|(question, answer)| {
                    details()
                        .child(summary().text(question))
                        .child(p().text(answer))
                }))),
        )
}

fn call_to_action() -> Element {
    section()
        .class("cta section--alt")
        .id("telecharger")
        .attr("aria-labelledby", "h-cta")
        .child(
            div()
                .class("wrap cta__inner")
                .child(h2().id("h-cta").text("Bientôt sur l’App Store"))
                .child(p().text(
                    "FLUXA arrive d’abord en bêta sur TestFlight, puis sur l’App Store. L’app est conçue pour iPhone et fonctionne sans compte.",
                ))
                .child(store_badge()),
        )
}

/// La page d'accueil.
pub fn home(ctx: &Ctx) -> Page {
    layout(
        ctx,
        "FLUXA pour iPhone",
        DESCRIPTION,
        main()
            .id("contenu")
            .child(hero())
            .child(cadence())
            .child(features())
            .child(profiles_section())
            .child(transparency())
            .child(privacy_section())
            .child(technology())
            .child(roadmap())
            .child(faq())
            .child(call_to_action()),
    )
}

// ---------- Pied de page ----------

const APPLE_HOTSPOT_GUIDE: &str = "https://support.apple.com/fr-fr/111785";
const APPLE_NETWORK_EXTENSION: &str = "https://developer.apple.com/documentation/networkextension";
const APPLE_TN3120: &str = "https://developer.apple.com/documentation/technotes/tn3120-expected-use-cases-for-network-extension-packet-tunnel-providers";

/// Les colonnes du pied de page : un titre, puis des liens (cible, libellé).
const FOOTER: [(&str, &[(&str, &str)]); 6] = [
    (
        "Application",
        &[
            ("#f-tableau", "Tableau de bord"),
            ("#f-test", "Test de débit"),
            ("#f-reseau", "Mon réseau"),
            ("#f-partage", "Partage de connexion"),
            ("#f-historique", "Historique"),
            ("#f-automatisations", "Automatisations"),
            ("#f-diagnostic", "Centre de diagnostic"),
        ],
    ),
    (
        "Profils et limites",
        &[
            ("#profils", "Les sept profils"),
            ("#f-limiteur", "Limiteur de débit"),
            ("#lab", "Configuré ou appliqué"),
            ("#lab-effect", "Simulation d’un plafond"),
        ],
    ),
    (
        "Transparence",
        &[
            ("#transparence", "Ce qu’iOS autorise"),
            ("#regle", "La règle de l’app"),
            ("#capacites", "Capacités sur iPhone"),
            ("#feuille-de-route", "Feuille de route"),
        ],
    ),
    (
        "Confidentialité",
        &[
            ("#confidentialite", "Nos engagements"),
            ("#conservation", "Durées de conservation"),
            ("#suppression", "Effacer l’historique"),
            ("/confidentialite/", "Politique de confidentialité"),
        ],
    ),
    (
        "Technologie",
        &[
            ("#technologie", "Swift natif"),
            ("#t-swiftui", "Interface SwiftUI"),
            ("#t-moteur", "Moteur FluxaCore"),
            ("#t-stockage", "Stockage local"),
            ("#t-ios", "Adaptateur iOS"),
        ],
    ),
    (
        "Aide et ressources",
        &[
            ("#faq", "Questions fréquentes"),
            (APPLE_HOTSPOT_GUIDE, "Partage de connexion, guide Apple"),
            (APPLE_NETWORK_EXTENSION, "Network Extension, Apple"),
            (APPLE_TN3120, "Note technique TN3120"),
            ("/mentions-legales/#contact", "Contact"),
        ],
    ),
];

fn footer_link(ctx: &Ctx, target: &str, label: &'static str) -> Element {
    let link = a().href(ctx.href(target)).text(label);
    if target.starts_with("https://") {
        link.attr("target", "_blank").attr("rel", "noopener")
    } else {
        link
    }
}

fn site_footer(ctx: &Ctx) -> Element {
    let columns = FOOTER.iter().map(|(title, links)| {
        details()
            .class("fcol")
            .child(summary().child(h3().text(*title)))
            .child(
                ul().children(
                    links
                        .iter()
                        .map(|(target, label)| li().child(footer_link(ctx, target, label))),
                ),
            )
    });
    let specs = [
        ("Appareil", "iPhone"),
        ("Langue", "Français"),
        ("Compte", "Aucun"),
        ("Données", "Sur l’appareil"),
        ("Distribution", "App Store"),
        ("État", "V1 en développement"),
    ];
    let notes = [
        (
            "Partage de connexion.",
            " FLUXA ne contrôle pas le partage de connexion d’iOS. Les plafonds de débit réglés dans l’app sont des profils et des simulations. Ils ne sont pas appliqués aux appareils reliés à votre iPhone.",
        ),
        (
            "Données de démonstration.",
            " Les débits, latences et consommations affichés sur ce site sont fictifs et servent à illustrer l’interface. Les préréglages de profil sont des valeurs de départ, pas des débits garantis.",
        ),
        (
            "Marques.",
            " Apple, iPhone, iOS, App Store, TestFlight, SwiftUI et Swift sont des marques d’Apple Inc., déposées aux États-Unis et dans d’autres pays. FLUXA n’est ni affilié à Apple ni approuvé par Apple.",
        ),
    ];
    let legal = [
        ("/mentions-legales/", "Mentions légales"),
        ("/confidentialite/", "Confidentialité"),
        ("/mentions-legales/#conditions", "Conditions d’utilisation"),
        ("/confidentialite/#site", "Cookies"),
    ];
    footer().class("footer").attr("aria-label", "Pied de page").child(
        div()
            .class("wrap")
            .child(
                div()
                    .class("footer__top")
                    .child(
                        div()
                            .class("footer__brand")
                            .child(brand("#haut".to_owned(), "FLUXA, haut de page"))
                            .child(p().text(
                                "Le moniteur de connexion pour iPhone qui mesure à la seconde et n’annonce que ce que le système confirme.",
                            ))
                            .child(
                                ul().class("footer__badges")
                                    .attr("aria-label", "En bref")
                                    .children(
                                        ["Sans compte", "Sans cloud", "Stockage local"]
                                            .map(|badge| li().class("pill pill--ok").text(badge)),
                                    ),
                            ),
                    )
                    .child(
                        div()
                            .class("footer__get")
                            .child(store_badge())
                            .child(small().text(
                                "Bêta TestFlight avant la publication. Aucune date annoncée.",
                            )),
                    ),
            )
            .child(
                nav()
                    .class("footer__cols")
                    .attr("aria-label", "Plan du site")
                    .children(columns),
            )
            .child(
                dl().class("footer__specs")
                    .attr("aria-label", "Fiche de l’application")
                    .children(
                        specs.map(|(name, value)| div().child(dt().text(name)).child(dd().text(value))),
                    ),
            )
            .child(
                div().class("footer__notes").children(
                    notes.map(|(title, body)| p().child(strong().text(title)).child(text(body))),
                ),
            )
            .child(
                div()
                    .class("footer__bottom")
                    .child(
                        div()
                            .child(p().text("© 2026 FLUXA. Tous droits réservés."))
                            .child(
                                nav()
                                    .class("footer__legal")
                                    .attr("aria-label", "Informations légales")
                                    .children(
                                        legal.map(|(target, label)| footer_link(ctx, target, label)),
                                    ),
                            ),
                    )
                    .child(
                        div()
                            .class("footer__meta")
                            .child(span().class("footer__lang").text("Français (France)"))
                            .child(
                                a().class("top-link")
                                    .href("#haut")
                                    .child(text("Haut de page "))
                                    .child(span().attr("aria-hidden", "true").text("↑")),
                            ),
                    ),
            ),
    )
}

// ---------- Pages légales ----------

/// Un bloc d'une page de texte.
enum Block {
    Title(&'static str, &'static str),
    /// Un paragraphe. Le texte est le nôtre : il peut contenir du HTML.
    Text(&'static str),
    List(&'static [&'static str]),
    /// Des champs à renseigner par l'éditeur du site.
    Fields(&'static [(&'static str, &'static str)]),
}

fn todo(label: &'static str) -> Element {
    span().class("todo").text(label)
}

fn document(
    ctx: &Ctx,
    title: &'static str,
    page_title: &'static str,
    lead: &'static str,
    blocks: &[Block],
) -> Page {
    let body = blocks.iter().map(|block| match block {
        Block::Title(id, words) => h2().id(*id).text(*words),
        Block::Text(html) => p().html(*html),
        Block::List(items) => ul().children(items.iter().map(|item| li().html(*item))),
        Block::Fields(fields) => {
            dl().class("doc__fields")
                .children(fields.iter().map(|(name, missing)| {
                    div()
                        .child(dt().text(*name))
                        .child(dd().child(todo(missing)))
                }))
        }
    });
    layout(
        ctx,
        page_title,
        lead,
        main().id("contenu").class("doc").child(
            div()
                .class("wrap")
                .child(
                    div()
                        .class("doc__head")
                        .child(
                            a().class("doc__back")
                                .href(link(HOME))
                                .text("← Retour à l’accueil"),
                        )
                        .child(eyebrow("Document"))
                        .child(h1().text(title))
                        .child(p().text(lead)),
                )
                .child(div().class("prose").children(body)),
        ),
    )
}

/// La politique de confidentialité.
pub fn privacy(ctx: &Ctx) -> Page {
    document(
        ctx,
        "Politique de confidentialité",
        "Confidentialité · FLUXA",
        "Cette politique décrit la V1 de FLUXA pour iPhone telle qu’elle est conçue. Elle sera revue avant la publication sur l’App Store.",
        &[
            Block::Title("resume", "En bref"),
            Block::List(&[
                "FLUXA fonctionne <strong>sans compte</strong> et <strong>sans serveur</strong>.",
                "Les mesures et les réglages sont enregistrés <strong>sur votre iPhone</strong>.",
                "Aucune statistique n’est envoyée automatiquement à qui que ce soit.",
                "Vous pouvez effacer tout l’historique depuis les réglages de l’app.",
            ]),
            Block::Title("donnees", "Données traitées par l’application"),
            Block::Text(
                "Pour afficher le tableau de bord et l’historique, l’app enregistre localement :",
            ),
            Block::List(&[
                "les mesures réseau : débit descendant et montant, latence, gigue, pertes de paquets lorsqu’elles sont mesurables, type de réseau, disponibilité d’Internet ;",
                "la consommation de données et les sessions réseau ;",
                "vos profils, vos règles et le résultat de leur application (appliqué, partiel, simulé ou non pris en charge) ;",
                "les appareils que vous enregistrez et le nom que vous leur donnez ;",
                "vos préférences.",
            ]),
            Block::Text(
                "Ces données sont stockées dans un fichier sur l’appareil, protégé par le chiffrement d’iOS.",
            ),
            Block::Title("jamais", "Ce que FLUXA ne collecte pas"),
            Block::List(&[
                "Le contenu de vos communications. L’app compte des octets, elle ne lit pas ce qu’ils transportent.",
                "Vos mots de passe Wi-Fi.",
                "Des identifiants d’appareils qu’iOS ne fournit pas. Une information inconnue reste marquée comme inconnue.",
            ]),
            Block::Title("conservation", "Durées de conservation"),
            Block::List(&[
                "Mesures détaillées : <strong>7 jours</strong>.",
                "Agrégats horaires : <strong>30 jours</strong>.",
                "Agrégats journaliers : <strong>12 mois</strong>.",
                "Historique des profils : durée réglable dans l’app.",
            ]),
            Block::Text(
                "La suppression totale est possible à tout moment depuis les réglages de l’app.",
            ),
            Block::Title("autorisations", "Autorisations"),
            Block::Text(
                "L’app demande une autorisation au moment où une fonction en a besoin, jamais en bloc au premier lancement. Le VPN local est facultatif. S’il est activé, il traite uniquement le trafic de l’iPhone passé par le tunnel.",
            ),
            Block::Title("site", "Ce site et les cookies"),
            Block::Text(
                "Ce site ne dépose aucun cookie et n’utilise aucun outil de mesure d’audience. Il ne contient aucun formulaire.",
            ),
            Block::Text(
                "Les polices de caractères, les styles et le code du site sont servis par le site lui-même. Aucune ressource n’est chargée depuis un autre service.",
            ),
            Block::Title("contact", "Contact"),
            Block::Text(
                "Pour toute question sur cette politique : <span class=\"todo\">adresse de contact à compléter</span>",
            ),
        ],
    )
}

/// Les mentions légales et les conditions d'utilisation du site.
pub fn legal(ctx: &Ctx) -> Page {
    document(
        ctx,
        "Mentions légales",
        "Mentions légales · FLUXA",
        "Informations sur l’éditeur du site, son hébergement et les conditions d’utilisation.",
        &[
            Block::Title("editeur", "Éditeur"),
            Block::Fields(&[
                ("Nom ou raison sociale", "à compléter"),
                ("Adresse", "à compléter"),
                ("Immatriculation", "à compléter si applicable"),
                ("Directeur de la publication", "à compléter"),
            ]),
            Block::Title("hebergeur", "Hébergeur"),
            Block::Fields(&[("Nom", "à compléter"), ("Adresse", "à compléter")]),
            Block::Title("contact", "Contact"),
            Block::Fields(&[("Adresse électronique", "à compléter")]),
            Block::Title("conditions", "Conditions d’utilisation du site"),
            Block::Text(
                "Ce site présente l’application FLUXA pour iPhone, en cours de développement. Les fonctions décrites correspondent à la V1 prévue et peuvent évoluer avant la publication.",
            ),
            Block::Text(
                "Les débits, latences et consommations affichés sur le site sont des données de démonstration. Les préréglages de profil sont des valeurs de départ, pas des débits garantis.",
            ),
            Block::Text(
                "FLUXA ne contrôle pas le partage de connexion d’iOS. Les plafonds de débit réglés dans l’app sont des profils et des simulations.",
            ),
            Block::Title("propriete", "Propriété intellectuelle"),
            Block::Text(
                "Les textes, l’identité visuelle et les illustrations de ce site appartiennent à l’éditeur de FLUXA, sauf mention contraire. Les polices Bricolage Grotesque, Hanken Grotesk et JetBrains Mono sont distribuées sous licence SIL Open Font License.",
            ),
            Block::Title("marques", "Marques"),
            Block::Text(
                "Apple, iPhone, iOS, App Store, TestFlight, SwiftUI et Swift sont des marques d’Apple Inc., déposées aux États-Unis et dans d’autres pays. FLUXA n’est ni affilié à Apple ni approuvé par Apple.",
            ),
            Block::Title("liens", "Liens externes"),
            Block::Text(
                "Ce site renvoie vers la documentation publique d’Apple. L’éditeur n’est pas responsable du contenu de ces pages.",
            ),
        ],
    )
}

/// La page « introuvable ».
pub fn not_found(ctx: &Ctx) -> Page {
    layout(
        ctx,
        "Page introuvable · FLUXA",
        "Cette adresse ne mène à aucune page du site.",
        main().id("contenu").class("doc").child(
            div().class("wrap").child(
                div()
                    .class("doc__head")
                    .child(eyebrow("Erreur 404"))
                    .child(h1().text("Page introuvable"))
                    .child(p().text(
                        "Cette adresse ne mène à aucune page du site. Le lien est peut-être ancien ou mal recopié.",
                    ))
                    .child(
                        p().child(
                            a().class("btn btn--primary")
                                .href(link(HOME))
                                .text("Retour à l’accueil"),
                        ),
                    ),
            ),
        ),
    )
    .seo(Seo::new().noindex(true))
    .status(404)
}

// ---------- Carte de partage ----------

/// La courbe de la carte : les mêmes données de démonstration que le tableau de bord,
/// dessinées en SVG par le serveur (la carte est une image, sans script).
fn share_chart() -> String {
    const WIDTH: f64 = 372.0;
    const HEIGHT: f64 = 120.0;
    let flow = Flow::new(2026);
    // Le dernier point s'arrête avant le bord, pour que sa pastille reste entière.
    const LAST: f64 = WIDTH - 6.0;
    let x = |index: usize| index as f64 * LAST / POINTS as f64;
    let y = |mbps: f64| HEIGHT - 4.0 - mbps / SCALE_MAX * (HEIGHT - 12.0);
    let line = |series: &[f64]| {
        series
            .iter()
            .enumerate()
            .map(|(index, value)| format!("{:.1},{:.1}", x(index), y(*value)))
            .collect::<Vec<_>>()
            .join(" ")
    };
    let down = line(flow.down());
    let up = line(flow.up());
    let (last_down, last_up) = flow.latest();
    format!(
        r##"<svg viewBox="0 0 {WIDTH} {HEIGHT}" width="{WIDTH}" height="{HEIGHT}" aria-hidden="true"><defs><linearGradient id="aire" x1="0" y1="0" x2="0" y2="1"><stop offset="0" stop-color="#7cd4fd" stop-opacity="0.34"/><stop offset="1" stop-color="#7cd4fd" stop-opacity="0"/></linearGradient></defs><line x1="0" x2="{WIDTH}" y1="{g40:.1}" y2="{g40:.1}" stroke="#1b1f35"/><line x1="0" x2="{WIDTH}" y1="{g20:.1}" y2="{g20:.1}" stroke="#1b1f35"/><polygon points="0,{HEIGHT} {down} {LAST},{HEIGHT}" fill="url(#aire)"/><polyline points="{down}" fill="none" stroke="#7cd4fd" stroke-width="2.5" stroke-linejoin="round" stroke-linecap="round"/><polyline points="{up}" fill="none" stroke="#ffb37a" stroke-width="2" stroke-linejoin="round" stroke-linecap="round"/><circle cx="{LAST}" cy="{cy_down:.1}" r="4.5" fill="#7cd4fd" stroke="#090b14" stroke-width="2"/><circle cx="{LAST}" cy="{cy_up:.1}" r="4" fill="#ffb37a" stroke="#090b14" stroke-width="2"/></svg>"##,
        g40 = y(40.0),
        g20 = y(20.0),
        cy_down = y(last_down),
        cy_up = y(last_up),
    )
}

/// La carte de partage, à capturer en 1200 × 630 pour refaire `public/og-image.png`.
pub fn share_card(ctx: &Ctx) -> Page {
    Page::new("Carte de partage · FLUXA")
        .lang("fr")
        .plain()
        .stylesheet(ctx.site.stylesheet())
        .seo(Seo::new().noindex(true))
        .body(
            main()
                .class("sharecard")
                .child(
                    div()
                        .class("sharecard__copy")
                        .child(
                            div()
                                .class("brand")
                                .child(span().class("brand__mark").html(LOGO))
                                .child(span().class("brand__name").text("FLUXA")),
                        )
                        .child(h1().text("Votre connexion, mesurée à la seconde."))
                        .child(p().text(
                            "Débit, latence et consommation de votre iPhone. Sans compte, sans cloud.",
                        ))
                        .child(
                            div()
                                .class("sharecard__pills")
                                .child(pill("pill--ok", "Pris en charge"))
                                .child(pill("pill--sim", "Simulé"))
                                .child(pill("pill--no", "Réservé à iOS")),
                        ),
                )
                .child(
                    div()
                        .class("sharecard__panel")
                        .child(
                            div()
                                .class("app__bar")
                                .child(span().class("app__title").text("Tableau de bord"))
                                .child(pill("pill--ok", "Connecté")),
                        )
                        .child(p().class("app__label").text("Débit descendant"))
                        .child(
                            p().class("app__big")
                                .child(span().text("42,8"))
                                .child(small().text("Mb/s")),
                        )
                        .child(p().class("app__up").text("↑ 8,4 Mb/s montant"))
                        .child(div().class("sharecard__chart").html(share_chart()))
                        .child(
                            dl().class("app__tiles")
                                .child(
                                    div()
                                        .child(dt().text("Latence"))
                                        .child(dd().text("28 ms")),
                                )
                                .child(div().child(dt().text("Gigue")).child(dd().text("4 ms"))),
                        ),
                ),
        )
}
