// swift-tools-version: 5.9
import PackageDescription

// La logique de FLUXA, en Swift pur : mesure du débit, latence, profils, simulation,
// capacités, historique et stockage. Aucune dépendance à UIKit ou SwiftUI : le paquet
// se compile et se teste aussi sous Linux (`swift test`).
//
// Le stockage SQLite utilise la bibliothèque du système : le module `SQLite3` du SDK sur
// les plateformes Apple, et `CSQLite` (libsqlite3-dev) sous Linux seulement.
let package = Package(
    name: "FluxaCore",
    defaultLocalization: "fr",
    platforms: [.iOS(.v17), .macOS(.v14)],
    products: [
        .library(name: "FluxaCore", targets: ["FluxaCore"])
    ],
    targets: [
        .systemLibrary(
            name: "CSQLite",
            pkgConfig: "sqlite3",
            providers: [.apt(["libsqlite3-dev"])]
        ),
        .target(
            name: "FluxaCore",
            dependencies: [
                .target(name: "CSQLite", condition: .when(platforms: [.linux]))
            ]
        ),
        .testTarget(name: "FluxaCoreTests", dependencies: ["FluxaCore"]),
    ]
)
