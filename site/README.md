# Le site de FLUXA

Le site de présentation de FLUXA, écrit en Rust avec [Paquets](https://github.com/maxlestage/Paquets) :
les pages sont rendues par le serveur, et trois îlots prennent vie dans le navigateur, compilés
en WebAssembly à partir des mêmes fonctions.

| Chemin | Rôle |
| --- | --- |
| `src/main.rs` | le serveur, et la commande `export` |
| `src/server/pages.rs` | les pages : accueil, confidentialité, mentions légales, page introuvable |
| `src/server/mod.rs` | l'application Paquets : routes, sécurité, redirection HTTPS, compression |
| `src/server/export.rs` | l'export en fichiers statiques, pour GitHub Pages |
| `src/islands.rs` | les îlots : `menu`, `dashboard` (le tableau de bord animé), `profile-lab` |
| `src/profiles.rs` | les sept profils et la simulation d'un plafond |
| `src/demo.rs` | les mesures fictives du tableau de bord |
| `src/client/` | le bundle du navigateur : hydratation, courbe dans un canvas |
| `public/` | la feuille de style, les polices et l'icône, servies à la racine |
| `tests/` | les pages, les liens et l'export |

## Lancer

Depuis ce dossier, avec Rust et la cible `wasm32-unknown-unknown` :

```sh
../heroku-build.sh                 # le serveur et les îlots (site/pkg)
./target/release/fluxa-site        # http://localhost:3000
```

Pendant le développement, `cargo run` suffit pour les pages. Les îlots demandent le bundle
(`site/pkg`) : relancez `../heroku-build.sh` après avoir modifié `src/islands.rs` ou `src/client/`.
Avec la commande `paquets`, `paquets dev` fait les deux.

```sh
cargo test                                   # pages, liens, export
cargo clippy --all-targets -- -D warnings
```

## Exporter en fichiers statiques

```sh
BASE_PATH=/FLUXA SITE_URL=https://maxlestage.github.io/FLUXA cargo run -- export dist
```

Chaque page est demandée au serveur lui-même, par le client de test de Paquets : la version
statique et la version servie sont identiques. `BASE_PATH` préfixe tous les liens.

## Ce qui est interactif

- **Le menu** est un `<details>` : il s'ouvre sans script. L'îlot le referme quand on suit un lien.
- **Le tableau de bord** reçoit une mesure fictive par seconde, et la latence toutes les cinq
  secondes, comme dans l'app. Avec « réduire les animations », il reste sur son image de repos.
- **Le laboratoire des profils** montre le plafond enregistré, ce qu'iOS en fait, et l'effet
  simulé sur le débit mesuré.
- **Le pied de page** est un accordéon natif sur téléphone, en colonnes dépliées au-delà, sans script.

Les polices (Bricolage Grotesque, Hanken Grotesk, JetBrains Mono, licence OFL) sont dans
`public/fonts` : le site ne charge rien depuis un autre service, et la Content-Security-Policy
de Paquets n'autorise que le site lui-même.
