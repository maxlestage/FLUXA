//! `fluxa-site export <dossier>` : tout le site en fichiers statiques, pour GitHub
//! Pages ou n'importe quel hébergeur statique. Chaque page vient du serveur lui-même,
//! par le client de test en mémoire de Paquets (`app.test()`) : les deux versions sont
//! donc identiques.

use std::io;
use std::path::{Path, PathBuf};
use std::sync::Arc;

use super::{Site, app, site_dir};
use crate::routes::{self, base, set_base};

/// L'adresse des URL canoniques quand `SITE_URL` n'est pas défini.
fn default_site_url(base: &str) -> String {
    if base.is_empty() {
        "http://localhost:3000".to_owned()
    } else {
        format!("https://maxlestage.github.io{base}")
    }
}

/// Écrit le site dans `out`, les liens derrière `base_path` (`""` ou `/FLUXA`), les URL
/// absolues sur `site_url`. Renvoie le nombre de fichiers écrits.
pub async fn export(out: &Path, base_path: &str, site_url: Option<String>) -> io::Result<usize> {
    set_base(base_path);
    let base = base();
    let out = std::path::absolute(out)?;
    // Paquets trouve `pkg/` (le bundle du navigateur) dans le dossier courant.
    let dir = std::path::absolute(site_dir())?;
    std::env::set_current_dir(&dir)?;
    if !dir.join("pkg").is_dir() {
        eprintln!(
            "attention : site/pkg manque : les pages ne seront pas interactives (voir site/README.md)"
        );
    }
    let site_url = site_url
        .filter(|url| !url.trim().is_empty())
        .unwrap_or_else(|| default_site_url(&base));
    let mut app = app(Arc::new(Site::load(Some(site_url))));
    // Des fichiers statiques n'ont pas de serveur à protéger.
    app.security(None);
    let client = app.test().await;

    let mut written = 0;
    let mut write = |path: &str, bytes: &[u8]| -> io::Result<()> {
        let file = out.join(path.trim_start_matches('/'));
        if let Some(parent) = file.parent() {
            std::fs::create_dir_all(parent)?;
        }
        std::fs::write(file, bytes)?;
        written += 1;
        Ok(())
    };
    let get = |path: &'static str, expected: u16| {
        let client = &client;
        async move {
            let response = client.get(path).await;
            if response.status().as_u16() != expected {
                return Err(io::Error::other(format!(
                    "GET {path} : {} au lieu de {expected}",
                    response.status()
                )));
            }
            Ok(response.text())
        }
    };

    for path in routes::PAGES {
        let html = get(path, 200).await?;
        write(
            &format!("{path}index.html"),
            with_base(&html, &base).as_bytes(),
        )?;
    }
    // GitHub Pages sert 404.html pour toute adresse inconnue.
    let missing = get("/page-introuvable/", 404).await?;
    write("404.html", with_base(&missing, &base).as_bytes())?;
    for file in ["/sitemap.xml", "/robots.txt", "/manifest.webmanifest"] {
        write(file, get(file, 200).await?.as_bytes())?;
    }
    // Le service worker garde le bundle des îlots, dont l'adresse reçoit le sous-chemin.
    let worker = get("/sw.js", 200).await?;
    write("/sw.js", with_base(&worker, &base).as_bytes())?;
    for folder in ["public", "pkg"] {
        let root = dir.join(folder);
        let prefix = if folder == "pkg" { "pkg/" } else { "" };
        for file in files(&root) {
            let relative = file.strip_prefix(&root).map_err(io::Error::other)?;
            let url = format!("{prefix}{}", relative.to_string_lossy().replace('\\', "/"));
            // Les fichiers propres à wasm-bindgen, inutiles au bundle.
            if url.ends_with(".gitignore") || url.ends_with("package.json") {
                continue;
            }
            write(&url, &std::fs::read(&file)?)?;
        }
    }
    // Les fichiers sont servis tels quels : pas de Jekyll sur GitHub Pages.
    write(".nojekyll", b"")?;
    Ok(written)
}

/// Les adresses que Paquets écrit lui-même (le chargeur des îlots `/pkg/…`, le manifeste
/// et le service worker de la PWA) ne connaissent pas le sous-chemin : elles le reçoivent ici. Les liens du site l'ont déjà.
pub fn with_base(html: &str, base: &str) -> String {
    if base.is_empty() {
        return html.to_owned();
    }
    html.replace("\"/pkg/", &format!("\"{base}/pkg/"))
        .replace(
            "\"/manifest.webmanifest\"",
            &format!("\"{base}/manifest.webmanifest\""),
        )
        .replace("\"/sw.js\"", &format!("\"{base}/sw.js\""))
}

/// Tous les fichiers de `dir`, récursivement.
fn files(dir: &Path) -> Vec<PathBuf> {
    let mut found = Vec::new();
    let Ok(entries) = std::fs::read_dir(dir) else {
        return found;
    };
    for entry in entries.flatten() {
        let path = entry.path();
        if path.is_dir() {
            found.extend(files(&path));
        } else {
            found.push(path);
        }
    }
    found.sort();
    found
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn prefixes_the_islands_loader() {
        let html = r#"<link rel="modulepreload" href="/pkg/a.js"/><script type="module">import init from "/pkg/a.js";init({module_or_path:"/pkg/a_bg.wasm"});</script>"#;
        let out = with_base(html, "/FLUXA");
        assert_eq!(out.matches("\"/FLUXA/pkg/").count(), 3);
        assert_eq!(with_base(html, ""), html);
        assert_eq!(
            default_site_url("/FLUXA"),
            "https://maxlestage.github.io/FLUXA"
        );
    }
}
