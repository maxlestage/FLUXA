//! fluxa-shaper : tente d'appliquer un plafond de débit au partage de connexion de
//! l'iPhone par les mécanismes du noyau, et rend compte de chaque tentative.
//!
//! Sur un système de la famille BSD comme iOS, brider le trafic d'une interface passe
//! par le filtre de paquets `pf` (le périphérique `/dev/pf`) associé à `dummynet`, dont
//! les files se configurent sur une socket brute, et par des réglages `sysctl` du noyau.
//! Le module essaie ces trois voies, dans cet ordre, sans rien modifier :
//!   - il ouvre `/dev/pf` en écriture, puis le referme ;
//!   - il ouvre une socket brute IPv4, puis la referme ;
//!   - il réécrit un réglage `sysctl` réseau avec sa valeur actuelle.
//!
//! Le plafond n'est déclaré appliqué que si une règle a réellement été posée et
//! confirmée par le système. Ce module n'en pose aucune : même si toutes les voies
//! s'ouvraient, `applied` resterait faux, et le rapport dirait que la voie est libre.
//! Sur un iPhone ordinaire, le bac à sable des apps les refuse toutes.
//!
//! L'ABI C est décrite dans `include/fluxa_shaper.h`. Le rapport est un JSON en UTF-8.

use std::ffi::{c_char, CString};
use std::io;

/// Ce que le système a répondu à une tentative.
#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub enum Outcome {
    /// Le système a laissé faire.
    Accepted,
    /// Le système a refusé, avec ce code d'erreur.
    Refused(i32),
    /// Le mécanisme n'existe pas sur ce système.
    Missing,
}

/// Une voie essayée et la réponse du système.
#[derive(Debug, Clone, PartialEq, Eq)]
pub struct Attempt {
    pub mechanism: &'static str,
    pub title: &'static str,
    pub outcome: Outcome,
}

/// Le rapport complet d'une tentative d'application.
#[derive(Debug, Clone, PartialEq, Eq)]
pub struct Report {
    pub download_bps: Option<u64>,
    pub upload_bps: Option<u64>,
    /// L'interface de pont du partage de connexion, si elle existe.
    pub sharing_interface: Option<String>,
    pub attempts: Vec<Attempt>,
}

impl Report {
    /// Toujours faux : aucune règle n'est posée (voir l'en-tête du module).
    pub fn applied(&self) -> bool {
        false
    }

    /// Vrai si toutes les voies se sont ouvertes.
    pub fn system_allows(&self) -> bool {
        !self.attempts.is_empty()
            && self
                .attempts
                .iter()
                .all(|attempt| attempt.outcome == Outcome::Accepted)
    }

    pub fn summary(&self) -> &'static str {
        if self.system_allows() {
            "Le système laisse l’accès à ces mécanismes, ce qui n’arrive pas sur un iPhone ordinaire. \
             FLUXA n’y pose encore aucune règle : rien n’est appliqué."
        } else {
            "iOS a refusé l’accès aux mécanismes qui brident le réseau. Rien n’est appliqué au partage \
             de connexion."
        }
    }

    pub fn to_json(&self) -> String {
        let attempts: Vec<String> = self
            .attempts
            .iter()
            .map(|attempt| {
                let (outcome, code) = match attempt.outcome {
                    Outcome::Accepted => ("accepted", None),
                    Outcome::Refused(errno) => ("refused", Some(errno)),
                    Outcome::Missing => ("missing", None),
                };
                format!(
                    "{{\"mechanism\":{},\"title\":{},\"outcome\":{},\"code\":{},\"message\":{}}}",
                    quote(attempt.mechanism),
                    quote(attempt.title),
                    quote(outcome),
                    code.map_or("null".to_string(), |errno| quote(errno_name(errno))),
                    quote(&message(attempt.outcome)),
                )
            })
            .collect();
        format!(
            "{{\"version\":{},\"download_bps\":{},\"upload_bps\":{},\"sharing_interface\":{},\
             \"applied\":{},\"system_allows\":{},\"summary\":{},\"attempts\":[{}]}}",
            quote(env!("CARGO_PKG_VERSION")),
            number(self.download_bps),
            number(self.upload_bps),
            self.sharing_interface
                .as_deref()
                .map_or("null".to_string(), quote),
            self.applied(),
            self.system_allows(),
            quote(self.summary()),
            attempts.join(","),
        )
    }
}

/// Essaie toutes les voies et rend le rapport. Un plafond nul vaut « sans plafond ».
pub fn try_apply(download_bps: u64, upload_bps: u64) -> Report {
    Report {
        download_bps: (download_bps > 0).then_some(download_bps),
        upload_bps: (upload_bps > 0).then_some(upload_bps),
        sharing_interface: sharing_interface(),
        attempts: vec![packet_filter(), dummynet_socket(), kernel_setting()],
    }
}

// MARK: Les voies

fn last_errno() -> i32 {
    io::Error::last_os_error().raw_os_error().unwrap_or(0)
}

/// Le filtre de paquets : `/dev/pf`, ouvert en écriture puis refermé.
fn packet_filter() -> Attempt {
    let path = c"/dev/pf";
    // SAFETY : chemin terminé par un zéro ; le descripteur est refermé aussitôt.
    let descriptor = unsafe { libc::open(path.as_ptr(), libc::O_RDWR | libc::O_CLOEXEC) };
    let outcome = if descriptor >= 0 {
        unsafe { libc::close(descriptor) };
        Outcome::Accepted
    } else {
        match last_errno() {
            libc::ENOENT => Outcome::Missing,
            errno => Outcome::Refused(errno),
        }
    };
    Attempt {
        mechanism: "pf",
        title: "Filtre de paquets (pf)",
        outcome,
    }
}

/// Les files `dummynet` se configurent sur une socket brute IPv4.
fn dummynet_socket() -> Attempt {
    // SAFETY : appel système sans pointeur ; la socket est refermée aussitôt.
    let socket = unsafe { libc::socket(libc::AF_INET, libc::SOCK_RAW, libc::IPPROTO_RAW) };
    let outcome = if socket >= 0 {
        unsafe { libc::close(socket) };
        Outcome::Accepted
    } else {
        match last_errno() {
            libc::EAFNOSUPPORT | libc::EPROTONOSUPPORT => Outcome::Missing,
            errno => Outcome::Refused(errno),
        }
    };
    Attempt {
        mechanism: "dummynet",
        title: "Files de débit (dummynet)",
        outcome,
    }
}

/// Un réglage réseau du noyau, réécrit avec sa valeur actuelle : rien ne change.
#[cfg(target_vendor = "apple")]
fn kernel_setting() -> Attempt {
    let name = c"net.inet.ip.forwarding";
    let mut value: libc::c_int = 0;
    let mut size = std::mem::size_of::<libc::c_int>();
    // SAFETY : tampons de la bonne taille, nom terminé par un zéro.
    let read = unsafe {
        libc::sysctlbyname(
            name.as_ptr(),
            (&mut value as *mut libc::c_int).cast(),
            &mut size,
            std::ptr::null_mut(),
            0,
        )
    };
    let outcome = if read != 0 {
        match last_errno() {
            libc::ENOENT => Outcome::Missing,
            errno => Outcome::Refused(errno),
        }
    } else {
        let written = unsafe {
            libc::sysctlbyname(
                name.as_ptr(),
                std::ptr::null_mut(),
                std::ptr::null_mut(),
                (&mut value as *mut libc::c_int).cast(),
                std::mem::size_of::<libc::c_int>(),
            )
        };
        if written == 0 {
            Outcome::Accepted
        } else {
            Outcome::Refused(last_errno())
        }
    };
    Attempt {
        mechanism: "sysctl",
        title: "Réglages du noyau (sysctl)",
        outcome,
    }
}

/// Hors des systèmes d'Apple (tests sous Linux), `sysctlbyname` n'existe pas.
#[cfg(not(target_vendor = "apple"))]
fn kernel_setting() -> Attempt {
    Attempt {
        mechanism: "sysctl",
        title: "Réglages du noyau (sysctl)",
        outcome: Outcome::Missing,
    }
}

/// L'interface de pont que le système crée pour le partage de connexion.
fn sharing_interface() -> Option<String> {
    (100..110)
        .map(|number| format!("bridge{number}"))
        .find(|name| {
            let Ok(name) = CString::new(name.as_str()) else {
                return false;
            };
            // SAFETY : nom terminé par un zéro.
            unsafe { libc::if_nametoindex(name.as_ptr()) != 0 }
        })
}

// MARK: Les messages

fn errno_name(errno: i32) -> &'static str {
    match errno {
        libc::EPERM => "EPERM",
        libc::EACCES => "EACCES",
        libc::ENOENT => "ENOENT",
        libc::EBUSY => "EBUSY",
        libc::EINVAL => "EINVAL",
        libc::ENOTSUP => "ENOTSUP",
        _ => "AUTRE",
    }
}

fn message(outcome: Outcome) -> String {
    match outcome {
        Outcome::Accepted => "Accès accordé par le système.".to_string(),
        Outcome::Missing => "Ce mécanisme n’existe pas sur ce système.".to_string(),
        Outcome::Refused(libc::EPERM) => {
            "Refusé : opération réservée au système (EPERM).".to_string()
        }
        Outcome::Refused(libc::EACCES) => {
            "Refusé par le bac à sable des apps (EACCES).".to_string()
        }
        Outcome::Refused(errno) => format!("Refusé par le système (erreur {errno})."),
    }
}

fn quote(text: &str) -> String {
    let mut out = String::with_capacity(text.len() + 2);
    out.push('"');
    for character in text.chars() {
        match character {
            '"' => out.push_str("\\\""),
            '\\' => out.push_str("\\\\"),
            '\n' => out.push_str("\\n"),
            control if (control as u32) < 0x20 => {
                out.push_str(&format!("\\u{:04x}", control as u32))
            }
            other => out.push(other),
        }
    }
    out.push('"');
    out
}

fn number(value: Option<u64>) -> String {
    value.map_or("null".to_string(), |value| value.to_string())
}

// MARK: L'ABI C

/// Tente d'appliquer le plafond et renvoie le rapport en JSON, à rendre avec
/// `fluxa_shaper_free`. Ne renvoie jamais un pointeur nul.
#[no_mangle]
pub extern "C" fn fluxa_shaper_try_apply(download_bps: u64, upload_bps: u64) -> *mut c_char {
    let json = try_apply(download_bps, upload_bps).to_json();
    // Le JSON ne contient pas de zéro : les caractères de contrôle sont échappés.
    CString::new(json).unwrap_or_default().into_raw()
}

/// Rend un rapport renvoyé par `fluxa_shaper_try_apply`. Sans effet sur un pointeur nul.
///
/// # Safety
/// `report` doit venir de `fluxa_shaper_try_apply` et n'être rendu qu'une fois.
#[no_mangle]
pub unsafe extern "C" fn fluxa_shaper_free(report: *mut c_char) {
    if !report.is_null() {
        drop(CString::from_raw(report));
    }
}

/// La version du module, valable pendant toute la vie du programme.
#[no_mangle]
pub extern "C" fn fluxa_shaper_version() -> *const c_char {
    concat!(env!("CARGO_PKG_VERSION"), "\0").as_ptr().cast()
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn nothing_is_ever_declared_applied() {
        let report = try_apply(5_000_000, 1_000_000);
        assert!(!report.applied());
        assert_eq!(report.attempts.len(), 3);
        assert!(report.to_json().contains("\"applied\":false"));
    }

    #[test]
    fn open_mechanisms_still_do_not_mean_applied() {
        let report = Report {
            download_bps: Some(1),
            upload_bps: None,
            sharing_interface: Some("bridge100".into()),
            attempts: vec![Attempt {
                mechanism: "pf",
                title: "pf",
                outcome: Outcome::Accepted,
            }],
        };
        assert!(report.system_allows());
        assert!(!report.applied());
        assert!(report.summary().contains("rien n’est appliqué"));
    }

    #[test]
    fn a_refusal_is_reported_with_its_code() {
        let report = Report {
            download_bps: Some(5_000_000),
            upload_bps: None,
            sharing_interface: None,
            attempts: vec![Attempt {
                mechanism: "pf",
                title: "pf",
                outcome: Outcome::Refused(libc::EPERM),
            }],
        };
        let json = report.to_json();
        assert!(!report.system_allows());
        assert!(json.contains("\"outcome\":\"refused\""), "{json}");
        assert!(json.contains("\"code\":\"EPERM\""), "{json}");
        assert!(json.contains("\"upload_bps\":null"), "{json}");
        assert!(json.contains("\"sharing_interface\":null"), "{json}");
    }

    #[test]
    fn zero_means_no_cap() {
        let report = try_apply(0, 0);
        assert_eq!(report.download_bps, None);
        assert_eq!(report.upload_bps, None);
    }

    #[test]
    fn json_text_is_escaped() {
        assert_eq!(quote("a\"b\\c\nd\u{1}"), "\"a\\\"b\\\\c\\nd\\u0001\"");
    }

    #[test]
    fn the_c_abi_round_trips() {
        let report = fluxa_shaper_try_apply(1_000_000, 0);
        assert!(!report.is_null());
        let text = unsafe { std::ffi::CStr::from_ptr(report) }
            .to_str()
            .unwrap()
            .to_owned();
        unsafe { fluxa_shaper_free(report) };
        assert!(text.starts_with('{') && text.ends_with('}'));
        let version = unsafe { std::ffi::CStr::from_ptr(fluxa_shaper_version()) };
        assert_eq!(version.to_str().unwrap(), env!("CARGO_PKG_VERSION"));
    }
}
