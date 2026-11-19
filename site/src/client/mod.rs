//! Le bundle du navigateur : rend les îlots interactifs.

pub mod chart;

use wasm_bindgen::prelude::*;

#[wasm_bindgen(start)]
pub fn start() {
    paquets::hydrate(&crate::islands::ISLANDS);
}
