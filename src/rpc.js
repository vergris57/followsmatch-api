// Dispatcher RPC (remplace sb.rpc('fn_...', {...})).
// Chaque fonction métier reste en base (PL/pgSQL) ; on l'appelle au nom de l'utilisateur.
const express = require('express');
const { withUser } = require('./db');
const { authOptional, requireAuth } = require('./auth');

// Liste blanche : nom -> nature du retour + paramètres autorisés.
const RPC = {
  fn_suggestions:      { kind: 'set',    params: ['p_limit'] },
  fn_set_target:       { kind: 'void',   params: ['p_platform'] },
  fn_swipe:            { kind: 'scalar', params: ['p_target', 'p_direction'] },
  fn_match_step:       { kind: 'void',   params: ['p_match', 'p_action'] },
  fn_retention_answer: { kind: 'void',   params: ['p_match', 'p_day', 'p_still'] },
  fn_report:           { kind: 'void',   params: ['p_match', 'p_reason', 'p_comment'] },
  fn_report_unfollow:  { kind: 'void',   params: ['p_match'] },
  fn_block:            { kind: 'void',   params: ['p_target'] },
  fn_verify_account:   { kind: 'void',   params: ['p_account', 'p_approve'] },
  fn_resolve_report:   { kind: 'void',   params: ['p_report', 'p_confirm'] },
  fn_referral_stats:   { kind: 'set',    params: [] },
  fn_apply_referral:   { kind: 'void',   params: ['p_code'] },
  fn_leaderboard:      { kind: 'set',    params: ['p_limit'] },
  fn_set_username:     { kind: 'void',   params: ['p_account', 'p_username'] },
};

const router = express.Router();

router.post('/:fn', authOptional, requireAuth, async (req, res) => {
  const name = req.params.fn;
  const spec = RPC[name];
  if (!spec) return res.status(404).json({ error: { message: 'fonction inconnue' } });

  const body = req.body || {};
  const parts = [];
  const values = [];
  for (const p of spec.params) {
    if (body[p] !== undefined) {
      values.push(body[p]);
      parts.push(`${p} => $${values.length}`);
    }
  }
  const call = `${name}(${parts.join(', ')})`;
  const sql = spec.kind === 'set' ? `select * from ${call}` : `select ${call} as v`;

  try {
    const data = await withUser(req.userId, async (client) => {
      const r = await client.query(sql, values);
      if (spec.kind === 'set') return r.rows;
      if (spec.kind === 'scalar') return r.rows[0] ? r.rows[0].v : null;
      return null; // void
    });
    return res.json({ data });
  } catch (e) {
    // Renvoie message + code PG (le front s'appuie parfois dessus, ex : 23505).
    return res.status(400).json({ error: { message: e.message, code: e.code || null } });
  }
});

module.exports = { router, RPC };
