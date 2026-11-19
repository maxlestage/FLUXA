//! Les adresses du site. Derrière un sous-chemin (GitHub Pages : `/FLUXA`), chaque
//! lien reçoit ce préfixe.

use std::sync::RwLock;

static BASE: RwLock<String> = RwLock::new(String::new());

pub const HOME: &str = "/";
pub const PRIVACY: &str = "/confidentialite/";
pub const LEGAL: &str = "/mentions-legales/";

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
