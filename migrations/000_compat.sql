-- ============================================================
-- FollowsMatch — Couche de compatibilité "ex-Supabase" pour Railway/Postgres nu.
-- But : rejouer TEL QUEL le schéma + les migrations écrits pour Supabase,
-- en ne changeant qu'UNE chose de fond : d'où vient l'utilisateur courant.
--   • Supabase : auth.uid() lit un claim JWT.
--   • Ici      : auth.uid() lit la variable de session `app.user_id`,
--                que l'API positionne à chaque requête (SET LOCAL app.user_id = ...).
-- Le reste (auth.users, storage, net, cron) est reproduit à l'identique en surface
-- pour que rien ne casse ; les vrais services (auth mot de passe, upload photo,
-- notifications, expiration) sont assurés par l'API Node / des tâches planifiées.
-- ============================================================

-- ---------- Rôles attendus par les GRANT / policies (dormants : l'API se connecte en owner) ----------
do $$ begin
  if not exists (select 1 from pg_roles where rolname = 'anon') then create role anon nologin; end if;
  if not exists (select 1 from pg_roles where rolname = 'authenticated') then create role authenticated nologin; end if;
  if not exists (select 1 from pg_roles where rolname = 'service_role') then create role service_role nologin; end if;
end $$;

-- ---------- Schéma auth : table des comptes (remplace auth.users de Supabase) ----------
create schema if not exists auth;

create table if not exists auth.users (
  id uuid primary key default gen_random_uuid(),
  email text unique,
  encrypted_password text,               -- hash bcrypt (auth e-mail/mot de passe)
  google_sub text unique,                -- identifiant Google (auth "Continuer avec Google")
  raw_user_meta_data jsonb not null default '{}'::jsonb,
  email_confirmed_at timestamptz,
  created_at timestamptz not null default now()
);

-- Utilisateur courant : lu depuis la variable de session posée par l'API.
create or replace function auth.uid() returns uuid
  language sql stable as $$ select nullif(current_setting('app.user_id', true), '')::uuid $$;

-- Certaines policies ciblent le rôle ; on fournit l'équivalent applicatif.
create or replace function auth.role() returns text
  language sql stable as $$ select coalesce(nullif(current_setting('app.user_role', true), ''), 'anon') $$;

-- ---------- Schéma storage : stubs pour rejouer la migration "photo de profil" ----------
-- (Les avatars sont en réalité servis par l'API : table public.avatars + routes.)
create schema if not exists storage;
create table if not exists storage.buckets (
  id text primary key, name text, public boolean default false
);
create table if not exists storage.objects (
  id uuid primary key default gen_random_uuid(),
  bucket_id text, name text, owner uuid, created_at timestamptz default now()
);
create or replace function storage.foldername(name text) returns text[]
  language sql immutable as $$ select string_to_array(name, '/') $$;

-- ---------- Schéma net : stub pour pg_net (fn_notify appelait une Edge Function) ----------
create schema if not exists net;
create or replace function net.http_post(url text, body jsonb default '{}'::jsonb, params jsonb default '{}'::jsonb, headers jsonb default '{}'::jsonb, timeout_milliseconds int default 5000)
  returns bigint language sql as $$ select 0::bigint $$;  -- no-op : les push sont gérés côté API

-- ---------- Schéma cron : stub pour pg_cron (expiration/relances planifiées côté API Node) ----------
create schema if not exists cron;
create or replace function cron.schedule(job_name text, schedule text, command text)
  returns bigint language sql as $$ select 0::bigint $$;  -- no-op : planification via l'API
