# FLUXA

Site de présentation de FLUXA, le moniteur de connexion pour iPhone.

- En ligne sur Heroku : <https://fluxa-app-ded0024c2b45.herokuapp.com/>
- GitHub Pages : publié par le workflow `pages.yml` une fois Pages activé (voir plus bas)

Le site est statique et mobile first. Il vit dans `public/` et n'a pas d'étape de build.
Un petit serveur Rust (`src/main.rs`) le sert sur Heroku.

## Structure

| Chemin | Rôle |
| --- | --- |
| `public/index.html` | Page d'accueil |
| `public/confidentialite.html` | Politique de confidentialité |
| `public/mentions-legales.html` | Mentions légales et conditions d'utilisation |
| `public/404.html` | Page d'erreur, pour Heroku et GitHub Pages |
| `public/assets/site.css` | Styles (jetons de couleur et de typographie en tête de fichier) |
| `public/assets/site.js` | Menu mobile, accordéon du pied de page, démonstrations |
| `src/main.rs` | Serveur : gzip, ETag, cache, en-têtes de sécurité, redirection HTTPS |
| `Procfile`, `RustConfig`, `app.json` | Heroku avec le buildpack `emk/rust` |
| `.github/workflows/heroku.yml` | Déploiement Heroku à chaque push sur `master` |
| `.github/workflows/pages.yml` | Déploiement GitHub Pages à chaque push sur `master` |

L'en-tête et le pied de page sont dupliqués dans les trois pages. Sur les pages légales, les
ancres pointent vers `index.html#…`. Les pages n'ont ni style ni script en ligne : la
Content-Security-Policy du serveur n'autorise que les fichiers du site et Google Fonts.

## En local

```sh
cargo run            # http://localhost:3000
cargo test
```

Sans Rust : `python3 -m http.server 8000 --directory public`.

## Heroku

L'application `fluxa-app` (région eu, pile heroku-26) utilise le buildpack
[emk/rust](https://elements.heroku.com/buildpacks/emk/heroku-buildpack-rust). Il lit `RustConfig`,
lance `cargo build --release`, et le `Procfile` démarre `target/release/fluxa-site`.

Pour que GitHub Actions déploie chaque push sur `master`
(Settings → Secrets and variables → Actions) :

- secret `HEROKU_API_KEY` : Heroku → Account settings → API Key ;
- variable `HEROKU_APP_NAME` : `fluxa-app` ;
- variable facultative `HEROKU_REGION` : `eu` par défaut.

Sans eux, le workflow passe sans rien déployer.

## GitHub Pages

Une fois, dans GitHub : Settings → Pages → Build and deployment → Source : **GitHub Actions**.
Ensuite `pages.yml` publie `public/` à chaque push sur `master` qui touche le site.
Les pages utilisent des liens relatifs et fonctionnent donc sous `/FLUXA/`.

## À compléter avant d'annoncer le site

- `public/mentions-legales.html` : éditeur, hébergeur, adresse de contact (champs « à compléter »).
- `public/confidentialite.html` : adresse de contact.
- Lien App Store ou TestFlight, quand il existe (blocs `.store` et boutons « Bientôt sur l'App Store »).
- Polices : elles sont chargées depuis Google Fonts. Les héberger avec le site évite de transmettre
  l'adresse IP des visiteurs à Google.

Les débits, latences et consommations affichés sur le site sont des données de démonstration
générées dans `public/assets/site.js`.
