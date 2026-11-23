//! Ce que coûte une connexion relayée en descripteurs de fichiers. Dans un fichier à part :
//! le test tourne seul dans son processus, et le compte n'est pas faussé par d'autres tests.

use fluxa_shaper::relay::Relay;
use std::io::{Read, Write};
use std::net::{TcpListener, TcpStream};
use std::thread;
use std::time::{Duration, Instant};

fn open_descriptors() -> usize {
    std::fs::read_dir("/dev/fd").unwrap().count()
}

/// Ouvre un tunnel CONNECT à travers le relais vers `target`.
fn tunnel(relay: &Relay, target: u16) -> TcpStream {
    let mut stream = TcpStream::connect(("127.0.0.1", relay.port())).unwrap();
    write!(
        stream,
        "CONNECT 127.0.0.1:{target} HTTP/1.1\r\nHost: 127.0.0.1:{target}\r\n\r\n"
    )
    .unwrap();
    let mut answer = [0u8; 12];
    stream.read_exact(&mut answer).unwrap();
    assert_eq!(&answer, b"HTTP/1.1 200");
    stream
}

#[test]
fn a_relayed_connection_costs_few_descriptors() {
    // Un serveur qui garde ses connexions ouvertes.
    let listener = TcpListener::bind("127.0.0.1:0").unwrap();
    let target = listener.local_addr().unwrap().port();
    thread::spawn(move || {
        let mut held = Vec::new();
        for stream in listener.incoming() {
            held.push(stream.unwrap());
        }
    });
    let relay = Relay::start(0, true).unwrap();
    thread::sleep(Duration::from_millis(100));

    const TUNNELS: usize = 10;
    let before = open_descriptors();
    let tunnels: Vec<TcpStream> = (0..TUNNELS).map(|_| tunnel(&relay, target)).collect();
    // Le temps que chaque tunnel ait ses deux fils en place.
    let deadline = Instant::now() + Duration::from_secs(2);
    let mut during = open_descriptors();
    while Instant::now() < deadline {
        thread::sleep(Duration::from_millis(50));
        during = open_descriptors();
    }
    let per_tunnel = (during - before) as f64 / TUNNELS as f64;
    // Par tunnel : la socket du test et celle que le serveur garde (2), puis, pour le
    // relais, le client et le serveur et leur copie gardée pour l'arrêt du relais (4).
    eprintln!("{per_tunnel} descripteurs par tunnel");
    assert!(per_tunnel <= 6.0, "{per_tunnel} descripteurs par tunnel");
    drop(tunnels);
}
