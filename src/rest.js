// Accès aux tables (remplace sb.from('table').select/insert/update/delete/upsert).
// L'autorisation N'EST PLUS assurée par le RLS (l'API se connecte en owner) :
// elle est FORCÉE ici, table par table. Les filtres du client sont additifs,
// jamais une source d'autorisation. Seul l'opérateur "eq" est utilisé par l'app.
const express = require('express');
const { withUser, pool } = require('./db');
const { authOptional, requireAuth } = require('./auth');

const SAFE_PROFILE_COLS = ['id', 'display_name', 'bio', 'niche', 'trust_score', 'target_platform',
  'avatar_url', 'language', 'status', 'created_at', 'last_active_at', 'daily_likes_used',
  'likes_reset_on', 'referral_code', 'referred_by', 'is_admin'];

// Colonnes de filtre autorisées (identifiants jamais interpolés hors de ces listes).
const FILTER_COLS = {
  profiles: ['id'],
  social_accounts: ['user_id', 'verification_status', 'id'],
  trust_events: ['user_id'],
  reports: ['status'],
};
const ident = (t, c) => (FILTER_COLS[t] || []).includes(c);

function eqFilters(table, filters, values, extraStart) {
  // Construit "col = $n" pour les filtres eq valides. values est muté.
  const clauses = [];
  for (const f of filters || []) {
    if (f.op && f.op !== 'eq') continue;
    if (!ident(table, f.col)) continue;
    values.push(f.val);
    clauses.push(`${f.col} = $${values.length}`);
  }
  return clauses;
}

async function isAdmin(client, userId) {
  const r = await client.query('select coalesce(is_admin,false) a from profiles where id = $1', [userId]);
  return !!(r.rows[0] && r.rows[0].a);
}

const router = express.Router();
router.use(authOptional, requireAuth);

// ---------------- SELECT ----------------
router.post('/select', async (req, res) => {
  const { table, filters, order, limit, single, embed } = req.body || {};
  try {
    const data = await withUser(req.userId, async (client) => {
      const values = [];
      let sql;

      if (table === 'profiles') {
        const where = eqFilters('profiles', filters, values);
        if (!where.length) throw new Error('lecture profils : filtre requis');
        sql = `select ${SAFE_PROFILE_COLS.join(',')} from profiles where ${where.join(' and ')}`;

      } else if (table === 'social_accounts') {
        const admin = await isAdmin(client, req.userId);
        values.push(req.userId);
        const base = admin ? 'true' : `(user_id = $1 or verification_status = 'verified')`;
        const extra = eqFilters('social_accounts', filters, values);
        const wantProfiles = embed === 'profiles' || (Array.isArray(embed) && embed.includes('profiles'));
        const cols = 'sa.*' + (wantProfiles ? ", json_build_object('display_name', p.display_name) as profiles" : '');
        const join = wantProfiles ? 'left join profiles p on p.id = sa.user_id' : '';
        const whereParts = [base.replace(/user_id/g, 'sa.user_id').replace(/verification_status/g, 'sa.verification_status')]
          .concat(extra.map((c) => 'sa.' + c));
        sql = `select ${cols} from social_accounts sa ${join} where ${whereParts.join(' and ')} order by sa.created_at asc`;

      } else if (table === 'trust_events') {
        values.push(req.userId);
        sql = `select * from trust_events where user_id = $1 order by created_at desc`;
        if (limit) sql += ` limit ${parseInt(limit, 10)}`;

      } else if (table === 'reports') {
        const admin = await isAdmin(client, req.userId);
        const extra = eqFilters('reports', filters, values);
        const scope = admin ? 'true' : `reporter_id = '${req.userId}'`;
        sql = `select * from reports where ${[scope].concat(extra).join(' and ')} order by created_at asc`;

      } else {
        throw new Error('table non lisible: ' + table);
      }

      const r = await client.query(sql, values);
      return single ? (r.rows[0] || null) : r.rows;
    });
    return res.json({ data });
  } catch (e) {
    return res.status(400).json({ data: single ? null : [], error: { message: e.message, code: e.code || null } });
  }
});

// ---------------- INSERT ----------------
router.post('/insert', async (req, res) => {
  const { table } = req.body || {};
  let rows = req.body.rows;
  if (!Array.isArray(rows)) rows = [rows];
  try {
    const data = await withUser(req.userId, async (client) => {
      if (table === 'social_accounts') {
        const out = [];
        for (const raw of rows) {
          const row = {
            user_id: req.userId,
            platform: raw.platform,
            username: raw.username,
            follower_count: raw.follower_count != null ? raw.follower_count : 0,
          };
          if (raw.verification_status) row.verification_status = raw.verification_status;
          const cols = Object.keys(row);
          const ph = cols.map((_, i) => `$${i + 1}`);
          const r = await client.query(
            `insert into social_accounts(${cols.join(',')}) values (${ph.join(',')}) returning *`,
            cols.map((c) => row[c])
          );
          out.push(r.rows[0]);
        }
        return out;
      }
      throw new Error('table non insérable: ' + table);
    });
    return res.json({ data });
  } catch (e) {
    return res.status(e.code === '23505' ? 409 : 400).json({ data: null, error: { message: e.message, code: e.code || null } });
  }
});

// ---------------- UPDATE ----------------
router.post('/update', async (req, res) => {
  const { table, values: patch, filters } = req.body || {};
  try {
    const data = await withUser(req.userId, async (client) => {
      const values = [];
      let sql;

      if (table === 'profiles') {
        const allowed = ['display_name', 'bio', 'niche', 'language', 'avatar_url', 'last_active_at'];
        const set = [];
        for (const k of Object.keys(patch || {})) {
          if (!allowed.includes(k)) throw new Error('colonne non modifiable: ' + k);
          values.push(patch[k]); set.push(`${k} = $${values.length}`);
        }
        if (!set.length) throw new Error('rien à modifier');
        values.push(req.userId);
        let where = `id = $${values.length}`; // enforcement : uniquement soi
        const idf = (filters || []).find((f) => f.col === 'id'); // honore aussi le filtre client (fidèle au RLS)
        if (idf) { values.push(idf.val); where += ` and id = $${values.length}`; }
        sql = `update profiles set ${set.join(',')} where ${where} returning ${SAFE_PROFILE_COLS.join(',')}`;

      } else if (table === 'social_accounts') {
        const allowed = ['follower_count'];
        const set = [];
        for (const k of Object.keys(patch || {})) {
          if (!allowed.includes(k)) throw new Error('colonne non modifiable: ' + k);
          values.push(patch[k]); set.push(`${k} = $${values.length}`);
        }
        if (!set.length) throw new Error('rien à modifier');
        const idf = (filters || []).find((f) => f.col === 'id');
        if (!idf) throw new Error('id requis');
        values.push(idf.val); const idIx = values.length;
        values.push(req.userId); const meIx = values.length;
        sql = `update social_accounts set ${set.join(',')} where id = $${idIx} and user_id = $${meIx} returning *`;

      } else {
        throw new Error('table non modifiable: ' + table);
      }

      const r = await client.query(sql, values);
      return r.rows;
    });
    return res.json({ data });
  } catch (e) {
    return res.status(400).json({ data: null, error: { message: e.message, code: e.code || null } });
  }
});

// ---------------- DELETE ----------------
router.post('/delete', async (req, res) => {
  const { table, filters } = req.body || {};
  try {
    const data = await withUser(req.userId, async (client) => {
      if (table === 'social_accounts') {
        const idf = (filters || []).find((f) => f.col === 'id');
        if (!idf) throw new Error('id requis');
        const r = await client.query(
          'delete from social_accounts where id = $1 and user_id = $2 returning *',
          [idf.val, req.userId]
        );
        return r.rows;
      }
      throw new Error('table non supprimable: ' + table);
    });
    return res.json({ data });
  } catch (e) {
    return res.status(400).json({ data: null, error: { message: e.message, code: e.code || null } });
  }
});

// ---------------- UPSERT ----------------
router.post('/upsert', async (req, res) => {
  const { table, row, onConflict } = req.body || {};
  try {
    const data = await withUser(req.userId, async (client) => {
      if (table === 'push_subscriptions' && onConflict === 'endpoint') {
        const r = await client.query(
          `insert into push_subscriptions(user_id, endpoint, p256dh, auth)
           values ($1,$2,$3,$4)
           on conflict (endpoint) do update set p256dh = excluded.p256dh, auth = excluded.auth, user_id = excluded.user_id
           returning *`,
          [req.userId, row.endpoint, row.p256dh, row.auth]
        );
        return r.rows;
      }
      throw new Error('table non upsertable: ' + table);
    });
    return res.json({ data });
  } catch (e) {
    return res.status(400).json({ data: null, error: { message: e.message, code: e.code || null } });
  }
});

module.exports = { router };
