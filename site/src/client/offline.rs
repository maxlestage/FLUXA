//! Le site hors ligne dès la première visite.
//!
//! Le service worker de Paquets garde ce qui passe par lui. À la première visite, la
//! page est déjà chargée quand il prend la main : ses fichiers ne sont donc pas encore
//! gardés. Ici, une fois le service worker aux commandes, le navigateur redemande les
//! pages, la feuille de style et les polices listées par la page, pour qu'il les garde.

use wasm_bindgen::prelude::*;
use wasm_bindgen_futures::JsFuture;

/// Attend `ms` millisecondes.
async fn pause(ms: i32) {
    let promise = js_sys::Promise::new(&mut |resolve, _| {
        if let Some(window) = web_sys::window() {
            let _ = window.set_timeout_with_callback_and_timeout_and_arguments_0(&resolve, ms);
        }
    });
    let _ = JsFuture::from(promise).await;
}

pub fn keep_the_site() {
    let Some(window) = web_sys::window() else {
        return;
    };
    let navigator = window.navigator();
    // Pas de service worker dans ce navigateur (ou en navigation privée) : rien à garder.
    if !js_sys::Reflect::has(&navigator, &JsValue::from_str("serviceWorker")).unwrap_or(false) {
        return;
    }
    let Some(list) = window
        .document()
        .and_then(|document| {
            document
                .query_selector("meta[name=\"fluxa-offline\"]")
                .ok()
                .flatten()
        })
        .and_then(|meta| meta.get_attribute("content"))
    else {
        return;
    };
    let container = navigator.service_worker();
    let Ok(ready) = container.ready() else {
        return;
    };
    wasm_bindgen_futures::spawn_local(async move {
        if JsFuture::from(ready).await.is_err() {
            return;
        }
        // Le service worker est actif ; on attend qu'il contrôle la page (dix secondes au plus).
        for _ in 0..40 {
            if container.controller().is_some() {
                break;
            }
            pause(250).await;
        }
        if container.controller().is_none() {
            return;
        }
        for url in list.split_whitespace() {
            // Un échec (réseau coupé) n'empêche pas de garder le reste.
            let _ = JsFuture::from(window.fetch_with_str(url)).await;
        }
        let _ = window
            .document()
            .and_then(|document| document.document_element())
            .map(|root| root.set_attribute("data-offline-ready", ""));
    });
}
