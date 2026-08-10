# FollowsMatch API — backend Railway (remplace Supabase)

Objectif : sortir de Supabase et gérer toute la partie serveur **par simple commit GitHub** (Railway déploie automatiquement à chaque push, et les migrations de base tournent au démarrage). Plus jamais de console SQL à ouvrir à la main.

## Architecture cible

- **Front** : inchangé — PWA statique sur GitHub Pages (`followsmatch.com`). On remplace seulement les appels `supabase-js` par des appels `fetch` vers cette API.
- **API** : ce serveur Node/Express, déployé sur **Railway**, branché au dépôt GitHub (auto-deploy).
- **Base** : **Postgres managé Railway** (variable `DATABASE_URL` injectée automatiquement).
- **Auth** : e-mail/mot de passe (bcrypt + JWT) + **Google OAuth** (côté serveur). Remplace Supabase Auth.
- **Photos** : stockage des avatars (à câbler en phase 3 — piste : R2/S3 gratuit, ou table Postgres pour les petites images compressées).

## Ce que Supabase faisait, et où ça part

| Supabase | Nouveau |
|---|---|
| Base Postgres + RLS | Postgres Railway + contrôles d'accès dans l'API |
| Auth (email + Google) | Routes `/auth/*` (bcrypt + JWT + OAuth Google) |
| Storage (bucket avatars) | Stockage objet (phase 3) |
| RPC `fn_suggestions`, `fn_leaderboard`… | Routes API équivalentes |

## Plan par étapes (sans casser l'app en ligne)

0. **Fondation** *(faite)* : serveur + `/health` + runner de migrations auto.
1. **Setup Railway** *(action une fois de Jalal)* : compte Railway, projet, Postgres, brancher ce dépôt, variables secrètes. → le squelette se déploie.
2. **Schéma + auth** : port du schéma Postgres ; inscription/connexion e-mail ; Google OAuth ; migration des quelques comptes existants.
3. **Fonctionnalités** : profils, réseaux, swipe, matchs, suggestions, classement, photos.
4. **Bascule du front** : `app.js` appelle la nouvelle API ; tests bout en bout.
5. **Débranchement de Supabase.**

L'app actuelle (Supabase) **reste en ligne et intacte** jusqu'à la bascule finale.

## Variables d'environnement (Railway)

- `DATABASE_URL` — injectée automatiquement par Railway (Postgres lié).
- `JWT_SECRET` — secret pour signer les jetons de session *(à définir par Jalal)*.
- `GOOGLE_CLIENT_ID` / `GOOGLE_CLIENT_SECRET` — pour « Continuer avec Google » *(secret défini par Jalal)*.
- `PGSSL` — `disable` en local si besoin ; laisser vide sur Railway.

## Démarrage local (référence)

```
npm install
DATABASE_URL=postgres://... npm start
# GET /health -> { ok: true, db_time: ... }
```
