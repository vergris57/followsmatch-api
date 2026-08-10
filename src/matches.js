// Endpoint dédié pour les matchs : reproduit EXACTEMENT la forme imbriquée que
// le front attend (embed PostgREST a:/b: + social_accounts). Portée : mes matchs.
// Reproduit aussi le RLS d'origine sur l'embed : d'un autre profil on ne voit que
// les comptes "verified" ; des miens, tous.
const express = require('express');
const { withUser } = require('./db');
const { authOptional, requireAuth } = require('./auth');

const router = express.Router();

const PROFILE_JSON = (alias, uidParam) => `json_build_object(
  'id', ${alias}.id, 'display_name', ${alias}.display_name, 'avatar_url', ${alias}.avatar_url,
  'trust_score', ${alias}.trust_score, 'target_platform', ${alias}.target_platform,
  'social_accounts', coalesce((
     select json_agg(json_build_object('username', s.username, 'platform', s.platform, 'verification_status', s.verification_status) order by s.created_at)
     from social_accounts s
     where s.user_id = ${alias}.id and (s.user_id = ${uidParam} or s.verification_status = 'verified')
  ), '[]'::json))`;

router.get('/', authOptional, requireAuth, async (req, res) => {
  try {
    const data = await withUser(req.userId, async (client) => {
      const sql = `
        select m.id, m.status, m.user_a, m.user_b, m.user_a_target, m.user_b_target,
               m.expires_at, m.created_at, m.completed_at,
               m.step1_a_followed_at, m.step2_b_confirmed_at, m.step3_b_followed_back_at, m.step4_a_confirmed_at,
               m.expired_fault,
               (select ${PROFILE_JSON('pa', '$1')} from profiles pa where pa.id = m.user_a) as a,
               (select ${PROFILE_JSON('pb', '$1')} from profiles pb where pb.id = m.user_b) as b
        from matches m
        where $1 in (m.user_a, m.user_b)
        order by m.created_at desc`;
      const r = await client.query(sql, [req.userId]);
      return r.rows;
    });
    return res.json({ data });
  } catch (e) {
    return res.status(400).json({ data: [], error: { message: e.message, code: e.code || null } });
  }
});

module.exports = { router };
