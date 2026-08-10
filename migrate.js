// Runner de migrations : joue les .sql de db/migrations/ dans l'ordre, une seule fois chacun.
// S'exécute au démarrage du serveur (donc à chaque déploiement Railway = migrations auto, sans console).
const fs = require('fs');
const path = require('path');

async function runMigrations(pool) {
  await pool.query(
    'create table if not exists _migrations (name text primary key, run_at timestamptz default now())'
  );
  const dir = path.join(__dirname, 'migrations');
  if (!fs.existsSync(dir)) return { ran: [] };
  const files = fs.readdirSync(dir).filter((f) => f.endsWith('.sql')).sort();
  const ran = [];
  for (const f of files) {
    const done = await pool.query('select 1 from _migrations where name = $1', [f]);
    if (done.rowCount) continue;
    const sql = fs.readFileSync(path.join(dir, f), 'utf8');
    console.log('[migrate] running', f);
    const client = await pool.connect();
    try {
      await client.query('begin');
      await client.query(sql);
      await client.query('insert into _migrations(name) values ($1)', [f]);
      await client.query('commit');
      ran.push(f);
    } catch (e) {
      await client.query('rollback');
      throw new Error('Migration ' + f + ' a échoué : ' + e.message);
    } finally {
      client.release();
    }
  }
  console.log('[migrate] à jour (' + ran.length + ' nouvelle(s) migration(s))');
  return { ran };
}

module.exports = { runMigrations };
