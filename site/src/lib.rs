//! Le site de FLUXA, écrit avec Paquets : ce que le serveur et le navigateur partagent
//! (liens, profils, démonstrations, îlots), le serveur (natif) et le bundle du
//! navigateur (wasm32).

pub mod demo;
pub mod islands;
pub mod profiles;
pub mod routes;

#[cfg(not(target_arch = "wasm32"))]
pub mod server;

#[cfg(target_arch = "wasm32")]
mod client;
