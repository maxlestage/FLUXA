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
    // Neuf fonctions, chacune avec son ancre, et un pied de page complet.
    assert_eq!(html.matches(r#"class="feat""#).count(), 9);
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
