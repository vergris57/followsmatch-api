// Authentification (remplace Supabase Auth) : e-mail/mot de passe (bcrypt + JWT)
// et « Continuer avec Google » (OAuth côté serveur). Émet un JWT que le front stocke.
const express = require('express');
const bcrypt = require('bcryptjs');
const jwt = require('jsonwebtoken');
const { pool } = require('./db');

const JWT_SECRET = process.env.JWT_SECRET || null;
if (!JWT_SECRET) {
  console.warn('[auth] ⚠️ JWT_SECRET non défini — secret éphémère (les sessions ne survivront pas à un redémarrage). Définis JWT_SECRET sur Railway.');
}
const SECRET = JWT_SECRET || ('dev-' + Math.random().toString(36).slice(2) + Date.now());
const EXPIRES = '30d';

function sign(user) {
  return jwt.sign({ sub: user.id, email: user.email }, SECRET, { expiresIn: EXPIRES });
}
function sessionPayload(user) {
  const access_token = sign(user);
  return { access_token, token_type: 'bearer', user: { id: user.id, email: user.email } };
}
function verify(token) {
  // Algorithme verrouillé (HS256) : empêche les attaques par substitution d'algorithme.
  try { return jwt.verify(token, SECRET, { algorithms: ['HS256'] }); } catch (_) { return null; }
}

// Middleware : renseigne req.userId si un Bearer valide est présent (sinon null, pas d'erreur).
function authOptional(req, _res, next) {
  const h = req.headers.authorization || '';
  const m = h.match(/^Bearer\s+(.+)$/i);
  if (m) {
    const c = verify(m[1]);
    if (c) { req.userId = c.sub; req.userEmail = c.email; }
  }
  next();
}
function requireAuth(req, res, next) {
  if (!req.userId) return res.status(401).json({ error: { message: 'non authentifié' } });
  next();
}

function apiBase(req) {
  const proto = (req.headers['x-forwarded-proto'] || req.protocol || 'https').split(',')[0];
  return process.env.PUBLIC_URL || `${proto}://${req.get('host')}`;
}

// Sécurité OAuth : n'autorise le retour (« redirect_to ») que vers les domaines de
// confiance de FollowsMatch. Sans ce filtre, un pirate pourrait renvoyer la victime
// vers son propre site AVEC le jeton de session dans l'URL (prise de contrôle du compte).
const REDIRECT_ALLOW = [
  'https://followsmatch.com',
  'https://www.followsmatch.com',
  'https://vergris57.github.io',
];
function safeRedirect(target, req) {
  const fallback = 'https://followsmatch.com/';
  try {
    const allow = REDIRECT_ALLOW.slice();
    try { allow.push(new URL(apiBase(req)).origin); } catch (_) {}
    const u = new URL(String(target));
    if (u.protocol === 'https:' && allow.includes(u.origin)) return u.toString();
  } catch (_) {}
  return fallback;
}

const router = express.Router();

// --- Inscription e-mail (session immédiate, sans e-mail de confirmation) ---
router.post('/signup', async (req, res) => {
  const email = (req.body.email || '').trim().toLowerCase();
  const password = req.body.password || '';
  const displayName = (req.body.data && req.body.data.display_name) || req.body.display_name || '';
  if (!email || !email.includes('@')) return res.status(400).json({ error: { message: 'e-mail invalide' } });
  if (password.length < 8) return res.status(400).json({ error: { message: 'mot de passe : 8 caractères minimum' } });
  try {
    const hash = await bcrypt.hash(password, 10);
    const meta = JSON.stringify({ display_name: displayName });
    const r = await pool.query(
      `insert into auth.users(email, encrypted_password, raw_user_meta_data, email_confirmed_at)
       values ($1,$2,$3::jsonb, now()) returning id, email`,
      [email, hash, meta]
    );
    return res.json(sessionPayload(r.rows[0]));
  } catch (e) {
    if (e.code === '23505') return res.status(400).json({ error: { message: 'already registered' } });
    console.error('[auth/signup]', e.message);
    return res.status(500).json({ error: { message: e.message } });
  }
});

// --- Connexion e-mail ---
router.post('/login', async (req, res) => {
  const email = (req.body.email || '').trim().toLowerCase();
  const password = req.body.password || '';
  try {
    const r = await pool.query('select id, email, encrypted_password from auth.users where email = $1', [email]);
    const u = r.rows[0];
    if (!u || !u.encrypted_password || !(await bcrypt.compare(password, u.encrypted_password))) {
      return res.status(400).json({ error: { message: 'Invalid login credentials' } });
    }
    return res.json(sessionPayload(u));
  } catch (e) {
    console.error('[auth/login]', e.message);
    return res.status(500).json({ error: { message: e.message } });
  }
});

router.post('/logout', (_req, res) => res.json({}));

router.get('/session', authOptional, async (req, res) => {
  if (!req.userId) return res.json({ user: null });
  const r = await pool.query('select id, email from auth.users where id = $1', [req.userId]);
  if (!r.rows[0]) return res.json({ user: null });
  return res.json({ user: r.rows[0] });
});

// --- Mot de passe oublié (stub : e-mail à câbler via un fournisseur SMTP plus tard) ---
router.post('/recover', async (_req, res) => res.json({}));

// --- Changement de mot de passe (utilisateur connecté) ---
router.post('/update-user', authOptional, requireAuth, async (req, res) => {
  const password = req.body.password;
  if (!password || password.length < 8) return res.status(400).json({ error: { message: '8 caractères minimum' } });
  try {
    const hash = await bcrypt.hash(password, 10);
    await pool.query('update auth.users set encrypted_password = $1 where id = $2', [hash, req.userId]);
    return res.json({ user: { id: req.userId, email: req.userEmail } });
  } catch (e) {
    return res.status(500).json({ error: { message: e.message } });
  }
});

// ---------- Google OAuth ----------
router.get('/google/start', (req, res) => {
  const cid = process.env.GOOGLE_CLIENT_ID;
  if (!cid) return res.status(400).send('Google non configuré (GOOGLE_CLIENT_ID manquant).');
  const redirectTo = safeRedirect(req.query.redirect_to || apiBase(req), req);
  const state = Buffer.from(JSON.stringify({ r: redirectTo })).toString('base64url');
  const p = new URLSearchParams({
    client_id: cid,
    redirect_uri: apiBase(req) + '/auth/google/callback',
    response_type: 'code',
    scope: 'openid email profile',
    state,
    access_type: 'online',
    prompt: 'select_account',
  });
  res.redirect('https://accounts.google.com/o/oauth2/v2/auth?' + p.toString());
});

router.get('/google/callback', async (req, res) => {
  const cid = process.env.GOOGLE_CLIENT_ID, secret = process.env.GOOGLE_CLIENT_SECRET;
  let redirectTo = apiBase(req);
  try {
    const st = JSON.parse(Buffer.from(String(req.query.state || ''), 'base64url').toString());
    if (st && st.r) redirectTo = st.r;
  } catch (_) {}
  // Neutralise tout retour hors des domaines FollowsMatch (le jeton ne fuit jamais dehors).
  redirectTo = safeRedirect(redirectTo, req);
  try {
    if (!cid || !secret) throw new Error('Google non configuré (client id/secret).');
    const code = req.query.code;
    if (!code) throw new Error('code manquant');
    const tok = await fetch('https://oauth2.googleapis.com/token', {
      method: 'POST', headers: { 'content-type': 'application/x-www-form-urlencoded' },
      body: new URLSearchParams({
        client_id: cid, client_secret: secret, code,
        redirect_uri: apiBase(req) + '/auth/google/callback', grant_type: 'authorization_code',
      }),
    }).then((r) => r.json());
    if (!tok.access_token) throw new Error('échange de code échoué');
    const info = await fetch('https://openidconnect.googleapis.com/v1/userinfo', {
      headers: { authorization: 'Bearer ' + tok.access_token },
    }).then((r) => r.json());
    if (!info.sub || !info.email) throw new Error('profil Google illisible');
    // Exige un e-mail Google confirmé : empêche de rattacher/créer un compte avec un e-mail non prouvé.
    if (info.email_verified !== true && info.email_verified !== 'true') throw new Error('e-mail Google non vérifié');

    const email = info.email.toLowerCase();
    const name = info.name || info.given_name || '';
    // Rattache par google_sub, sinon par e-mail, sinon crée.
    let u = (await pool.query('select id, email from auth.users where google_sub = $1', [info.sub])).rows[0];
    if (!u) {
      const byEmail = (await pool.query('select id, email from auth.users where email = $1', [email])).rows[0];
      if (byEmail) {
        await pool.query('update auth.users set google_sub = $1 where id = $2', [info.sub, byEmail.id]);
        u = byEmail;
      } else {
        u = (await pool.query(
          `insert into auth.users(email, google_sub, raw_user_meta_data, email_confirmed_at)
           values ($1,$2,$3::jsonb, now()) returning id, email`,
          [email, info.sub, JSON.stringify({ display_name: name })]
        )).rows[0];
      }
    }
    const s = sessionPayload(u);
    const hash = new URLSearchParams({ access_token: s.access_token, token_type: 'bearer' }).toString();
    return res.redirect(redirectTo + '#' + hash);
  } catch (e) {
    console.error('[auth/google]', e.message);
    return res.redirect(redirectTo + '#error=' + encodeURIComponent(e.message));
  }
});

module.exports = { router, authOptional, requireAuth, sign, verify };
