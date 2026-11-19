//! Serveur du site FLUXA.
//!
//! Sert le dossier `public/` tel quel : les fichiers sont chargés en mémoire au
//! démarrage, compressés une fois, puis servis avec un ETag, une politique de
//! cache et des en-têtes de sécurité. Sur Heroku, le port vient de `$PORT`.

use std::collections::HashMap;
use std::io::{self, BufRead, BufReader, Read, Write};
use std::net::{TcpListener, TcpStream};
use std::path::Path;
use std::sync::{Arc, Mutex, mpsc};
use std::time::Duration;
use std::{env, fs, thread};

use flate2::Compression;
use flate2::write::GzEncoder;

/// Taille maximale d'une requête (ligne de requête et en-têtes).
const MAX_REQUEST_BYTES: u64 = 16 * 1024;

/// Le site n'exécute que son propre code. Les polices viennent de Google Fonts.
const CONTENT_SECURITY_POLICY: &str = "default-src 'self'; script-src 'self'; \
     style-src 'self' https://fonts.googleapis.com; font-src https://fonts.gstatic.com; \
     img-src 'self' data:; base-uri 'self'; form-action 'none'; frame-ancestors 'none'";

struct Asset {
    body: Vec<u8>,
    gzip: Option<Vec<u8>>,
    content_type: &'static str,
    etag: String,
}

impl Asset {
    fn new(name: &str, body: Vec<u8>) -> Self {
        let content_type = content_type(name);
        let gzip = if is_text(content_type) {
            gzip(&body).filter(|packed| packed.len() < body.len())
        } else {
            None
        };
        Asset {
            etag: format!("\"{:016x}\"", fnv1a(&body)),
            body,
            gzip,
            content_type,
        }
    }

    fn is_html(&self) -> bool {
        self.content_type.starts_with("text/html")
    }
}

/// Les fichiers du site, par chemin d'URL (`/index.html`, `/assets/site.css`…).
struct Site {
    files: HashMap<String, Asset>,
}

impl Site {
    fn load(dir: &Path) -> io::Result<Self> {
        let mut files = HashMap::new();
        load_dir(dir, "", &mut files)?;
        if !files.contains_key("/index.html") {
            return Err(io::Error::new(
                io::ErrorKind::NotFound,
                format!("{} ne contient pas index.html", dir.display()),
            ));
        }
        Ok(Site { files })
    }

    /// `/` donne `index.html`, `/confidentialite` donne `confidentialite.html`.
    fn resolve(&self, path: &str) -> Option<&Asset> {
        if let Some(dir) = path.strip_suffix('/') {
            return self.files.get(&format!("{dir}/index.html"));
        }
        self.files
            .get(path)
            .or_else(|| self.files.get(&format!("{path}.html")))
            .or_else(|| self.files.get(&format!("{path}/index.html")))
    }
}

fn load_dir(dir: &Path, prefix: &str, files: &mut HashMap<String, Asset>) -> io::Result<()> {
    for entry in fs::read_dir(dir)? {
        let entry = entry?;
        let name = entry.file_name().to_string_lossy().into_owned();
        if name.starts_with('.') {
            continue;
        }
        let url = format!("{prefix}/{name}");
        if entry.file_type()?.is_dir() {
            load_dir(&entry.path(), &url, files)?;
        } else {
            files.insert(url, Asset::new(&name, fs::read(entry.path())?));
        }
    }
    Ok(())
}

fn content_type(name: &str) -> &'static str {
    match name.rsplit('.').next().unwrap_or("") {
        "html" => "text/html; charset=utf-8",
        "css" => "text/css; charset=utf-8",
        "js" => "text/javascript; charset=utf-8",
        "json" | "webmanifest" => "application/json; charset=utf-8",
        "svg" => "image/svg+xml",
        "txt" => "text/plain; charset=utf-8",
        "xml" => "application/xml; charset=utf-8",
        "png" => "image/png",
        "jpg" | "jpeg" => "image/jpeg",
        "webp" => "image/webp",
        "ico" => "image/x-icon",
        "woff2" => "font/woff2",
        _ => "application/octet-stream",
    }
}

fn is_text(content_type: &str) -> bool {
    content_type.starts_with("text/")
        || content_type.starts_with("application/json")
        || content_type.starts_with("application/xml")
        || content_type == "image/svg+xml"
}

fn gzip(body: &[u8]) -> Option<Vec<u8>> {
    let mut encoder = GzEncoder::new(Vec::new(), Compression::best());
    encoder.write_all(body).ok()?;
    encoder.finish().ok()
}

/// Empreinte FNV-1a : stable d'une version de Rust à l'autre, suffisante pour un ETag.
fn fnv1a(bytes: &[u8]) -> u64 {
    bytes.iter().fold(0xcbf2_9ce4_8422_2325, |hash, byte| {
        (hash ^ u64::from(*byte)).wrapping_mul(0x0000_0100_0000_01b3)
    })
}

/// Décode les `%XX` d'un chemin. `None` si le chemin est invalide.
fn percent_decode(path: &str) -> Option<String> {
    let bytes = path.as_bytes();
    let mut out = Vec::with_capacity(bytes.len());
    let mut i = 0;
    while i < bytes.len() {
        if bytes[i] == b'%' {
            let hex = path.get(i + 1..i + 3)?;
            out.push(u8::from_str_radix(hex, 16).ok()?);
            i += 3;
        } else {
            out.push(bytes[i]);
            i += 1;
        }
    }
    let decoded = String::from_utf8(out).ok()?;
    let safe = decoded.starts_with('/')
        && !decoded.contains('\0')
        && !decoded.contains('\\')
        && !decoded.split('/').any(|segment| segment == "..");
    safe.then_some(decoded)
}

struct Request {
    method: String,
    target: String,
    headers: HashMap<String, String>,
}

impl Request {
    fn header(&self, name: &str) -> &str {
        self.headers.get(name).map_or("", String::as_str)
    }
}

fn read_request(stream: &TcpStream) -> io::Result<Option<Request>> {
    let mut reader = BufReader::new(stream.take(MAX_REQUEST_BYTES));
    let mut line = String::new();
    if reader.read_line(&mut line)? == 0 {
        return Ok(None);
    }
    let mut parts = line.split_whitespace();
    let (Some(method), Some(target), Some(version)) = (parts.next(), parts.next(), parts.next())
    else {
        return Ok(None);
    };
    if !version.starts_with("HTTP/1.") {
        return Ok(None);
    }
    let (method, target) = (method.to_string(), target.to_string());

    let mut headers = HashMap::new();
    loop {
        let mut line = String::new();
        if reader.read_line(&mut line)? == 0 {
            return Ok(None); // requête tronquée ou trop longue
        }
        let line = line.trim_end();
        if line.is_empty() {
            break;
        }
        if let Some((name, value)) = line.split_once(':') {
            headers.insert(name.trim().to_ascii_lowercase(), value.trim().to_string());
        }
    }
    Ok(Some(Request {
        method,
        target,
        headers,
    }))
}

struct Response<'a> {
    status: u16,
    reason: &'static str,
    headers: Vec<(&'static str, String)>,
    body: &'a [u8],
}

impl<'a> Response<'a> {
    fn new(status: u16, reason: &'static str) -> Self {
        Response {
            status,
            reason,
            headers: Vec::new(),
            body: &[],
        }
    }

    fn text(status: u16, reason: &'static str, body: &'a str) -> Self {
        let mut response = Response::new(status, reason);
        response.header("Content-Type", "text/plain; charset=utf-8");
        response.body = body.as_bytes();
        response
    }

    fn header(&mut self, name: &'static str, value: impl Into<String>) {
        self.headers.push((name, value.into()));
    }

    fn write(&self, mut stream: &TcpStream, head_only: bool, secure: bool) -> io::Result<()> {
        let mut head = format!("HTTP/1.1 {} {}\r\n", self.status, self.reason);
        for (name, value) in &self.headers {
            head.push_str(&format!("{name}: {value}\r\n"));
        }
        head.push_str(&format!("Content-Length: {}\r\n", self.body.len()));
        head.push_str("X-Content-Type-Options: nosniff\r\n");
        head.push_str("Referrer-Policy: strict-origin-when-cross-origin\r\n");
        head.push_str("X-Frame-Options: DENY\r\n");
        if secure {
            head.push_str("Strict-Transport-Security: max-age=31536000\r\n");
        }
        head.push_str("Connection: close\r\n\r\n");
        stream.write_all(head.as_bytes())?;
        if !head_only {
            stream.write_all(self.body)?;
        }
        stream.flush()
    }
}

/// Répond à une requête. Renvoie le statut, pour le journal.
fn respond(site: &Site, request: &Request, stream: &TcpStream) -> io::Result<u16> {
    let head_only = request.method == "HEAD";
    // Heroku termine le TLS et indique le protocole d'origine dans cet en-tête.
    let proto = request.header("x-forwarded-proto");
    let secure = proto == "https";
    let send = |response: Response| {
        response.write(stream, head_only, secure)?;
        Ok(response.status)
    };

    if request.method != "GET" && !head_only {
        let mut response = Response::text(405, "Method Not Allowed", "Méthode non autorisée.\n");
        response.header("Allow", "GET, HEAD");
        return send(response);
    }

    let host = request.header("host");
    let host_is_plain = !host.is_empty()
        && host
            .bytes()
            .all(|b| b.is_ascii_alphanumeric() || matches!(b, b'.' | b'-' | b':'));
    if proto == "http" && host_is_plain && request.target.starts_with('/') {
        let mut response = Response::new(301, "Moved Permanently");
        response.header("Location", format!("https://{host}{}", request.target));
        return send(response);
    }

    let raw_path = request.target.split(['?', '#']).next().unwrap_or("");
    let Some(path) = percent_decode(raw_path) else {
        return send(Response::text(400, "Bad Request", "Requête invalide.\n"));
    };

    let (asset, status, reason) = match site.resolve(&path) {
        Some(asset) => (asset, 200, "OK"),
        None => match site.files.get("/404.html") {
            Some(page) => (page, 404, "Not Found"),
            None => return send(Response::text(404, "Not Found", "Page introuvable.\n")),
        },
    };

    if status == 200 && request.header("if-none-match") == asset.etag {
        let mut response = Response::new(304, "Not Modified");
        response.header("ETag", asset.etag.clone());
        return send(response);
    }

    let mut response = Response::new(status, reason);
    response.header("Content-Type", asset.content_type);
    if asset.is_html() {
        response.header("Content-Security-Policy", CONTENT_SECURITY_POLICY);
        response.header("Cache-Control", "no-cache");
    } else {
        // Les fichiers ne sont pas versionnés dans leur nom : cache court, revalidé par ETag.
        response.header("Cache-Control", "public, max-age=3600");
    }
    if status == 200 {
        response.header("ETag", asset.etag.clone());
    }
    response.body = &asset.body;
    if let Some(packed) = &asset.gzip {
        response.header("Vary", "Accept-Encoding");
        let accepts_gzip = request
            .header("accept-encoding")
            .split(',')
            .any(|encoding| encoding.trim().starts_with("gzip"));
        if accepts_gzip {
            response.header("Content-Encoding", "gzip");
            response.body = packed;
        }
    }
    send(response)
}

fn handle(site: &Site, stream: &TcpStream) -> io::Result<()> {
    stream.set_read_timeout(Some(Duration::from_secs(10)))?;
    stream.set_write_timeout(Some(Duration::from_secs(30)))?;
    let Some(request) = read_request(stream)? else {
        return Response::text(400, "Bad Request", "Requête invalide.\n")
            .write(stream, false, false);
    };
    let status = respond(site, &request, stream)?;
    println!("{} {} {status}", request.method, request.target);
    Ok(())
}

/// Sert le site sur `listener` avec un nombre fixe de fils d'exécution.
fn serve(listener: TcpListener, site: Arc<Site>, workers: usize) {
    let (sender, receiver) = mpsc::sync_channel::<TcpStream>(256);
    let receiver = Arc::new(Mutex::new(receiver));
    for _ in 0..workers {
        let (receiver, site) = (Arc::clone(&receiver), Arc::clone(&site));
        thread::spawn(move || {
            loop {
                let next = receiver.lock().unwrap_or_else(|e| e.into_inner()).recv();
                let Ok(stream) = next else { break };
                // Une connexion coupée par le client n'est pas une erreur du serveur.
                let _ = handle(&site, &stream);
            }
        });
    }
    for stream in listener.incoming().flatten() {
        // File pleine : la connexion est fermée plutôt que mise en attente sans fin.
        let _ = sender.try_send(stream);
    }
}

fn main() -> io::Result<()> {
    let dir = env::var("SITE_DIR").unwrap_or_else(|_| "public".into());
    let port = env::var("PORT").unwrap_or_else(|_| "3000".into());
    let workers = env::var("WEB_CONCURRENCY")
        .ok()
        .and_then(|value| value.parse().ok())
        .filter(|count| (1..=256).contains(count))
        .unwrap_or(16);

    let site = Arc::new(Site::load(Path::new(&dir))?);
    let listener = TcpListener::bind(format!("0.0.0.0:{port}"))?;
    println!(
        "FLUXA : {} fichiers servis depuis {dir}/ sur http://localhost:{port}",
        site.files.len()
    );
    serve(listener, site, workers);
    Ok(())
}

#[cfg(test)]
mod tests {
    use super::*;

    /// Démarre le serveur sur un port libre avec le vrai dossier `public/`.
    fn start() -> String {
        let site = Arc::new(Site::load(Path::new("public")).expect("public/ lisible"));
        let listener = TcpListener::bind("127.0.0.1:0").unwrap();
        let address = listener.local_addr().unwrap().to_string();
        thread::spawn(move || serve(listener, site, 2));
        address
    }

    fn request(address: &str, raw: &str) -> String {
        let mut stream = TcpStream::connect(address).unwrap();
        stream.write_all(raw.as_bytes()).unwrap();
        let mut response = Vec::new();
        stream.read_to_end(&mut response).unwrap();
        String::from_utf8_lossy(&response).into_owned()
    }

    fn get(address: &str, path: &str) -> String {
        request(
            address,
            &format!("GET {path} HTTP/1.1\r\nHost: test\r\n\r\n"),
        )
    }

    #[test]
    fn serves_the_pages() {
        let address = start();
        let home = get(&address, "/");
        assert!(home.starts_with("HTTP/1.1 200 OK"), "{home}");
        assert!(home.contains("Content-Type: text/html; charset=utf-8"));
        assert!(home.contains("Content-Security-Policy: default-src 'self'"));
        assert!(home.contains("<title>FLUXA pour iPhone</title>"));

        for path in ["/index.html", "/confidentialite", "/mentions-legales.html"] {
            assert!(get(&address, path).starts_with("HTTP/1.1 200 OK"), "{path}");
        }
        let css = get(&address, "/assets/site.css");
        assert!(css.contains("Content-Type: text/css; charset=utf-8"));
        assert!(css.contains("Cache-Control: public, max-age=3600"));
    }

    #[test]
    fn answers_404_with_the_error_page() {
        let address = start();
        let missing = get(&address, "/absent");
        assert!(missing.starts_with("HTTP/1.1 404 Not Found"), "{missing}");
        assert!(missing.contains("Page introuvable"));
    }

    #[test]
    fn refuses_what_it_should() {
        let address = start();
        for path in [
            "/../Cargo.toml",
            "/%2e%2e/Cargo.toml",
            "/assets/..%2f..%2fCargo.toml",
        ] {
            let response = get(&address, path);
            assert!(!response.starts_with("HTTP/1.1 200"), "{path}: {response}");
            assert!(!response.contains("[package]"), "{path}");
        }
        let post = request(&address, "POST / HTTP/1.1\r\nHost: test\r\n\r\n");
        assert!(post.starts_with("HTTP/1.1 405"), "{post}");
        assert!(request(&address, "n'importe quoi\r\n\r\n").starts_with("HTTP/1.1 400"));
    }

    #[test]
    fn compresses_and_revalidates() {
        let address = start();
        let packed = request(
            &address,
            "GET / HTTP/1.1\r\nHost: test\r\nAccept-Encoding: br, gzip\r\n\r\n",
        );
        assert!(packed.contains("Content-Encoding: gzip"));

        let plain = get(&address, "/assets/site.js");
        let etag = plain
            .lines()
            .find_map(|line| line.strip_prefix("ETag: "))
            .expect("un ETag");
        let again = request(
            &address,
            &format!("GET /assets/site.js HTTP/1.1\r\nHost: test\r\nIf-None-Match: {etag}\r\n\r\n"),
        );
        assert!(again.starts_with("HTTP/1.1 304"), "{again}");

        let head = request(&address, "HEAD / HTTP/1.1\r\nHost: test\r\n\r\n");
        assert!(head.starts_with("HTTP/1.1 200 OK") && head.ends_with("\r\n\r\n"));
    }

    #[test]
    fn redirects_http_to_https_behind_the_router() {
        let address = start();
        let response = request(
            &address,
            "GET /confidentialite?x=1 HTTP/1.1\r\nHost: fluxa.example\r\nX-Forwarded-Proto: http\r\n\r\n",
        );
        assert!(response.starts_with("HTTP/1.1 301"), "{response}");
        assert!(response.contains("Location: https://fluxa.example/confidentialite?x=1"));

        let secure = request(
            &address,
            "GET / HTTP/1.1\r\nHost: fluxa.example\r\nX-Forwarded-Proto: https\r\n\r\n",
        );
        assert!(secure.contains("Strict-Transport-Security: max-age=31536000"));
    }

    #[test]
    fn decodes_paths() {
        assert_eq!(percent_decode("/a%20b").as_deref(), Some("/a b"));
        assert_eq!(percent_decode("/%zz"), None);
        assert_eq!(percent_decode("/a/../b"), None);
        assert_eq!(percent_decode("sans-barre"), None);
    }
}
