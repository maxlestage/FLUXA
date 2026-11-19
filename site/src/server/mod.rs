//! Le serveur : une `paquets::App` avec les pages du site. Les fichiers statiques
//! viennent de `public/` et le bundle du navigateur de `pkg/`, que Paquets trouve dans
//! le dossier courant.

pub mod export;
pub mod pages;

use std::io;
use std::path::{Path, PathBuf};
use std::sync::Arc;

use paquets::prelude::*;
use paquets::securite::https::HttpsRedirect;

use crate::routes::{
    self, HOME, ICON_192, ICON_512, ICON_MASKABLE, LEGAL, PRIVACY, SHARE_CARD, base, link,
};

pub struct Site {
    /// L'adresse publique, sous-chemin compris (`SITE_URL`) ; `None` : celle de chaque
    /// requête.
    pub site_url: Option<String>,
    /// L'empreinte de `public/site.css`, pour `?v=` dans son lien.
    pub css_version: String,
}

/// Le dossier `site/` : `SITE_DIR` s'il contient `public/`, sinon le dossier courant
/// s'il contient `public/`, sinon le dossier de la crate.
///
/// `SITE_DIR` est relatif à l'endroit où le serveur démarre (`SITE_DIR=site` dans le
/// Procfile). Une fois que [`run`] s'est placé dans ce dossier, `site/public` n'existe
/// plus vu de là, et le dossier courant est le bon.
pub fn site_dir() -> PathBuf {
    resolve_site_dir(std::env::var_os("SITE_DIR").map(PathBuf::from))
}

fn resolve_site_dir(env: Option<PathBuf>) -> PathBuf {
    if let Some(dir) = env.filter(|dir| dir.join("public").is_dir()) {
        return dir;
    }
    if Path::new("public").is_dir() {
        return PathBuf::from(".");
    }
    PathBuf::from(env!("CARGO_MANIFEST_DIR"))
}

/// FNV-1a : assez pour distinguer deux versions d'un fichier.
pub fn version(bytes: &[u8]) -> String {
    let hash = bytes.iter().fold(0xcbf2_9ce4_8422_2325_u64, |hash, byte| {
        (hash ^ u64::from(*byte)).wrapping_mul(0x0100_0000_01b3)
    });
    format!("{hash:016x}")[..10].to_owned()
}

impl Site {
    /// Lit la feuille de style. Appelez [`routes::set_base`] avant.
    pub fn load(site_url: Option<String>) -> Site {
        let path = site_dir().join("public/site.css");
        let css = std::fs::read(&path).unwrap_or_else(|error| {
            eprintln!(
                "attention : {} illisible ({error}) : site.css?v= ne changera pas",
                path.display()
            );
            Vec::new()
        });
        Site {
            site_url: site_url
                .map(|url| url.trim().trim_end_matches('/').to_owned())
                .filter(|url| !url.is_empty())
                .map(|url| {
                    if url.ends_with(&base()) {
                        url
                    } else {
                        format!("{url}{}", base())
                    }
                }),
            css_version: version(&css),
        }
    }

    /// L'adresse de la feuille de style, avec son empreinte : elle change avec le fichier.
    pub fn stylesheet(&self) -> String {
        format!("{}?v={}", link("/site.css"), self.css_version)
    }

    /// L'adresse publique du site, sous-chemin compris, sans barre finale.
    fn origin(&self, req: &Request) -> String {
        if let Some(url) = &self.site_url {
            return url.clone();
        }
        let header = |name: &str| {
            req.header(name)
                .map(|value| value.split(',').next().unwrap_or("").trim().to_owned())
        };
        let host = header("x-forwarded-host")
            .or_else(|| header("host"))
            .unwrap_or_else(|| "localhost".into());
        if host.is_empty()
            || !host
                .chars()
                .all(|c| c.is_ascii_alphanumeric() || matches!(c, '.' | '-' | ':'))
        {
            return format!("http://localhost{}", base());
        }
        let proto = if header("x-forwarded-proto").as_deref() == Some("https") {
            "https"
        } else {
            "http"
        };
        format!("{proto}://{host}{}", base())
    }
}

/// Une page du site : son chemin et la fonction qui la rend.
type Render = fn(&pages::Ctx) -> Page;

const ROUTES: [(&str, Render); 4] = [
    (HOME, pages::home),
    (PRIVACY, pages::privacy),
    (LEGAL, pages::legal),
    (SHARE_CARD, pages::share_card),
];

/// Le manifeste de l'application installable. Ses adresses passent par le sous-chemin du
/// site : le même code sert Heroku (`/`) et GitHub Pages (`/FLUXA/`).
fn manifest() -> Pwa {
    Pwa::new("FLUXA")
        .short_name("FLUXA")
        .description("Le site de FLUXA, le moniteur de connexion pour iPhone : fonctions, profils, transparence et confidentialité. Lisible hors ligne.")
        .id(link(HOME))
        .start_url(link(HOME))
        .scope(link(HOME))
        .display("standalone")
        .orientation("portrait")
        .lang("fr")
        .theme_color("#090b14")
        .background_color("#090b14")
        .categories(["utilities", "productivity"])
        .icon(link(ICON_192), "192x192", "image/png")
        .icon(link(ICON_512), "512x512", "image/png")
        .maskable_icon(link(ICON_MASKABLE), "512x512", "image/png")
}

fn render(site: &Site, req: &Request, path: &'static str, page: Render) -> Response {
    // Une seule adresse par page : `/confidentialite` mène à `/confidentialite/`.
    if req.path() != path {
        let query = req
            .uri()
            .query()
            .map(|query| format!("?{query}"))
            .unwrap_or_default();
        return Redirect::permanent(format!("{}{query}", link(path))).into_response();
    }
    let ctx = pages::Ctx {
        site,
        path,
        origin: site.origin(req),
    };
    page(&ctx)
        .into_response()
        .header("cache-control", "no-cache")
}

fn not_found(site: &Site, req: &Request) -> Response {
    let ctx = pages::Ctx {
        site,
        path: "/404/",
        origin: site.origin(req),
    };
    pages::not_found(&ctx).into_response()
}

fn sitemap(site: &Site, req: &Request) -> Response {
    let origin = site.origin(req);
    let mut xml = String::from(
        "<?xml version=\"1.0\" encoding=\"UTF-8\"?>\n<urlset xmlns=\"http://www.sitemaps.org/schemas/sitemap/0.9\">\n",
    );
    for path in routes::PAGES {
        xml.push_str(&format!("<url><loc>{origin}{path}</loc></url>\n"));
    }
    xml.push_str("</urlset>\n");
    Response::new()
        .header("content-type", "application/xml; charset=utf-8")
        .send(xml)
}

fn robots(site: &Site, req: &Request) -> Response {
    let origin = site.origin(req);
    Response::new()
        .header("content-type", "text/plain; charset=utf-8")
        .send(format!(
            "User-agent: *\nAllow: /\n\nSitemap: {origin}/sitemap.xml\n"
        ))
}

/// L'application, prête à tourner ou à être testée.
pub fn app(site: Arc<Site>) -> App {
    let mut app = App::new();
    // Le bouclier de Paquets, plus la redirection vers HTTPS derrière le routeur de
    // Heroku (qui indique le protocole d'origine dans `X-Forwarded-Proto`).
    app.security(paquets::shield().guard(HttpsRedirect::new()).build());
    app.middleware(middleware::compress());
    for (path, page) in ROUTES {
        let site = site.clone();
        // La route s'écrit sans barre finale ; `render` y ramène ensuite l'adresse.
        let route = if path == HOME {
            path
        } else {
            path.trim_end_matches('/')
        };
        app.get(route, move |req: Request| {
            let site = site.clone();
            async move { render(&site, &req, path, page) }
        });
    }
    for (path, handler) in [
        ("/sitemap.xml", sitemap as fn(&Site, &Request) -> Response),
        ("/robots.txt", robots),
    ] {
        let site = site.clone();
        app.get(path, move |req: Request| {
            let site = site.clone();
            async move { handler(&site, &req) }
        });
    }
    // Installable sur téléphone et ordinateur, lisible hors ligne : Paquets sert le
    // manifeste (`/manifest.webmanifest`) et le service worker (`/sw.js`).
    app.pwa(manifest());
    let fallback = site.clone();
    app.fallback(move |req: Request| {
        let site = fallback.clone();
        async move { not_found(&site, &req) }
    });
    app
}

/// `cargo run` : le serveur, sur `PORT` (Heroku) ou 3000.
pub fn run() -> io::Result<()> {
    routes::set_base(&std::env::var("BASE_PATH").unwrap_or_default());
    // Paquets sert `public/` et `pkg/` depuis le dossier courant.
    let dir = site_dir();
    if dir != Path::new(".") {
        std::env::set_current_dir(&dir)?;
    }
    let site = Arc::new(Site::load(std::env::var("SITE_URL").ok()));
    app(site).run()
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn versions_change_with_the_content() {
        assert_eq!(version(b"a").len(), 10);
        assert_ne!(version(b"a"), version(b"b"));
    }

    #[test]
    fn the_stylesheet_is_found_from_the_site_folder() {
        assert_eq!(resolve_site_dir(Some("site".into())), PathBuf::from("."));
        assert_eq!(resolve_site_dir(None), PathBuf::from("."));
        let site = Site::load(None);
        assert_ne!(
            site.css_version,
            version(b""),
            "public/site.css n'a pas été lu"
        );
    }
}
