# FLUXA pour iPhone

L'app est écrite en Swift natif : SwiftUI pour l'interface, un paquet Swift (`FluxaCore`) pour la
logique. iOS 17 au minimum.

| Chemin | Rôle |
| --- | --- |
| `FluxaCore/` | la logique, testée sans l'interface sous Linux et macOS : débit, latence, profils, limites et simulation, automatisations, appareils, historique, volume par réseau, rattrapage hors de l'app, forfait mobile, sessions de partage, stockage SQLite |
| `App/` | l'app SwiftUI et l'accès au système (`App/Services/`) |
| `AppTests/` | les règles de l'interface : écriture des mesures, échelles, résumés |
| `AppUITests/` | l'app lancée dans le simulateur et manipulée écran par écran |
| `Config/` | l'identité de l'app et sa signature |
| `project.yml` | le projet Xcode, décrit pour [XcodeGen](https://github.com/yonaskolb/XcodeGen) |

## Tester la logique, sans Xcode

```sh
cd FluxaCore && swift test
```

Sous Linux, il faut les en-têtes de SQLite : `sudo apt-get install libsqlite3-dev`.

## Ouvrir le projet

```sh
brew install xcodegen
xcodegen generate
open Fluxa.xcodeproj
```

Le projet et `App/Info.plist` sont écrits par XcodeGen : ils ne sont pas dans le dépôt.
Relancez `xcodegen generate` après avoir ajouté ou déplacé un fichier.

## Installer l'app sur votre iPhone

1. Copiez `Config/Signing.local.xcconfig.example` en `Config/Signing.local.xcconfig`.
2. Renseignez-y votre équipe (`DEVELOPMENT_TEAM`) et un identifiant d'app à vous
   (`FLUXA_BUNDLE_ID`). L'identifiant `app.fluxa.ios` du dépôt est provisoire.
3. `xcodegen generate`, puis ouvrez le projet, branchez l'iPhone, choisissez-le comme
   destination et lancez (⌘R). Xcode crée le profil de provisionnement.

Un identifiant Apple gratuit suffit pour l'installer sur votre propre iPhone ; l'app doit alors
être réinstallée tous les sept jours. TestFlight et l'App Store demandent l'adhésion payante au
programme développeur.

À vérifier sur un vrai iPhone, parce que le simulateur ne le permet pas :

- le débit en réseau mobile, et l'affichage 4G ou 5G ;
- la mesure pendant un partage de connexion, l'état « Détecté » du partage, et les volumes de la
  session lus sur l'interface de pont (`bridge100`) ;
- le rattrapage du réseau mobile au retour dans l'app, comparé au compteur de l'opérateur ;
- les notifications des automatisations ;
- le test de débit complet (jusqu'à 260 Mo sur une connexion rapide).

## Envoyer sur TestFlight

Le workflow `.github/workflows/ios-release.yml` archive l'app et l'envoie sur TestFlight, sans Mac.
Il se lance à la main (Actions → iOS release → Run workflow) et demande trois secrets GitHub, tirés
d'une clé d'API App Store Connect au rôle Admin : `ASC_KEY_ID`, `ASC_ISSUER_ID` et `ASC_KEY` (le
contenu du fichier `.p8`). L'identifiant de l'app et celui de l'équipe sont retrouvés dans App Store
Connect par `Config/appstoreconnect.py`, qui enregistre l'identifiant `com.maxlestage.fluxa` ; l'app doit y avoir été créée une fois à la main. Son en-tête détaille les
étapes.

## Lancer l'app sur un écran donné

Pour les captures d'écran et les tests :

| Argument | Effet |
| --- | --- |
| `-fluxaTab reseau\|partage\|profils\|historique\|reglages` | ouvre l'app sur cet onglet |
| `-fluxaScreen reseau\|limiteur\|diagnostic\|test\|automatisations\|appareils\|forfait` | ouvre cet écran seul |
| `-hasSeenWelcome YES` | saute l'accueil du premier lancement |
| `-fluxaShortSpeedTest YES` | raccourcit le test de débit |
| `-fluxaAbsenceMinimum 1` | signale une absence dès une seconde (une minute sinon) |

## Ce que l'app ne fait pas

iOS réserve au système l'activation du partage de connexion, la limitation de son débit, la liste
des appareils reliés et leur déconnexion. Un plafond réglé dans l'app est enregistré et simulé sur
le débit mesuré ; son statut reste « Simulé », jamais « Appliqué ».

Les mesures et les règles ne tournent que lorsque l'app est ouverte : iOS la suspend en
arrière-plan.

## Ce que l'app compte quand elle est fermée

Les compteurs d'octets du système sont cumulés depuis le démarrage de l'iPhone. Au retour dans
l'app, FLUXA compare leur valeur à celle du dernier relevé et en tire le volume échangé entre-temps,
par réseau. C'est un minimum : ces compteurs sont sur 32 bits et repartent de zéro tous les 4 Go,
et rien ne peut être rattrapé après un redémarrage de l'iPhone. Ce volume alimente le suivi du
forfait mobile, que l'utilisateur peut recaler sur le nombre de son opérateur.

Le partage de connexion crée une interface de pont : FLUXA y lit le trafic de tous les appareils
reliés ensemble (durée et volume de la session), sans détail par appareil.
