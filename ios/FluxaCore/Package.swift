// swift-tools-version: 5.9
import PackageDescription

// La logique de FLUXA, en Swift pur : mesure du débit, latence, profils, simulation,
// capacités, historique et stockage. Aucune dépendance à UIKit ou SwiftUI : le paquet
// se compile et se teste aussi sous Linux (`swift test`).
let package = Package(
    name: "FluxaCore",
    defaultLocalization: "fr",
    platforms: [.iOS(.v17), .macOS(.v14)],
    products: [
        .library(name: "FluxaCore", targets: ["FluxaCore"])
    ],
    targets: [
        .target(name: "FluxaCore"),
        .testTarget(name: "FluxaCoreTests", dependencies: ["FluxaCore"]),
    ]
)
