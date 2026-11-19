# FLUXA

FLUXA est un moniteur de connexion pour iPhone : débit, latence, consommation, profils de débit
et guide du partage de connexion. Tout le dépôt est en Rust, sauf l'interface de l'app, en SwiftUI.

- Site sur Heroku : <https://fluxa-app-ded0024c2b45.herokuapp.com/>
- Site sur GitHub Pages : <https://maxlestage.github.io/FLUXA/>

## Le site (`site/`)

Une application [Paquets](https://github.com/maxlestage/Paquets) : pages rendues par le serveur,
trois îlots en WebAssembly (menu, tableau de bord animé, laboratoire des profils), export
statique pour GitHub Pages. Voir [`site/README.md`](site/README.md).

```sh
./heroku-build.sh                          # le serveur et les îlots
cd site && ./target/release/fluxa-site     # http://localhost:3000
```

## Déploiement

| Cible | Comment |
| --- | --- |
| Heroku (`fluxa-app`, région eu, pile heroku-26) | buildpack [emk/rust](https://elements.heroku.com/buildpacks/emk/heroku-buildpack-rust) : `RustConfig` saute la construction par défaut et lance `heroku-build.sh`, le `Procfile` démarre `site/target/release/fluxa-site` |
| GitHub Pages | `.github/workflows/pages.yml` compile les îlots, exporte le site derrière `/FLUXA` et le publie |

Les deux workflows partent d'un push sur `master` qui touche le site.

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
