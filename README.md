# FLUXA

FLUXA est un moniteur de connexion pour iPhone : débit, latence, consommation, profils de débit
et guide du partage de connexion.

- L'app iOS (`ios/`) est écrite en Swift natif : SwiftUI pour l'interface, un paquet Swift pour la logique.
- Le site (`site/`) est écrit en Rust avec Paquets.

Le site en ligne :

- Heroku : <https://fluxa-app-ded0024c2b45.herokuapp.com/>
- GitHub Pages : <https://maxlestage.github.io/FLUXA/>

## L'app iOS (`ios/`)

| Chemin | Rôle |
| --- | --- |
| `ios/FluxaCore/` | la logique, en Swift pur : mesure du débit, latence, profils, limites et simulation, capacités, historique, stockage. Testée sans l'interface, sous Linux et macOS |
| `ios/App/` | l'app SwiftUI : tableau de bord, mon réseau, partage de connexion, profils, limiteur, historique, réglages, diagnostic |
| `ios/App/Services/` | l'accès au système : compteurs des interfaces (`getifaddrs`), type de réseau (`NWPathMonitor`), génération mobile (CoreTelephony), sonde de latence (`NWConnection`) |
| `ios/project.yml` | le projet Xcode, décrit pour [XcodeGen](https://github.com/yonaskolb/XcodeGen) |

```sh
cd ios/FluxaCore && swift test          # la logique, sans Xcode
brew install xcodegen
cd ios && xcodegen generate && open Fluxa.xcodeproj
```

iOS 17 au minimum. L'identifiant `app.fluxa.ios` de `project.yml` est provisoire : remplacez-le
par celui de votre compte développeur avant de signer.

Ce que l'app ne fait pas, parce qu'iOS le réserve au système : activer le partage de connexion,
en limiter le débit, lister ou déconnecter les appareils reliés. Un plafond réglé dans l'app est
enregistré et simulé sur le débit mesuré ; son statut reste « Simulé », jamais « Appliqué ».

## Le site (`site/`)

Une application [Paquets](https://github.com/maxlestage/Paquets) : pages rendues par le serveur,
trois îlots en WebAssembly (menu, tableau de bord animé, laboratoire des profils), export
statique pour GitHub Pages. Il s'installe comme une application (PWA), se lit hors ligne, et
chaque lien partagé affiche sa carte. Voir [`site/README.md`](site/README.md).

```sh
./heroku-build.sh                          # le serveur et les îlots
cd site && ./target/release/fluxa-site     # http://localhost:3000
```

## Déploiement

| Cible | Comment |
| --- | --- |
| Heroku (`fluxa-app`, région eu, pile heroku-26) | buildpack [emk/rust](https://elements.heroku.com/buildpacks/emk/heroku-buildpack-rust) : `RustConfig` saute la construction par défaut et lance `heroku-build.sh`, le `Procfile` démarre `site/target/release/fluxa-site` |
| GitHub Pages | `.github/workflows/pages.yml` compile les îlots, exporte le site derrière `/FLUXA` et le publie |

Les deux workflows partent d'un push sur `master` qui touche le site. Un troisième, `ios.yml`,
teste `FluxaCore`, compile l'app pour le simulateur et garde une capture d'écran.

Pour que GitHub Actions déploie aussi sur Heroku (Settings → Secrets and variables → Actions) :

- secret `HEROKU_API_KEY` : Heroku → Account settings → API Key ;
- variable `HEROKU_APP_NAME` : `fluxa-app` ;
- variable facultative `HEROKU_REGION` : `eu` par défaut.

Sans eux, `heroku.yml` teste le site et s'arrête là.

## À compléter avant d'annoncer le site

- Mentions légales : éditeur, hébergeur, adresse de contact (`site/src/server/pages.rs`, champs « à compléter »).
- Politique de confidentialité : adresse de contact.
- Lien App Store ou TestFlight, quand il existe (`store_badge` et les boutons « Bientôt sur l'App Store »).

Les débits, latences et consommations affichés sur le site sont des données de démonstration
(`site/src/demo.rs`).
