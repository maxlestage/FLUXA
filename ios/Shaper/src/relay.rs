//! Le relais de partage : un serveur mandataire (HTTP, HTTPS par CONNECT, SOCKS5) que
//! FLUXA ouvre sur l'iPhone, sur l'adresse du partage de connexion.
//!
//! iOS ne laisse aucune app brider le partage de connexion par le système. En revanche,
//! une app peut recevoir des connexions : un appareil relié au partage qui règle son
//! mandataire sur l'iPhone (à la main, ou par le fichier de configuration automatique
//! que le relais sert sur `/proxy.pac`) fait passer son trafic par FLUXA. Le relais le
//! transmet, le compte par appareil (adresse IP) et le plafonne avec des seaux à jetons :
//! un plafond global, et un plafond par appareil s'il est réglé.
//!
//! Ce que le relais ne voit pas : le trafic d'un appareil qui n'utilise pas le
//! mandataire, et ce que les apps envoient hors mandataire (UDP, certaines apps). Le
//! plafond est donc réellement appliqué au trafic relayé, et à lui seul.
//!
//! Sécurité : seuls les appareils du partage de connexion (réseaux des interfaces de pont,
//! et 172.20.10.0/28) sont servis, et la boucle locale si on le demande. Le relais n'est
//! jamais un mandataire ouvert sur un Wi-Fi public.

use std::collections::HashMap;
use std::io::{self, Read, Write};
use std::net::{IpAddr, Ipv4Addr, Shutdown, SocketAddr, TcpListener, TcpStream, ToSocketAddrs};
use std::sync::atomic::{AtomicBool, AtomicU64, AtomicUsize, Ordering};
use std::sync::{Arc, Mutex, MutexGuard};
use std::thread;
use std::time::{Duration, Instant};

/// Le nombre de connexions relayées en même temps. Chaque connexion occupe deux fils
/// d'exécution : au-delà, les nouvelles sont refusées, pour que l'extension réseau reste
/// sous la limite de mémoire qu'iOS lui impose (environ 50 Mo). Un navigateur réessaie.
pub const MAX_CONNECTIONS: usize = 192;

/// Après la fermeture côté appareil, le temps laissé au serveur pour finir sa réponse
/// (silence maximal entre deux envois) avant de libérer la connexion.
const CLOSE_GRACE: Duration = Duration::from_secs(15);

/// La pile de chaque fil de connexion : de quoi lire, résoudre un nom et relayer, sans
/// réserver les 2 Mo par défaut.
const CONNECTION_STACK: usize = 256 * 1024;

/// Un plafond dans chaque sens, en octets par seconde. Zéro : sans plafond.
#[derive(Debug, Clone, Copy, Default, PartialEq, Eq)]
pub struct Limit {
    /// Vers l'appareil (son téléchargement).
    pub download: u64,
    /// Depuis l'appareil (son envoi).
    pub upload: u64,
}

impl Limit {
    pub fn is_none(&self) -> bool {
        self.download == 0 && self.upload == 0
    }
}

#[derive(Debug, Clone, Copy, PartialEq, Eq)]
enum Direction {
    Download,
    Upload,
}

/// Un seau à jetons. Les jetons peuvent passer sous zéro : la dette se paie en attente.
#[derive(Debug)]
struct Bucket {
    rate: u64,
    tokens: f64,
    last: Instant,
}

impl Bucket {
    fn new(rate: u64) -> Self {
        let mut bucket = Bucket {
            rate: 0,
            tokens: 0.0,
            last: Instant::now(),
        };
        bucket.set_rate(rate);
        bucket
    }

    /// Un quart de seconde de débit, et au moins 16 ko : de quoi lisser sans à-coups.
    fn burst(&self) -> f64 {
        (self.rate as f64 * 0.25).max(16_384.0)
    }

    fn set_rate(&mut self, rate: u64) {
        if rate != self.rate {
            self.rate = rate;
            self.tokens = self.burst();
            self.last = Instant::now();
        }
    }

    /// Prend `amount` octets et renvoie l'attente avant de les laisser passer.
    fn reserve(&mut self, amount: usize, now: Instant) -> Duration {
        if self.rate == 0 {
            return Duration::ZERO;
        }
        let elapsed = now.saturating_duration_since(self.last).as_secs_f64();
        self.last = now;
        self.tokens = (self.tokens + elapsed * self.rate as f64).min(self.burst());
        self.tokens -= amount as f64;
        if self.tokens >= 0.0 {
            Duration::ZERO
        } else {
            Duration::from_secs_f64(-self.tokens / self.rate as f64)
        }
    }
}

#[derive(Debug)]
struct Client {
    download: Bucket,
    upload: Bucket,
    to_device: u64,
    from_device: u64,
    connections: u32,
    last_seen: Instant,
}

impl Client {
    fn new() -> Self {
        Client {
            download: Bucket::new(0),
            upload: Bucket::new(0),
            to_device: 0,
            from_device: 0,
            connections: 0,
            last_seen: Instant::now(),
        }
    }
}

#[derive(Debug)]
struct State {
    global: Limit,
    global_download: Bucket,
    global_upload: Bucket,
    overrides: HashMap<IpAddr, Limit>,
    clients: HashMap<IpAddr, Client>,
}

struct Shared {
    stop: AtomicBool,
    allow_loopback: bool,
    /// Les connexions en cours, et leur maximum.
    active: AtomicUsize,
    max_connections: usize,
    /// Voir `CLOSE_GRACE` ; plus court dans les tests.
    close_grace: Mutex<Duration>,
    state: Mutex<State>,
    sockets: Mutex<HashMap<u64, TcpStream>>,
    next_socket: AtomicU64,
}

/// Un verrou empoisonné par une panique ailleurs reste utilisable : l'état est simple.
fn lock<T>(mutex: &Mutex<T>) -> MutexGuard<'_, T> {
    mutex
        .lock()
        .unwrap_or_else(|poisoned| poisoned.into_inner())
}

impl Shared {
    fn register(&self, stream: &TcpStream) -> Option<u64> {
        let clone = stream.try_clone().ok()?;
        let id = self.next_socket.fetch_add(1, Ordering::Relaxed);
        lock(&self.sockets).insert(id, clone);
        Some(id)
    }

    fn unregister(&self, id: Option<u64>) {
        if let Some(id) = id {
            lock(&self.sockets).remove(&id);
        }
    }

    /// Compte `amount` octets pour cet appareil et attend ce que les plafonds imposent.
    fn throttle(&self, peer: IpAddr, direction: Direction, amount: usize) {
        let wait = {
            let mut state = lock(&self.state);
            let now = Instant::now();
            let device_limit = state.overrides.get(&peer).copied().unwrap_or_default();
            let global_wait = match direction {
                Direction::Download => state.global_download.reserve(amount, now),
                Direction::Upload => state.global_upload.reserve(amount, now),
            };
            let client = state.clients.entry(peer).or_insert_with(Client::new);
            client.last_seen = now;
            let device_wait = match direction {
                Direction::Download => {
                    client.to_device = client.to_device.saturating_add(amount as u64);
                    client.download.set_rate(device_limit.download);
                    client.download.reserve(amount, now)
                }
                Direction::Upload => {
                    client.from_device = client.from_device.saturating_add(amount as u64);
                    client.upload.set_rate(device_limit.upload);
                    client.upload.reserve(amount, now)
                }
            };
            global_wait.max(device_wait)
        };
        // L'attente se fait hors du verrou, par tranches, pour s'arrêter vite au besoin.
        let deadline = Instant::now() + wait;
        while !self.stop.load(Ordering::Relaxed) {
            let left = deadline.saturating_duration_since(Instant::now());
            if left.is_zero() {
                break;
            }
            thread::sleep(left.min(Duration::from_millis(100)));
        }
    }

    fn connection_opened(&self, peer: IpAddr) {
        let mut state = lock(&self.state);
        let client = state.clients.entry(peer).or_insert_with(Client::new);
        client.connections += 1;
        client.last_seen = Instant::now();
    }

    fn connection_closed(&self, peer: IpAddr) {
        if let Some(client) = lock(&self.state).clients.get_mut(&peer) {
            client.connections = client.connections.saturating_sub(1);
            client.last_seen = Instant::now();
        }
    }

    fn allows(&self, peer: IpAddr) -> bool {
        if peer.is_loopback() {
            return self.allow_loopback;
        }
        allowed(peer, &sharing_networks())
    }
}

/// Le relais en service. Il s'arrête quand on l'abandonne.
pub struct Relay {
    shared: Arc<Shared>,
    accept: Option<thread::JoinHandle<()>>,
    port: u16,
}

impl Relay {
    /// Ouvre le relais sur ce port (0 : un port libre). `allow_loopback` sert aussi la
    /// boucle locale : pour les tests, et pour le simulateur.
    pub fn start(port: u16, allow_loopback: bool) -> io::Result<Relay> {
        Self::start_with_capacity(port, allow_loopback, MAX_CONNECTIONS)
    }

    /// Comme `start`, avec un autre maximum de connexions simultanées.
    pub fn start_with_capacity(
        port: u16,
        allow_loopback: bool,
        max_connections: usize,
    ) -> io::Result<Relay> {
        // Une attente bloquante : le fil d'accueil dort jusqu'à la prochaine connexion,
        // au lieu de se réveiller sans cesse. Utile en arrière-plan, dans l'extension.
        let listener = TcpListener::bind((Ipv4Addr::UNSPECIFIED, port))?;
        let port = listener.local_addr()?.port();
        let shared = Arc::new(Shared {
            stop: AtomicBool::new(false),
            allow_loopback,
            active: AtomicUsize::new(0),
            max_connections: max_connections.max(1),
            close_grace: Mutex::new(CLOSE_GRACE),
            state: Mutex::new(State {
                global: Limit::default(),
                global_download: Bucket::new(0),
                global_upload: Bucket::new(0),
                overrides: HashMap::new(),
                clients: HashMap::new(),
            }),
            sockets: Mutex::new(HashMap::new()),
            next_socket: AtomicU64::new(1),
        });
        let accepting = Arc::clone(&shared);
        let accept = thread::Builder::new()
            .name("fluxa-relay-accept".into())
            .spawn(move || accept_loop(&accepting, &listener))?;
        Ok(Relay {
            shared,
            accept: Some(accept),
            port,
        })
    }

    pub fn port(&self) -> u16 {
        self.port
    }

    #[cfg(test)]
    fn set_close_grace(&self, grace: Duration) {
        *lock(&self.shared.close_grace) = grace;
    }

    /// Le plafond de tout le trafic relayé.
    pub fn set_limit(&self, limit: Limit) {
        let mut state = lock(&self.shared.state);
        state.global = limit;
        state.global_download.set_rate(limit.download);
        state.global_upload.set_rate(limit.upload);
    }

    /// Le plafond d'un appareil. Un plafond nul le retire.
    pub fn set_device_limit(&self, address: IpAddr, limit: Limit) {
        let mut state = lock(&self.shared.state);
        if limit.is_none() {
            state.overrides.remove(&address);
        } else {
            state.overrides.insert(address, limit);
        }
    }

    /// L'état du relais en JSON : plafonds, et pour chaque appareil vu depuis dix minutes,
    /// ses connexions ouvertes et les octets relayés dans chaque sens.
    pub fn status_json(&self) -> String {
        let state = lock(&self.shared.state);
        let now = Instant::now();
        let mut clients: Vec<(&IpAddr, &Client)> = state
            .clients
            .iter()
            .filter(|(_, client)| {
                client.connections > 0
                    || now.duration_since(client.last_seen) < Duration::from_secs(600)
            })
            .collect();
        clients.sort_by_key(|(address, _)| **address);
        let clients: Vec<String> = clients
            .into_iter()
            .map(|(address, client)| {
                let limit = state.overrides.get(address).copied().unwrap_or_default();
                format!(
                    "{{\"address\":\"{address}\",\"connections\":{},\"to_device_bytes\":{},\"from_device_bytes\":{},\
                     \"idle_seconds\":{:.1},\"download_limit\":{},\"upload_limit\":{}}}",
                    client.connections,
                    client.to_device,
                    client.from_device,
                    now.duration_since(client.last_seen).as_secs_f64(),
                    limit.download,
                    limit.upload,
                )
            })
            .collect();
        let addresses: Vec<String> = sharing_networks()
            .iter()
            .map(|(address, _)| format!("\"{address}\""))
            .collect();
        format!(
            "{{\"running\":true,\"port\":{},\"active_connections\":{},\"max_connections\":{},\"download_limit\":{},\"upload_limit\":{},\"addresses\":[{}],\"clients\":[{}]}}",
            self.port,
            self.shared.active.load(Ordering::Relaxed),
            self.shared.max_connections,
            state.global.download,
            state.global.upload,
            addresses.join(","),
            clients.join(","),
        )
    }

    /// Arrête le relais et coupe les connexions en cours.
    pub fn stop(&mut self) {
        self.shared.stop.store(true, Ordering::Relaxed);
        for socket in lock(&self.shared.sockets).values() {
            let _ = socket.shutdown(Shutdown::Both);
        }
        if let Some(accept) = self.accept.take() {
            // Le fil d'accueil attend une connexion : une connexion locale le réveille, il
            // voit l'arrêt demandé et referme l'écoute.
            let _ = TcpStream::connect_timeout(
                &SocketAddr::from((Ipv4Addr::LOCALHOST, self.port)),
                Duration::from_secs(1),
            );
            let _ = accept.join();
        }
    }
}

impl Drop for Relay {
    fn drop(&mut self) {
        self.stop();
    }
}

fn accept_loop(shared: &Arc<Shared>, listener: &TcpListener) {
    while !shared.stop.load(Ordering::Relaxed) {
        match listener.accept() {
            Ok((stream, peer)) => {
                // La connexion qui réveille l'arrêt, ou un appareil hors du partage.
                if shared.stop.load(Ordering::Relaxed) || !shared.allows(peer.ip()) {
                    continue;
                }
                // Au maximum, la connexion est refermée aussitôt : l'appareil réessaiera.
                if shared.active.load(Ordering::Relaxed) >= shared.max_connections {
                    continue;
                }
                shared.active.fetch_add(1, Ordering::Relaxed);
                let serving = Arc::clone(shared);
                let spawned = thread::Builder::new()
                    .name("fluxa-relay-connection".into())
                    .stack_size(CONNECTION_STACK)
                    .spawn(move || {
                        serve(&serving, stream, peer);
                        serving.active.fetch_sub(1, Ordering::Relaxed);
                    });
                if spawned.is_err() {
                    shared.active.fetch_sub(1, Ordering::Relaxed);
                }
            }
            // Une erreur d'accueil (trop de descripteurs ouverts, écoute coupée par le
            // système) : une courte pause avant de réessayer, sans tourner à vide.
            Err(_) => thread::sleep(Duration::from_millis(200)),
        }
    }
}

fn serve(shared: &Arc<Shared>, mut client: TcpStream, peer: SocketAddr) {
    let id = shared.register(&client);
    shared.connection_opened(peer.ip());
    let _ = client.set_nodelay(true);
    let _ = handle(shared, &mut client, peer.ip());
    let _ = client.shutdown(Shutdown::Both);
    shared.connection_closed(peer.ip());
    shared.unregister(id);
}

// MARK: Les protocoles

fn handle(shared: &Arc<Shared>, client: &mut TcpStream, peer: IpAddr) -> io::Result<()> {
    client.set_read_timeout(Some(Duration::from_secs(30)))?;
    let head = read_head(client)?;
    if head.first() == Some(&5) {
        return socks5(shared, client, peer, head);
    }
    let end = find(&head, b"\r\n\r\n")
        .map(|index| index + 4)
        .ok_or(io::ErrorKind::InvalidData)?;
    let text = String::from_utf8_lossy(&head[..end]).into_owned();
    let rest = &head[end..];
    let mut lines = text.split("\r\n");
    let request = lines.next().unwrap_or_default();
    let mut parts = request.split_whitespace();
    let (method, target, version) = (
        parts.next().unwrap_or_default(),
        parts.next().unwrap_or_default(),
        parts.next().unwrap_or("HTTP/1.1"),
    );

    if method.eq_ignore_ascii_case("CONNECT") {
        let (host, port) = split_host_port(target, 443).ok_or(io::ErrorKind::InvalidData)?;
        let Ok(mut upstream) = connect(&host, port) else {
            client.write_all(
                b"HTTP/1.1 502 Bad Gateway\r\nContent-Length: 0\r\nConnection: close\r\n\r\n",
            )?;
            return Ok(());
        };
        client.write_all(b"HTTP/1.1 200 Connection Established\r\n\r\n")?;
        if !rest.is_empty() {
            upstream.write_all(rest)?;
        }
        return tunnel(shared, client, upstream, peer);
    }

    if let Some(url) = target.strip_prefix("http://") {
        let (authority, path) = match url.find('/') {
            Some(index) => (&url[..index], &url[index..]),
            None => (url, "/"),
        };
        let (host, port) = split_host_port(authority, 80).ok_or(io::ErrorKind::InvalidData)?;
        let Ok(mut upstream) = connect(&host, port) else {
            client.write_all(
                b"HTTP/1.1 502 Bad Gateway\r\nContent-Length: 0\r\nConnection: close\r\n\r\n",
            )?;
            return Ok(());
        };
        // Une connexion par requête : la suivante peut viser un autre serveur.
        let mut forwarded = format!("{method} {path} {version}\r\n");
        for line in lines.filter(|line| !line.is_empty()) {
            let name = line
                .split(':')
                .next()
                .unwrap_or_default()
                .trim()
                .to_ascii_lowercase();
            if !matches!(
                name.as_str(),
                "proxy-connection" | "proxy-authorization" | "connection" | "keep-alive"
            ) {
                forwarded.push_str(line);
                forwarded.push_str("\r\n");
            }
        }
        forwarded.push_str("Connection: close\r\n\r\n");
        upstream.write_all(forwarded.as_bytes())?;
        if !rest.is_empty() {
            upstream.write_all(rest)?;
        }
        return tunnel(shared, client, upstream, peer);
    }

    if target.starts_with('/') {
        let local = client.local_addr()?.ip();
        let port = client.local_addr()?.port();
        let (kind, body) = if target.starts_with("/proxy.pac") || target.starts_with("/wpad.dat") {
            ("application/x-ns-proxy-autoconfig", pac(local, port))
        } else {
            (
                "text/plain; charset=utf-8",
                format!("Relais FLUXA en service. Mandataire : {local}:{port}. Configuration automatique : http://{local}:{port}/proxy.pac\n"),
            )
        };
        let response = format!(
            "HTTP/1.1 200 OK\r\nContent-Type: {kind}\r\nContent-Length: {}\r\nCache-Control: no-store\r\nConnection: close\r\n\r\n{body}",
            body.len()
        );
        client.write_all(response.as_bytes())?;
        return Ok(());
    }

    client
        .write_all(b"HTTP/1.1 400 Bad Request\r\nContent-Length: 0\r\nConnection: close\r\n\r\n")?;
    Ok(())
}

/// Le fichier de configuration automatique : tout passe par le relais, et en direct si
/// le relais ne répond plus (l'appareil n'est jamais privé de connexion).
pub fn pac(address: IpAddr, port: u16) -> String {
    format!(
        "function FindProxyForURL(url, host) {{\n  if (isPlainHostName(host) || shExpMatch(host, \"*.local\")) return \"DIRECT\";\n  return \"PROXY {address}:{port}; SOCKS5 {address}:{port}; DIRECT\";\n}}\n"
    )
}

fn socks5(
    shared: &Arc<Shared>,
    client: &mut TcpStream,
    peer: IpAddr,
    head: Vec<u8>,
) -> io::Result<()> {
    let mut input = Prefixed {
        pending: head,
        position: 0,
    };
    let mut header = [0u8; 2];
    input.read_exact(client, &mut header)?;
    let mut methods = vec![0u8; header[1] as usize];
    input.read_exact(client, &mut methods)?;
    if !methods.contains(&0) {
        client.write_all(&[5, 0xFF])?;
        return Ok(());
    }
    client.write_all(&[5, 0])?;

    let mut request = [0u8; 4];
    input.read_exact(client, &mut request)?;
    if request[1] != 1 {
        client.write_all(&[5, 7, 0, 1, 0, 0, 0, 0, 0, 0])?;
        return Ok(());
    }
    let host = match request[3] {
        1 => {
            let mut address = [0u8; 4];
            input.read_exact(client, &mut address)?;
            Ipv4Addr::from(address).to_string()
        }
        3 => {
            let mut length = [0u8; 1];
            input.read_exact(client, &mut length)?;
            let mut name = vec![0u8; length[0] as usize];
            input.read_exact(client, &mut name)?;
            String::from_utf8_lossy(&name).into_owned()
        }
        4 => {
            let mut address = [0u8; 16];
            input.read_exact(client, &mut address)?;
            std::net::Ipv6Addr::from(address).to_string()
        }
        _ => {
            client.write_all(&[5, 8, 0, 1, 0, 0, 0, 0, 0, 0])?;
            return Ok(());
        }
    };
    let mut port = [0u8; 2];
    input.read_exact(client, &mut port)?;
    let Ok(mut upstream) = connect(&host, u16::from_be_bytes(port)) else {
        client.write_all(&[5, 5, 0, 1, 0, 0, 0, 0, 0, 0])?;
        return Ok(());
    };
    client.write_all(&[5, 0, 0, 1, 0, 0, 0, 0, 0, 0])?;
    let rest = input.remaining();
    if !rest.is_empty() {
        upstream.write_all(rest)?;
    }
    tunnel(shared, client, upstream, peer)
}

/// Des octets déjà lus, puis le reste de la socket.
struct Prefixed {
    pending: Vec<u8>,
    position: usize,
}

impl Prefixed {
    fn read_exact(&mut self, stream: &mut TcpStream, buffer: &mut [u8]) -> io::Result<()> {
        let available = (self.pending.len() - self.position).min(buffer.len());
        buffer[..available]
            .copy_from_slice(&self.pending[self.position..self.position + available]);
        self.position += available;
        stream.read_exact(&mut buffer[available..])
    }

    fn remaining(&self) -> &[u8] {
        &self.pending[self.position..]
    }
}

/// Ce que les deux sens d'un tunnel partagent : la fin du sens descendant, et l'instant
/// de son dernier envoi, en millisecondes depuis l'ouverture.
struct Progress {
    opened: Instant,
    finished: AtomicBool,
    last_download_ms: AtomicU64,
}

impl Progress {
    fn touch(&self) {
        self.last_download_ms
            .store(self.opened.elapsed().as_millis() as u64, Ordering::Relaxed);
    }

    fn silence(&self) -> Duration {
        let last = Duration::from_millis(self.last_download_ms.load(Ordering::Relaxed));
        self.opened.elapsed().saturating_sub(last)
    }
}

/// Relaie dans les deux sens, en plafonnant chacun, jusqu'à la fin de l'échange.
fn tunnel(
    shared: &Arc<Shared>,
    client: &mut TcpStream,
    upstream: TcpStream,
    peer: IpAddr,
) -> io::Result<()> {
    client.set_read_timeout(None)?;
    let _ = upstream.set_nodelay(true);
    let upstream_id = shared.register(&upstream);
    let progress = Arc::new(Progress {
        opened: Instant::now(),
        finished: AtomicBool::new(false),
        last_download_ms: AtomicU64::new(0),
    });

    let sending = Arc::clone(shared);
    let watching = Arc::clone(&progress);
    let from_device = client.try_clone()?;
    let to_server = upstream.try_clone()?;
    let uploader = thread::Builder::new()
        .name("fluxa-relay-upload".into())
        .stack_size(CONNECTION_STACK)
        .spawn(move || {
            let _ = pipe(
                &sending,
                peer,
                from_device,
                to_server.try_clone(),
                Direction::Upload,
                None,
            );
            // L'appareil a fini d'envoyer : le serveur peut finir sa réponse. Un serveur
            // muet trop longtemps ne garde pas la connexion, ni sa place, ni ses fils.
            let _ = to_server.shutdown(Shutdown::Write);
            let grace = *lock(&sending.close_grace);
            while !watching.finished.load(Ordering::Relaxed)
                && !sending.stop.load(Ordering::Relaxed)
            {
                if watching.silence() >= grace {
                    let _ = to_server.shutdown(Shutdown::Both);
                    break;
                }
                thread::sleep(grace.min(Duration::from_millis(100)));
            }
        })?;

    let _ = pipe(
        shared,
        peer,
        upstream.try_clone()?,
        client.try_clone(),
        Direction::Download,
        Some(&progress),
    );
    progress.finished.store(true, Ordering::Relaxed);
    let _ = client.shutdown(Shutdown::Both);
    let _ = upstream.shutdown(Shutdown::Both);
    let _ = uploader.join();
    shared.unregister(upstream_id);
    Ok(())
}

fn pipe(
    shared: &Shared,
    peer: IpAddr,
    mut from: TcpStream,
    to: io::Result<TcpStream>,
    direction: Direction,
    progress: Option<&Progress>,
) -> io::Result<()> {
    let mut to = to?;
    let mut buffer = [0u8; 8192];
    while !shared.stop.load(Ordering::Relaxed) {
        let count = match from.read(&mut buffer) {
            Ok(0) => break,
            Ok(count) => count,
            Err(error) if error.kind() == io::ErrorKind::Interrupted => continue,
            Err(error) => return Err(error),
        };
        shared.throttle(peer, direction, count);
        to.write_all(&buffer[..count])?;
        if let Some(progress) = progress {
            progress.touch();
        }
    }
    Ok(())
}

// MARK: Outils

fn read_head(stream: &mut TcpStream) -> io::Result<Vec<u8>> {
    let mut head = Vec::with_capacity(1024);
    let mut buffer = [0u8; 4096];
    loop {
        let count = stream.read(&mut buffer)?;
        if count == 0 {
            return Err(io::ErrorKind::UnexpectedEof.into());
        }
        head.extend_from_slice(&buffer[..count]);
        if head[0] == 5 || find(&head, b"\r\n\r\n").is_some() {
            return Ok(head);
        }
        if head.len() > 65_536 {
            return Err(io::ErrorKind::InvalidData.into());
        }
    }
}

fn find(haystack: &[u8], needle: &[u8]) -> Option<usize> {
    haystack
        .windows(needle.len())
        .position(|window| window == needle)
}

/// « hôte:port », « [ipv6]:port » ou « hôte » (port par défaut).
fn split_host_port(authority: &str, default_port: u16) -> Option<(String, u16)> {
    if let Some(rest) = authority.strip_prefix('[') {
        let (host, tail) = rest.split_once(']')?;
        let port = match tail.strip_prefix(':') {
            Some(port) => port.parse().ok()?,
            None => default_port,
        };
        return Some((host.to_string(), port));
    }
    match authority.rsplit_once(':') {
        Some((host, port)) if !host.contains(':') => Some((host.to_string(), port.parse().ok()?)),
        _ if !authority.is_empty() => Some((authority.to_string(), default_port)),
        _ => None,
    }
}

fn connect(host: &str, port: u16) -> io::Result<TcpStream> {
    let mut last = io::Error::from(io::ErrorKind::NotFound);
    for address in (host, port).to_socket_addrs()? {
        match TcpStream::connect_timeout(&address, Duration::from_secs(10)) {
            Ok(stream) => return Ok(stream),
            Err(error) => last = error,
        }
    }
    Err(last)
}

/// Si l'adresse appartient à l'un des réseaux (adresse, masque).
pub fn allowed(peer: IpAddr, networks: &[(Ipv4Addr, Ipv4Addr)]) -> bool {
    let IpAddr::V4(peer) = peer else { return false };
    networks.iter().any(|(address, mask)| {
        u32::from(peer) & u32::from(*mask) == u32::from(*address) & u32::from(*mask)
    })
}

/// Les réseaux du partage de connexion : ceux des interfaces de pont (`bridge…`), et
/// toujours 172.20.10.0/28, le réseau que l'iPhone donne aux appareils reliés.
pub fn sharing_networks() -> Vec<(Ipv4Addr, Ipv4Addr)> {
    let mut networks = bridge_networks();
    let default = (
        Ipv4Addr::new(172, 20, 10, 1),
        Ipv4Addr::new(255, 255, 255, 240),
    );
    if !networks.iter().any(|(address, _)| *address == default.0) {
        networks.push(default);
    }
    networks
}

fn bridge_networks() -> Vec<(Ipv4Addr, Ipv4Addr)> {
    let mut networks = Vec::new();
    let mut list: *mut libc::ifaddrs = std::ptr::null_mut();
    // SAFETY : la liste est parcourue en lecture puis rendue par freeifaddrs.
    unsafe {
        if libc::getifaddrs(&mut list) != 0 {
            return networks;
        }
        let mut cursor = list;
        while !cursor.is_null() {
            let entry = &*cursor;
            cursor = entry.ifa_next;
            if entry.ifa_addr.is_null() || entry.ifa_netmask.is_null() || entry.ifa_name.is_null() {
                continue;
            }
            if i32::from((*entry.ifa_addr).sa_family) != libc::AF_INET {
                continue;
            }
            let name = std::ffi::CStr::from_ptr(entry.ifa_name).to_string_lossy();
            if !name.starts_with("bridge") {
                continue;
            }
            let address = &*(entry.ifa_addr as *const libc::sockaddr_in);
            let mask = &*(entry.ifa_netmask as *const libc::sockaddr_in);
            networks.push((
                Ipv4Addr::from(u32::from_be(address.sin_addr.s_addr)),
                Ipv4Addr::from(u32::from_be(mask.sin_addr.s_addr)),
            ));
        }
        libc::freeifaddrs(list);
    }
    networks
}

#[cfg(test)]
mod tests {
    use super::*;
    use std::io::BufRead;

    /// Un petit serveur qui envoie `size` octets à chaque connexion, après avoir lu une
    /// ligne. Renvoie son port.
    fn source(size: usize) -> u16 {
        let listener = TcpListener::bind("127.0.0.1:0").unwrap();
        let port = listener.local_addr().unwrap().port();
        thread::spawn(move || {
            for stream in listener.incoming().flatten() {
                thread::spawn(move || {
                    let mut reader = io::BufReader::new(stream.try_clone().unwrap());
                    let mut line = String::new();
                    let _ = reader.read_line(&mut line);
                    let mut stream = stream;
                    let _ = stream.write_all(&vec![7u8; size]);
                });
            }
        });
        port
    }

    fn through_connect(relay: &Relay, target: u16) -> TcpStream {
        let mut stream = TcpStream::connect(("127.0.0.1", relay.port())).unwrap();
        write!(
            stream,
            "CONNECT 127.0.0.1:{target} HTTP/1.1\r\nHost: 127.0.0.1:{target}\r\n\r\n"
        )
        .unwrap();
        let mut answer = [0u8; 39];
        stream.read_exact(&mut answer).unwrap();
        assert!(
            answer.starts_with(b"HTTP/1.1 200"),
            "{}",
            String::from_utf8_lossy(&answer)
        );
        stream
    }

    fn drain(mut stream: TcpStream) -> usize {
        stream.write_all(b"go\n").unwrap();
        let mut received = Vec::new();
        stream.read_to_end(&mut received).unwrap();
        received.len()
    }

    #[test]
    fn https_tunnels_are_relayed() {
        let relay = Relay::start(0, true).unwrap();
        let target = source(100_000);
        assert_eq!(drain(through_connect(&relay, target)), 100_000);
    }

    #[test]
    fn the_download_cap_really_slows_the_device() {
        let relay = Relay::start(0, true).unwrap();
        // 3,2 Mb/s : 400 ko/s. 600 ko passent en un peu plus d'une seconde, rafale comprise.
        relay.set_limit(Limit {
            download: 400_000,
            upload: 0,
        });
        let target = source(600_000);
        let started = Instant::now();
        assert_eq!(drain(through_connect(&relay, target)), 600_000);
        let elapsed = started.elapsed();
        assert!(
            elapsed >= Duration::from_millis(1_000),
            "trop rapide : {elapsed:?}"
        );
        assert!(elapsed < Duration::from_secs(5), "trop lent : {elapsed:?}");
    }

    #[test]
    fn a_device_cap_applies_to_that_device_only() {
        let relay = Relay::start(0, true).unwrap();
        relay.set_device_limit(
            "127.0.0.2".parse().unwrap(),
            Limit {
                download: 50_000,
                upload: 0,
            },
        );
        let target = source(300_000);
        let started = Instant::now();
        // 127.0.0.1 n'est pas plafonné : l'échange est quasi immédiat.
        assert_eq!(drain(through_connect(&relay, target)), 300_000);
        assert!(started.elapsed() < Duration::from_millis(800));
    }

    #[test]
    fn traffic_is_counted_per_device() {
        let relay = Relay::start(0, true).unwrap();
        let target = source(50_000);
        drain(through_connect(&relay, target));
        thread::sleep(Duration::from_millis(100));
        let status = relay.status_json();
        assert!(status.contains("\"address\":\"127.0.0.1\""), "{status}");
        assert!(status.contains("\"to_device_bytes\":50000"), "{status}");
        assert!(status.contains("\"from_device_bytes\":3"), "{status}");
    }

    #[test]
    fn plain_http_is_rewritten_for_the_server() {
        let listener = TcpListener::bind("127.0.0.1:0").unwrap();
        let port = listener.local_addr().unwrap().port();
        let server = thread::spawn(move || {
            let (stream, _) = listener.accept().unwrap();
            let mut reader = io::BufReader::new(stream.try_clone().unwrap());
            let mut head = String::new();
            loop {
                let mut line = String::new();
                reader.read_line(&mut line).unwrap();
                if line == "\r\n" || line.is_empty() {
                    break;
                }
                head.push_str(&line);
            }
            let mut stream = stream;
            stream
                .write_all(b"HTTP/1.1 200 OK\r\nContent-Length: 2\r\n\r\nok")
                .unwrap();
            head
        });
        let relay = Relay::start(0, true).unwrap();
        let mut stream = TcpStream::connect(("127.0.0.1", relay.port())).unwrap();
        write!(
            stream,
            "GET http://127.0.0.1:{port}/page?x=1 HTTP/1.1\r\nHost: 127.0.0.1:{port}\r\nProxy-Connection: keep-alive\r\n\r\n"
        )
        .unwrap();
        let mut answer = String::new();
        stream.read_to_string(&mut answer).unwrap();
        assert!(answer.ends_with("ok"), "{answer}");
        let head = server.join().unwrap();
        assert!(head.starts_with("GET /page?x=1 HTTP/1.1\r\n"), "{head}");
        assert!(
            !head.to_ascii_lowercase().contains("proxy-connection"),
            "{head}"
        );
        assert!(head.contains("Connection: close"), "{head}");
    }

    #[test]
    fn socks5_is_relayed() {
        let relay = Relay::start(0, true).unwrap();
        let target = source(20_000);
        let mut stream = TcpStream::connect(("127.0.0.1", relay.port())).unwrap();
        stream.write_all(&[5, 1, 0]).unwrap();
        let mut choice = [0u8; 2];
        stream.read_exact(&mut choice).unwrap();
        assert_eq!(choice, [5, 0]);
        let mut request = vec![5, 1, 0, 1, 127, 0, 0, 1];
        request.extend_from_slice(&target.to_be_bytes());
        stream.write_all(&request).unwrap();
        let mut reply = [0u8; 10];
        stream.read_exact(&mut reply).unwrap();
        assert_eq!(reply[1], 0);
        assert_eq!(drain(stream), 20_000);
    }

    #[test]
    fn the_automatic_configuration_points_at_the_relay() {
        let relay = Relay::start(0, true).unwrap();
        let mut stream = TcpStream::connect(("127.0.0.1", relay.port())).unwrap();
        stream
            .write_all(b"GET /proxy.pac HTTP/1.1\r\nHost: x\r\n\r\n")
            .unwrap();
        let mut answer = String::new();
        stream.read_to_string(&mut answer).unwrap();
        assert!(
            answer.contains("application/x-ns-proxy-autoconfig"),
            "{answer}"
        );
        assert!(
            answer.contains(&format!("PROXY 127.0.0.1:{}", relay.port())),
            "{answer}"
        );
        assert!(answer.contains("DIRECT"), "{answer}");
    }

    #[test]
    fn the_loopback_is_refused_unless_asked() {
        let relay = Relay::start(0, false).unwrap();
        let mut stream = TcpStream::connect(("127.0.0.1", relay.port())).unwrap();
        stream
            .set_read_timeout(Some(Duration::from_secs(2)))
            .unwrap();
        let _ = stream.write_all(b"GET /proxy.pac HTTP/1.1\r\n\r\n");
        let mut answer = Vec::new();
        let _ = stream.read_to_end(&mut answer);
        assert!(answer.is_empty(), "le relais a répondu à la boucle locale");
    }

    #[test]
    fn only_the_sharing_network_is_served() {
        let networks = [(
            Ipv4Addr::new(172, 20, 10, 1),
            Ipv4Addr::new(255, 255, 255, 240),
        )];
        assert!(allowed("172.20.10.3".parse().unwrap(), &networks));
        assert!(allowed("172.20.10.14".parse().unwrap(), &networks));
        assert!(!allowed("172.20.10.17".parse().unwrap(), &networks));
        assert!(!allowed("192.168.1.20".parse().unwrap(), &networks));
        assert!(!allowed("::1".parse().unwrap(), &networks));
        assert!(sharing_networks()
            .iter()
            .any(|(address, _)| *address == Ipv4Addr::new(172, 20, 10, 1)));
    }

    #[test]
    fn the_relay_sleeps_while_idle_and_stops_at_once() {
        let mut relay = Relay::start(0, true).unwrap();
        let port = relay.port();
        // Au repos, le fil d'accueil attend : il ne se réveille pas pour rien.
        thread::sleep(Duration::from_millis(300));
        let started = Instant::now();
        relay.stop();
        assert!(
            started.elapsed() < Duration::from_secs(1),
            "arrêt trop lent : {:?}",
            started.elapsed()
        );
        // L'écoute est refermée : plus personne n'est servi.
        thread::sleep(Duration::from_millis(50));
        let refused = TcpStream::connect_timeout(
            &SocketAddr::from((Ipv4Addr::LOCALHOST, port)),
            Duration::from_millis(500),
        );
        assert!(refused.is_err(), "le relais écoute encore après son arrêt");
    }

    #[test]
    fn connections_beyond_the_maximum_are_refused_until_one_closes() {
        // Un serveur qui garde ses connexions ouvertes sans rien envoyer.
        let listener = TcpListener::bind("127.0.0.1:0").unwrap();
        let target = listener.local_addr().unwrap().port();
        thread::spawn(move || {
            let mut held = Vec::new();
            for stream in listener.incoming().flatten() {
                held.push(stream);
            }
        });
        let relay = Relay::start_with_capacity(0, true, 2).unwrap();
        relay.set_close_grace(Duration::from_millis(300));
        let first = through_connect(&relay, target);
        let _second = through_connect(&relay, target);
        assert!(
            relay.status_json().contains("\"active_connections\":2"),
            "{}",
            relay.status_json()
        );

        // La troisième est refermée sans réponse.
        let mut third = TcpStream::connect(("127.0.0.1", relay.port())).unwrap();
        third
            .set_read_timeout(Some(Duration::from_secs(2)))
            .unwrap();
        let _ = write!(third, "CONNECT 127.0.0.1:{target} HTTP/1.1\r\n\r\n");
        let mut answer = Vec::new();
        let _ = third.read_to_end(&mut answer);
        assert!(answer.is_empty(), "la connexion de trop a été servie");

        // Une connexion se ferme : la place se libère.
        drop(first);
        let deadline = Instant::now() + Duration::from_secs(3);
        while relay.status_json().contains("\"active_connections\":2") && Instant::now() < deadline
        {
            thread::sleep(Duration::from_millis(20));
        }
        let _again = through_connect(&relay, target);
    }

    #[test]
    fn host_and_port_are_split() {
        assert_eq!(
            split_host_port("example.com:8443", 443),
            Some(("example.com".into(), 8443))
        );
        assert_eq!(
            split_host_port("example.com", 443),
            Some(("example.com".into(), 443))
        );
        assert_eq!(
            split_host_port("[2001:db8::1]:80", 443),
            Some(("2001:db8::1".into(), 80))
        );
        assert_eq!(
            split_host_port("[2001:db8::1]", 443),
            Some(("2001:db8::1".into(), 443))
        );
        assert_eq!(split_host_port("", 443), None);
    }

    #[test]
    fn the_bucket_spreads_the_bytes_over_time() {
        let mut bucket = Bucket::new(100_000);
        let start = Instant::now();
        // La rafale passe d'un coup ; au-delà, l'attente suit le débit.
        assert_eq!(bucket.reserve(25_000, start), Duration::ZERO);
        let wait = bucket.reserve(50_000, start);
        assert!((wait.as_secs_f64() - 0.5).abs() < 0.01, "{wait:?}");
        assert_eq!(Bucket::new(0).reserve(1_000_000, start), Duration::ZERO);
    }
}
