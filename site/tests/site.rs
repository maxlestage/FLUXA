//! Le site tel que le serveur le rend, par le client de test en mémoire de Paquets.

use std::sync::Arc;

use fluxa_site::server::{Site, app};

async fn client() -> paquets::test::TestClient {
    let mut app = app(Arc::new(Site::load(Some("https://fluxa.example".into()))));
    // Les tests posent plus de questions à la seconde qu'un visiteur.
    app.security(None);
    app.test().await
}

#[tokio::test(flavor = "multi_thread")]
async fn serves_the_home_page() {
    let client = client().await;
    let response = client.get("/").await;
    assert_eq!(response.status(), 200);
    let html = response.text();
    assert!(html.contains("<title>FLUXA pour iPhone</title>"));
    assert!(html.contains(r#"<html lang="fr">"#));
    assert!(html.contains(r#"<link rel="canonical" href="https://fluxa.example/"/>"#));
    assert!(html.contains("Votre connexion, mesurée à la seconde."));
    // Les trois îlots, rendus par le serveur avec leurs valeurs de départ.
    for island in ["menu", "dashboard", "profile-lab"] {
        assert!(
            html.contains(&format!(r#"data-island="{island}""#)),
            "{island}"
        );
    }
    assert!(html.contains("42,8"));
    // Quinze fonctions, chacune avec son ancre, et un pied de page complet.
    assert_eq!(html.matches(r#"class="feat""#).count(), 15);
    assert_eq!(html.matches(r#"class="fcol""#).count(), 6);
    // iOS seulement.
    assert!(!html.to_lowercase().contains("android"));
}

#[tokio::test(flavor = "multi_thread")]
async fn every_anchor_of_the_home_page_exists() {
    let client = client().await;
    let html = client.get("/").await.text();
    let mut checked = 0;
    for part in html.split("href=\"#").skip(1) {
        let anchor = part.split('"').next().unwrap();
        assert!(
            html.contains(&format!(r#"id="{anchor}""#)),
            "l'ancre #{anchor} ne mène nulle part"
        );
        checked += 1;
    }
    assert!(checked > 30, "{checked} ancres seulement");
}

#[tokio::test(flavor = "multi_thread")]
async fn serves_the_legal_pages_on_one_address_each() {
    let client = client().await;
    for (path, title) in [
        ("/confidentialite/", "Politique de confidentialité"),
        ("/mentions-legales/", "Mentions légales"),
    ] {
        let response = client.get(path).await;
        assert_eq!(response.status(), 200, "{path}");
        let html = response.text();
        assert!(html.contains(&format!("<h1>{title}</h1>")), "{path}");
        // Hors de l'accueil, le menu et le pied de page y renvoient.
        assert!(html.contains(r##"href="/#fonctions""##), "{path}");

        let short = client.get(path.trim_end_matches('/')).await;
        assert_eq!(short.status(), 301, "{path}");
        assert_eq!(short.header("location"), Some(path));
    }
    // Les ancres vers les pages légales existent sur ces pages.
    let privacy = client.get("/confidentialite/").await.text();
    assert!(privacy.contains(r#"id="site""#));
    let legal = client.get("/mentions-legales/").await.text();
    assert!(legal.contains(r#"id="contact""#) && legal.contains(r#"id="conditions""#));
}

#[tokio::test(flavor = "multi_thread")]
async fn answers_unknown_addresses_with_the_not_found_page() {
    let client = client().await;
    let response = client.get("/nulle-part/").await;
    assert_eq!(response.status(), 404);
    let html = response.text();
    assert!(html.contains("Page introuvable"));
    assert!(html.contains("noindex"));
}

#[tokio::test(flavor = "multi_thread")]
async fn lists_its_pages_for_search_engines() {
    let client = client().await;
    let sitemap = client.get("/sitemap.xml").await.text();
    for path in fluxa_site::routes::PAGES {
        assert!(sitemap.contains(&format!("<loc>https://fluxa.example{path}</loc>")));
    }
    let robots = client.get("/robots.txt").await.text();
    assert!(robots.contains("Sitemap: https://fluxa.example/sitemap.xml"));
}

#[tokio::test(flavor = "multi_thread")]
async fn every_page_carries_the_share_card() {
    let client = client().await;
    for path in fluxa_site::routes::PAGES {
        let html = client.get(path).await.text();
        assert!(
            html.contains(
                r#"<meta property="og:image" content="https://fluxa.example/og-image.jpg"/>"#
            ),
            "{path}"
        );
        assert!(html.contains(r#"<meta name="twitter:card" content="summary_large_image"/>"#));
        assert!(html.contains(r#"<meta property="og:image:width" content="1200"/>"#));
        assert!(html.contains(r#"<meta property="og:image:height" content="630"/>"#));
        assert!(html.contains(r#"<meta property="og:image:alt""#));
    }
    // L'image existe, en JPEG, aux dimensions annoncées (lues dans son en-tête de trame),
    // et reste légère.
    let jpeg = std::fs::read("public/og-image.jpg").expect("public/og-image.jpg");
    assert_eq!(&jpeg[..2], &[0xFF, 0xD8]);
    assert!(
        jpeg.len() < 150_000,
        "image de partage trop lourde : {} o",
        jpeg.len()
    );
    let mut at = 2;
    let (width, height) = loop {
        assert_eq!(jpeg[at], 0xFF);
        let marker = jpeg[at + 1];
        let length = usize::from(u16::from_be_bytes([jpeg[at + 2], jpeg[at + 3]]));
        if matches!(marker, 0xC0..=0xC2) {
            let read = |i: usize| u16::from_be_bytes([jpeg[at + i], jpeg[at + i + 1]]);
            break (read(7), read(5));
        }
        at += 2 + length;
    };
    assert_eq!((width, height), (1200, 630));
}

#[tokio::test(flavor = "multi_thread")]
async fn the_share_card_page_stays_out_of_the_site() {
    let client = client().await;
    let response = client.get(fluxa_site::routes::SHARE_CARD).await;
    assert_eq!(response.status(), 200);
    let html = response.text();
    assert!(html.contains("noindex"));
    assert!(html.contains("42,8") && html.contains("<polyline"));
    let sitemap = client.get("/sitemap.xml").await.text();
    assert!(!sitemap.contains("carte-de-partage"));
}

#[tokio::test(flavor = "multi_thread")]
async fn the_site_is_an_installable_app() {
    let client = client().await;
    let html = client.get("/").await.text();
    assert!(html.contains(r#"<link rel="manifest" href="/manifest.webmanifest"/>"#));
    assert!(html.contains(r#"<link rel="apple-touch-icon" href="/icons/icon-512.png"/>"#));
    assert!(html.contains(r##"<meta name="theme-color" content="#090b14"/>"##));
    assert!(html.contains("serviceWorker"));

    let response = client.get("/manifest.webmanifest").await;
    assert_eq!(response.status(), 200);
    let manifest: paquets::serde_json::Value = response.json();
    assert_eq!(manifest["name"], "FLUXA");
    assert_eq!(manifest["start_url"], "/");
    assert_eq!(manifest["scope"], "/");
    assert_eq!(manifest["display"], "standalone");
    assert_eq!(manifest["lang"], "fr");
    let icons = manifest["icons"].as_array().unwrap();
    assert_eq!(icons.len(), 3);
    assert!(icons.iter().any(|icon| icon["purpose"] == "maskable"));
    for icon in icons {
        // Chaque icône du manifeste est un fichier du site, à la taille annoncée.
        let src = icon["src"].as_str().unwrap();
        let png = std::fs::read(format!("public{src}")).unwrap_or_else(|_| panic!("{src} manque"));
        let width = u32::from_be_bytes(png[16..20].try_into().unwrap());
        assert_eq!(icon["sizes"], format!("{width}x{width}"), "{src}");
    }
}

#[tokio::test(flavor = "multi_thread")]
async fn the_service_worker_keeps_the_site_for_offline() {
    let client = client().await;
    let worker = client.get("/sw.js").await.text();
    // La page d'accueil et les icônes sont gardées à l'installation ; hors ligne, une
    // adresse inconnue retombe sur l'accueil.
    assert!(worker.contains(r#"const OFFLINE = "/";"#));
    for url in [
        "\"/\"",
        "/icons/icon-192.png",
        "/icons/icon-maskable-512.png",
    ] {
        assert!(worker.contains(url), "{url}");
    }
    // Le reste est listé par chaque page : le navigateur le redemande une fois le
    // service worker aux commandes.
    let html = client.get("/confidentialite/").await.text();
    let list = html
        .split(r#"<meta name="fluxa-offline" content=""#)
        .nth(1)
        .and_then(|rest| rest.split('"').next())
        .expect("la liste hors ligne");
    let urls: Vec<&str> = list.split_whitespace().collect();
    for expected in [
        "/",
        "/confidentialite/",
        "/mentions-legales/",
        "/fonts/jetbrains-mono.woff2",
    ] {
        assert!(urls.contains(&expected), "{expected}");
    }
    assert!(urls.iter().any(|url| url.starts_with("/site.css?v=")));
    for url in urls {
        let path = url.split('?').next().unwrap();
        assert_eq!(client.get(path).await.status(), 200, "{url}");
    }
}

/// Le site ne promet rien que l'app ne fait pas : ces phrases ont été vraies ou prévues,
/// elles ne le sont plus. Une fonction qui revient doit revenir dans l'app d'abord.
#[tokio::test(flavor = "multi_thread")]
async fn the_site_does_not_lie() {
    let client = client().await;
    for path in ["/", "/confidentialite/", "/mentions-legales/"] {
        let html = client.get(path).await.text();
        for claim in [
            "Bientôt sur l’App Store",
            "Bientôt disponible",
            "saturations",
            "par semaine",
            "détecte ce que votre iPhone",
            "durée que vous réglez",
            "durée réglable",
            "VPN local facultatif",
            "deux échanges, et seulement de ceux-là",
            "de l’interface au moteur",
            "n’annonce que ce que le système confirme",
            "Quand l’app est ouverte, elle ouvre une connexion vers un hôte toutes les cinq secondes",
        ] {
            assert!(!html.contains(claim), "{path} affirme encore : {claim}");
        }
    }
    let home = client.get("/").await.text();
    // Le relais est décrit avec son vrai statut, et la disponibilité réelle est dite.
    assert!(home.contains("id=\"f-relais\""));
    assert!(home.contains("Partiel"));
    assert!(home.contains("bêta privée"));
    assert!(
        home.contains("Pas encore sur l’App Store") || home.contains("pas encore sur l’App Store")
    );
}

/// L'optimisation est mise en avant, et ses chiffres sont ceux de l'app : sonde de
/// latence, écritures, widgets, relais Rust, batterie. Un chiffre qui change dans l'app
/// change ici, ou ce test le signale.
#[tokio::test(flavor = "multi_thread")]
async fn the_optimisations_are_the_apps() {
    let client = client().await;
    let home = client.get("/").await.text();
    // Juste après les cadences, avant les fonctions, et dans le menu.
    let optimisation = home
        .find(r#"id="optimisation""#)
        .expect("la section optimisation");
    assert!(optimisation < home.find(r#"id="fonctions""#).unwrap());
    assert!(home.contains(r##"href="#optimisation""##));
    assert_eq!(home.matches(r#"class="feat opt""#).count(), 8);
    for fact in [
        "que tableau de bord affiché : toutes les 5 s, toutes les 15 s",
        "toutes les 30 s en données réduites",
        "une fois par minute dans une base SQLite",
        "par des requêtes compilées une seule fois puis réutilisées chaque minute",
        "au plus toutes les 5 minutes",
        "tous les quarts d’heure",
        "Au plus 192 connexions",
        "256 Ko de pile",
        "de 2 à 64 Ko",
        "après 3 s",
        "relus au plus toutes les 5 s, et non à chaque connexion",
        "dort jusqu’à elle, sans se réveiller en boucle",
        "toutes les 5 s au tableau de bord, toutes les 10 s ailleurs",
        "au plus toutes les 10 s",
        "sous 20 % de batterie",
        "ne se relisent que s’ils sont affichés",
        "n’est recopiée chaque seconde que tableau de bord affiché",
        "laisse 100 ms de marge à iOS",
        "écartées sur leur nom brut, sans rien copier",
        "dort d’un trait jusqu’à l’échéance, au lieu de se réveiller toutes les 100 ms",
        "part d’un tampon de 4 Ko, qui ne double, jusqu’à 64 Ko",
    ] {
        assert!(home.contains(fact), "l'optimisation ne dit plus : {fact}");
    }
    // Les mêmes chiffres dans le code de l'app.
    let read = |path: &str| std::fs::read_to_string(format!("../ios/{path}")).unwrap();
    let model = read("App/AppModel.swift");
    assert!(model.contains("dashboardVisible && interval > 0"));
    assert!(model.contains("level < 0.2"));
    assert!(model.contains("sampleTolerance: Duration = .milliseconds(100)"));
    assert!(model.contains("tolerance: Self.sampleTolerance"));
    assert!(model.contains("if Self.followsLiveChart(dashboardVisible: dashboardVisible) {"));
    let store = read("FluxaCore/Sources/FluxaCore/SQLiteStore.swift");
    assert!(store.contains("let statement = try database.statement(upsert)"));
    assert!(
        !store.contains("database.prepare("),
        "plus aucune écriture recompilée"
    );
    assert!(
        read("FluxaCore/Sources/FluxaCore/SQLiteDatabase.swift")
            .contains("if let statement = statements[sql] {")
    );
    let counters = read("App/Services/InterfaceCounters.swift");
    assert!(
        counters.contains("guard let kind = classify(cName: interface.ifa_name) else { continue }")
    );
    assert!(counters.contains("name: String(cString: interface.ifa_name)"));
    assert!(model.contains("relayScreenVisible ? 1 : (dashboardVisible ? 5 : 10)"));
    assert!(read("App/Features/HistoryView.swift").contains("visible ? revision() : nil"));
    assert!(
        read("App/Features/DiagnosticsView.swift")
            .contains("watchedRevision(model.historyRevision, visible: visible)")
    );
    let publisher = read("App/Services/WidgetPublisher.swift");
    assert!(publisher.contains("now.timeIntervalSince(lastWrite) >= 5 * 60"));
    assert!(publisher.contains("now.timeIntervalSince(lastReload) >= 15 * 60"));
    assert!(publisher.contains("now.timeIntervalSince(lastUpdate) >= 10"));
    let relay = read("Shaper/src/relay.rs");
    for constant in [
        "MAX_CONNECTIONS: usize = 192",
        "CONNECTION_STACK: usize = 256 * 1024",
        "MAX_CHUNK: usize = 64 * 1024",
        "MIN_CHUNK: usize = 2 * 1024",
        "CONNECT_ATTEMPT: Duration = Duration::from_secs(3)",
        ".wait_timeout(finished, grace - silence)",
        "START_CHUNK: usize = 4 * 1024",
        "count == length && length < MAX_CHUNK",
        "(length * 2).min(MAX_CHUNK)",
        "self.pause.sleep(wait, &self.stop);",
        ".wait_timeout(guard, left)",
        "self.shared.pause.wake();",
        "NETWORKS_TTL: Duration = Duration::from_secs(5)",
        "self.networks.allows(peer)",
    ] {
        assert!(relay.contains(constant), "{constant}");
    }
}
