//! L'export statique pour GitHub Pages, derrière le sous-chemin `/FLUXA`.
//!
//! Seul dans son fichier : l'export fixe le sous-chemin pour tout le processus.

use std::path::Path;

fn files(dir: &Path, out: &mut Vec<std::path::PathBuf>) {
    for entry in std::fs::read_dir(dir).unwrap().flatten() {
        let path = entry.path();
        if path.is_dir() {
            files(&path, out);
        } else {
            out.push(path);
        }
    }
}

#[tokio::test(flavor = "multi_thread")]
async fn exports_every_page_behind_the_base_path() {
    let out = std::env::temp_dir().join(format!("fluxa-site-export-{}", std::process::id()));
    let _ = std::fs::remove_dir_all(&out);
    let written = fluxa_site::server::export::export(
        &out,
        "/FLUXA",
        Some("https://maxlestage.github.io/FLUXA".into()),
    )
    .await
    .unwrap();
    assert!(written >= 11, "{written} fichiers");
    for file in [
        "index.html",
        "confidentialite/index.html",
        "mentions-legales/index.html",
        "404.html",
        "sitemap.xml",
        "robots.txt",
        "site.css",
        "favicon.svg",
        "fonts/hanken-grotesk.woff2",
        ".nojekyll",
    ] {
        assert!(out.join(file).is_file(), "{file} manque");
    }

    let mut all = Vec::new();
    files(&out, &mut all);
    let mut links = 0;
    for file in all
        .iter()
        .filter(|f| f.extension().is_some_and(|e| e == "html"))
    {
        let html = std::fs::read_to_string(file).unwrap();
        // Chaque adresse du site passe par le sous-chemin.
        for attribute in ["href=\"/", "src=\"/", "from \"/", "module_or_path:\"/"] {
            for part in html.split(attribute).skip(1) {
                assert!(
                    part.starts_with("FLUXA/"),
                    "{} : {attribute}{}",
                    file.display(),
                    &part[..part.len().min(40)]
                );
                links += 1;
            }
        }
        assert!(html.contains("https://maxlestage.github.io/FLUXA/"));
    }
    assert!(links > 100, "{links} liens seulement");

    let sitemap = std::fs::read_to_string(out.join("sitemap.xml")).unwrap();
    assert!(sitemap.contains("<loc>https://maxlestage.github.io/FLUXA/confidentialite/</loc>"));
    let _ = std::fs::remove_dir_all(&out);
}
