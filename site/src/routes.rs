//! Les adresses du site. Derrière un sous-chemin (GitHub Pages : `/FLUXA`), chaque
//! lien reçoit ce préfixe.

use std::sync::RwLock;

static BASE: RwLock<String> = RwLock::new(String::new());

pub const HOME: &str = "/";
pub const PRIVACY: &str = "/confidentialite/";
pub const LEGAL: &str = "/mentions-legales/";

/// L'image affichée quand on partage un lien du site (1200 × 630).
pub const SHARE_IMAGE: &str = "/og-image.png";
/// La page qui dessine cette image. Elle n'est ni dans le plan du site ni exportée : on
/// l'ouvre pour refaire la capture (voir `site/README.md`).
pub const SHARE_CARD: &str = "/carte-de-partage/";

/// Les icônes de l'application installée.
pub const ICON_192: &str = "/icons/icon-192.png";
pub const ICON_512: &str = "/icons/icon-512.png";
pub const ICON_MASKABLE: &str = "/icons/icon-maskable-512.png";
pub const FONTS: [&str; 3] = [
    "/fonts/hanken-grotesk.woff2",
    "/fonts/bricolage-grotesque.woff2",
    "/fonts/jetbrains-mono.woff2",
];

/// Les pages du site, dans l'ordre du plan.
pub const PAGES: [&str; 3] = [HOME, PRIVACY, LEGAL];

/// Fixe le sous-chemin du site : `""` ou `/FLUXA`.
pub fn set_base(base: &str) {
    let base = base.trim().trim_end_matches('/');
    *BASE.write().unwrap_or_else(|e| e.into_inner()) = base.to_owned();
}

/// Le sous-chemin du site, sans barre finale.
pub fn base() -> String {
    BASE.read().unwrap_or_else(|e| e.into_inner()).clone()
}

/// Un chemin du site (`/confidentialite/`) derrière le sous-chemin.
pub fn link(path: &str) -> String {
    format!("{}{path}", base())
}
