// Connexion Postgres + exécution "au nom d'un utilisateur".
// Le cœur de la bascule ex-Supabase : chaque requête d'un utilisateur connecté
// tourne dans une transaction où l'on pose `app.user_id`. Toutes les fonctions
// métier lisent auth.uid() = current_setting('app.user_id') → logique identique.
const { Pool } = require('pg');

function sslConfig() {
  if (process.env.PGSSL === 'disable') return false;
  const url = process.env.DATABASE_URL || '';
  // Réseau interne Railway et local : pas de SSL. URL publique (proxy) : SSL requis.
  if (!url || url.includes('.railway.internal') || url.includes('localhost') || url.includes('127.0.0.1') || url.startsWith('postgres://claude') || url.includes('/pgtest/')) {
    return false;
  }
  return { rejectUnauthorized: false };
}

const pool = new Pool({
  connectionString: process.env.DATABASE_URL,
  ssl: sslConfig(),
  max: parseInt(process.env.PG_MAX || '8', 10),
});

pool.on('error', (e) => console.error('[pg] erreur pool inattendue:', e.message));

// Exécute fn(client) dans une transaction avec app.user_id positionné (local à la txn).
async function withUser(userId, fn) {
  const client = await pool.connect();
  try {
    await client.query('begin');
    await client.query("select set_config('app.user_id', $1, true)", [userId || '']);
    const res = await fn(client);
    await client.query('commit');
    return res;
  } catch (e) {
    try { await client.query('rollback'); } catch (_) {}
    throw e;
  } finally {
    client.release();
  }
}

module.exports = { pool, withUser, sslConfig };
