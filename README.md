# FLUXA

Site de présentation de FLUXA, le moniteur de connexion pour iPhone.

Site statique, mobile first, sans étape de build.

## Structure

| Fichier | Rôle |
| --- | --- |
| `index.html` | Page d'accueil |
| `confidentialite.html` | Politique de confidentialité |
| `mentions-legales.html` | Mentions légales et conditions d'utilisation |
| `assets/site.css` | Styles (jetons de couleur et de typographie en tête de fichier) |
| `assets/site.js` | Menu mobile, accordéon du pied de page, démonstrations |
| `assets/favicon.svg` | Icône |

L'en-tête et le pied de page sont dupliqués dans les trois pages. Sur les pages légales, les ancres pointent vers `index.html#…`.

## Aperçu local

```sh
python3 -m http.server 8000
```

Puis ouvrir <http://localhost:8000>.

## À compléter avant la mise en ligne

- `mentions-legales.html` : éditeur, hébergeur, adresse de contact (champs marqués « à compléter »).
- `confidentialite.html` : adresse de contact.
- Lien App Store ou TestFlight, quand il existe (blocs `.store` et boutons « Bientôt sur l'App Store »).
- Polices : elles sont chargées depuis Google Fonts. Les héberger avec le site évite de transmettre l'adresse IP des visiteurs à Google.

Les débits, latences et consommations affichés sur le site sont des données de démonstration générées dans `assets/site.js`.
