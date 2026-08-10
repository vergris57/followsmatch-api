// Photos de profil (remplace le bucket Storage 'avatars').
// Chemin calqué sur Supabase : /avatars/<user_id>/avatar.jpg
//  - PUT    : dépose (upsert) sa propre photo (corps = binaire image)
//  - GET    : sert la photo (public)
//  - DELETE : retire sa propre photo
const express = require('express');
const { pool } = require('./db');
const { authOptional, requireAuth } = require('./auth');

const router = express.Router();

router.put('/:uid/avatar.jpg',
  express.raw({ type: () => true, limit: '6mb' }),
  authOptional, requireAuth,
  async (req, res) => {
    if (req.params.uid !== req.userId) return res.status(403).json({ error: { message: 'interdit' } });
    const buf = req.body;
    if (!buf || !buf.length) return res.status(400).json({ error: { message: 'image vide' } });
    const ct = req.headers['content-type'] && req.headers['content-type'].startsWith('image/')
      ? req.headers['content-type'] : 'image/jpeg';
    try {
      await pool.query(
        `insert into avatars(user_id, bytes, content_type, updated_at)
         values ($1,$2,$3, now())
         on conflict (user_id) do update set bytes = excluded.bytes, content_type = excluded.content_type, updated_at = now()`,
        [req.userId, buf, ct]
      );
      return res.json({ ok: true });
    } catch (e) {
      return res.status(500).json({ error: { message: e.message } });
    }
  }
);

router.get('/:uid/avatar.jpg', async (req, res) => {
  try {
    const r = await pool.query('select bytes, content_type from avatars where user_id = $1', [req.params.uid]);
    if (!r.rows[0]) return res.status(404).end();
    res.set('Content-Type', r.rows[0].content_type || 'image/jpeg');
    res.set('Cache-Control', 'public, max-age=60');
    return res.send(r.rows[0].bytes);
  } catch (e) {
    return res.status(500).end();
  }
});

router.delete('/:uid/avatar.jpg', authOptional, requireAuth, async (req, res) => {
  if (req.params.uid !== req.userId) return res.status(403).json({ error: { message: 'interdit' } });
  try {
    await pool.query('delete from avatars where user_id = $1', [req.userId]);
    return res.json({ ok: true });
  } catch (e) {
    return res.status(500).json({ error: { message: e.message } });
  }
});

module.exports = { router };
