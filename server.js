// FollowsMatch API — serveur Node/Express sur Railway (remplace Supabase).
// Étape 1 (squelette) : connexion Postgres + /health + migrations auto au démarrage.
// Les routes (auth, profils, swipe, matchs, suggestions, classement, photos) s'ajoutent ensuite.
const express = require('express');
const cors = require('cors');
const { Pool } = require('pg');
const { runMigrations } = require('./migrate');

const app = express();
app.use(express.json({ limit: '6mb' }));

// L'app (front) tourne sur followsmatch.com — on autorise ces origines à appeler l'API.
const ALLOW = [
  'https://followsmatch.com',
  'https://www.followsmatch.com',
  'https://vergris57.github.io',
];
app.use(
  cors({
    origin: (origin, cb) => cb(null, !origin || ALLOW.includes(origin)),
    credentials: true,
  })
);

// Railway injecte DATABASE_URL automatiquement quand un Postgres est lié au service.
const pool = new Pool({
  connectionString: process.env.DATABASE_URL,
  ssl: process.env.PGSSL === 'disable' ? false : { rejectUnauthorized: false },
});
app.locals.pool = pool;

// Santé du service (utile pour vérifier le déploiement + la connexion base).
app.get('/health', async (req, res) => {
  try {
    const r = await pool.query('select now() as t');
    res.json({ ok: true, service: 'followsmatch-api', db_time: r.rows[0].t });
  } catch (e) {
    res.status(500).json({ ok: false, error: e.message });
  }
});

app.get('/', (req, res) => res.json({ ok: true, name: 'FollowsMatch API', version: '0.1.0' }));

const PORT = process.env.PORT || 3000;
runMigrations(pool)
  .then(() => {
    app.listen(PORT, () => console.log('FollowsMatch API en écoute sur :' + PORT));
  })
  .catch((e) => {
    console.error('Démarrage impossible (migrations) :', e.message);
    process.exit(1);
  });
