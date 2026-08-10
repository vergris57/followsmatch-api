// FollowsMatch API — serveur Node/Express sur Railway (remplace Supabase).
// Auth (e-mail + Google) · accès tables contrôlé · RPC métier en base · photos · planif.
const express = require('express');
const cors = require('cors');
const { pool } = require('./src/db');
const { runMigrations } = require('./migrate');
const authMod = require('./src/auth');
const rpcMod = require('./src/rpc');
const restMod = require('./src/rest');
const matchesMod = require('./src/matches');
const avatarsMod = require('./src/avatars');

const app = express();
app.set('trust proxy', true);

// Origines autorisées (le front est servi sur followsmatch.com / GitHub Pages).
const ALLOW = [
  'https://followsmatch.com',
  'https://www.followsmatch.com',
  'https://vergris57.github.io',
];
app.use(cors({
  origin: (origin, cb) => cb(null, !origin || ALLOW.includes(origin)),
  credentials: true,
}));

// Les avatars (PUT binaire, GET image) sont montés AVANT le parseur JSON global.
app.use('/avatars', avatarsMod.router);

app.use(express.json({ limit: '6mb' }));

app.get('/health', async (_req, res) => {
  try {
    const r = await pool.query('select now() as t');
    res.json({ ok: true, service: 'followsmatch-api', version: '0.2.0', db_time: r.rows[0].t });
  } catch (e) {
    res.status(500).json({ ok: false, error: e.message });
  }
});
app.get('/', (_req, res) => res.json({ ok: true, name: 'FollowsMatch API', version: '0.2.0' }));

app.use('/auth', authMod.router);
app.use('/rpc', rpcMod.router);
app.use('/rest', restMod.router);
app.use('/me/matches', matchesMod.router);

// Planification (remplace pg_cron) : expiration des matchs + relances push.
function startJobs() {
  const run = async (label, sql) => {
    try { await pool.query(sql); } catch (e) { console.error('[job]', label, e.message); }
  };
  // Expiration des matchs en retard : toutes les 15 min (+ une fois au démarrage).
  setTimeout(() => run('expire', 'select fn_expire_matches()'), 20 * 1000);
  setInterval(() => run('expire', 'select fn_expire_matches()'), 15 * 60 * 1000);
  // Relances (rappels) : toutes les heures.
  setInterval(() => run('reminders', 'select fn_push_reminders()'), 60 * 60 * 1000);
}

const PORT = process.env.PORT || 3000;

// Au démarrage sur Railway, le DNS privé de Postgres peut n'être prêt qu'après
// quelques secondes : on réessaie la connexion avant de lancer les migrations.
async function waitForDb(tries = 8) {
  for (let i = 1; i <= tries; i++) {
    try { await pool.query('select 1'); return; }
    catch (e) {
      console.log(`[boot] base pas encore prête (${i}/${tries}) : ${e.message}`);
      await new Promise((r) => setTimeout(r, 2500));
    }
  }
  throw new Error('base injoignable après plusieurs tentatives');
}

(async () => {
  try {
    await waitForDb();
    await runMigrations(pool);
    app.listen(PORT, () => {
      console.log('FollowsMatch API en écoute sur :' + PORT);
      startJobs();
    });
  } catch (e) {
    console.error('Démarrage impossible :', e.message);
    process.exit(1);
  }
})();
