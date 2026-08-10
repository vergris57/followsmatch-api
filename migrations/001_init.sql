-- ============================================================
-- FollowsMatch — schéma + logique métier consolidés (ex-Supabase).
-- Généré depuis schema.sql + migrations 02→12, rejoué et testé sur Postgres 16 nu.
-- La couche 000_compat.sql fournit auth.uid()/auth.users/storage/net/cron.
-- ============================================================


-- ======================== schema.sql ========================
-- ============================================================
-- FollowMatch — Schéma complet de la base de données (Supabase)
-- À exécuter tel quel dans : Supabase → SQL Editor → Run
-- Version : 1.0 · 03/08/2026 · Auteur : Claude (session #3)
-- ============================================================

-- ---------- 1. PROFILS (liés aux comptes d'authentification) ----------
create table public.profiles (
  id uuid primary key references auth.users on delete cascade,
  display_name text not null default '',
  bio text not null default '' check (char_length(bio) <= 140),
  language text not null default 'fr',
  niche text check (niche in ('Humour','Gaming','Beauté','Food','Sport','Musique','Mode','Tech','Business','Lifestyle','Art','Voyage')),
  trust_score int not null default 50 check (trust_score between 0 and 100),
  is_admin boolean not null default false,
  daily_likes_used int not null default 0,
  likes_reset_on date not null default current_date,
  status text not null default 'active' check (status in ('active','restricted','banned')),
  created_at timestamptz not null default now(),
  last_active_at timestamptz not null default now()
);

-- Création automatique du profil à l'inscription
create or replace function public.handle_new_user()
returns trigger language plpgsql security definer set search_path = public as $$
begin
  insert into public.profiles (id, display_name)
  values (new.id, coalesce(new.raw_user_meta_data->>'display_name',''));
  return new;
end $$;
create trigger on_auth_user_created
  after insert on auth.users
  for each row execute function public.handle_new_user();

-- ---------- 2. COMPTES SOCIAUX ----------
create table public.social_accounts (
  id uuid primary key default gen_random_uuid(),
  user_id uuid not null references public.profiles on delete cascade,
  platform text not null default 'tiktok' check (platform in ('tiktok','instagram')),
  username text not null,
  follower_count int not null default 0 check (follower_count >= 0),
  verification_status text not null default 'pending' check (verification_status in ('pending','verified','rejected')),
  verification_code text not null default 'FM-' || upper(substr(md5(random()::text), 1, 4)),
  verified_at timestamptz,
  created_at timestamptz not null default now(),
  unique (platform, username)
);
create index on public.social_accounts (user_id);

-- ---------- 3. SWIPES ----------
create table public.swipes (
  id uuid primary key default gen_random_uuid(),
  swiper_id uuid not null references public.profiles on delete cascade,
  target_id uuid not null references public.profiles on delete cascade,
  direction text not null check (direction in ('like','pass')),
  created_at timestamptz not null default now(),
  unique (swiper_id, target_id),
  check (swiper_id <> target_id)
);
create index on public.swipes (target_id, direction);

-- ---------- 4. MATCHS (avec les 4 étapes de validation) ----------
create table public.matches (
  id uuid primary key default gen_random_uuid(),
  user_a uuid not null references public.profiles on delete cascade, -- premier likeur : suit en premier
  user_b uuid not null references public.profiles on delete cascade,
  status text not null default 'pending_a_follow' check (status in
    ('pending_a_follow','pending_b_confirm','pending_b_followback','pending_a_confirm',
     'completed','expired','failed','reported')),
  step1_a_followed_at timestamptz,
  step2_b_confirmed_at timestamptz,
  step3_b_followed_back_at timestamptz,
  step4_a_confirmed_at timestamptz,
  expires_at timestamptz not null default now() + interval '48 hours',
  expired_fault uuid references public.profiles,
  created_at timestamptz not null default now(),
  completed_at timestamptz,
  check (user_a <> user_b)
);
-- Un seul match "vivant" par paire ; on peut re-matcher après une expiration/un échec
create unique index matches_pair_uniq on public.matches (least(user_a,user_b), greatest(user_a,user_b))
  where status not in ('expired','failed');
create index on public.matches (status, expires_at);

-- ---------- 5. HISTORIQUE DU SCORE ----------
create table public.trust_events (
  id uuid primary key default gen_random_uuid(),
  user_id uuid not null references public.profiles on delete cascade,
  match_id uuid references public.matches on delete set null,
  event_type text not null check (event_type in
    ('match_completed','fast_bonus','match_expired_fault','unfollow_confirmed','report_abuse','signup')),
  points_delta int not null,
  created_at timestamptz not null default now()
);
create index on public.trust_events (user_id, created_at desc);

-- ---------- 6. SIGNALEMENTS ----------
create table public.reports (
  id uuid primary key default gen_random_uuid(),
  reporter_id uuid not null references public.profiles,
  reported_id uuid not null references public.profiles,
  match_id uuid references public.matches on delete set null,
  reason text not null check (reason in ('no_follow','unfollowed','fake_account','other')),
  comment text not null default '',
  status text not null default 'open' check (status in ('open','confirmed','rejected')),
  created_at timestamptz not null default now(),
  resolved_at timestamptz
);

-- ---------- 7. CONTRÔLES DE FIDÉLITÉ (7 et 30 jours) ----------
create table public.retention_checks (
  id uuid primary key default gen_random_uuid(),
  match_id uuid not null references public.matches on delete cascade,
  asker_id uuid not null references public.profiles on delete cascade,
  day_mark int not null check (day_mark in (7,30)),
  still_following boolean not null,
  created_at timestamptz not null default now(),
  unique (match_id, asker_id, day_mark)
);

-- ============================================================
-- FONCTIONS MÉTIER (le client n'écrit jamais directement les données sensibles)
-- ============================================================

-- Ajout de points, borné 0–100, avec historique + bannissement automatique
create or replace function public.fn_add_trust(p_user uuid, p_delta int, p_type text, p_match uuid default null)
returns void language plpgsql security definer set search_path = public as $$
begin
  insert into trust_events (user_id, match_id, event_type, points_delta) values (p_user, p_match, p_type, p_delta);
  update profiles set trust_score = greatest(0, least(100, trust_score + p_delta)) where id = p_user;
  if p_type = 'unfollow_confirmed' and
     (select count(*) from trust_events where user_id = p_user and event_type = 'unfollow_confirmed') >= 3 then
    update profiles set status = 'banned' where id = p_user;
  end if;
end $$;

-- Suggestions pour la pile de swipe
create or replace function public.fn_suggestions(p_limit int default 15)
returns table (user_id uuid, display_name text, bio text, niche text, trust_score int,
               username text, follower_count int) language sql security definer set search_path = public as $$
  select p.id, p.display_name, p.bio, p.niche, p.trust_score, sa.username, sa.follower_count
  from profiles p
  join social_accounts sa on sa.user_id = p.id and sa.verification_status = 'verified'
  join profiles me on me.id = auth.uid()
  join social_accounts mysa on mysa.user_id = me.id and mysa.verification_status = 'verified'
  where p.id <> auth.uid()
    and p.status = 'active'
    and p.trust_score >= 30
    and p.language = me.language
    and (p.niche = me.niche or not exists (   -- même niche, sinon élargir si la pile est vide
          select 1 from profiles p2
          join social_accounts s2 on s2.user_id = p2.id and s2.verification_status = 'verified'
          where p2.id <> auth.uid() and p2.status = 'active' and p2.trust_score >= 30
            and p2.language = me.language and p2.niche = me.niche
            and not exists (select 1 from swipes sw where sw.swiper_id = auth.uid() and sw.target_id = p2.id)))
    and sa.follower_count between greatest(0, (mysa.follower_count * 0.3)::int) and greatest(100, (mysa.follower_count * 3)::int)
    and not exists (select 1 from swipes sw where sw.swiper_id = auth.uid() and sw.target_id = p.id)
    and not exists (select 1 from matches m where least(m.user_a,m.user_b) = least(auth.uid(),p.id)
                      and greatest(m.user_a,m.user_b) = greatest(auth.uid(),p.id)
                      and m.status not in ('expired','failed'))
  order by p.trust_score desc, p.last_active_at desc
  limit p_limit;
$$;

-- Swipe (like ou pass) + création de match si like mutuel. Renvoie l'id du match créé, sinon null.
create or replace function public.fn_swipe(p_target uuid, p_direction text)
returns uuid language plpgsql security definer set search_path = public as $$
declare v_match uuid; v_me uuid := auth.uid(); v_used int; v_reset date;
begin
  if p_direction not in ('like','pass') then raise exception 'direction invalide'; end if;
  if (select status from profiles where id = v_me) <> 'active' then raise exception 'compte restreint'; end if;
  if p_direction = 'like' then
    select daily_likes_used, likes_reset_on into v_used, v_reset from profiles where id = v_me for update;
    if v_reset < current_date then v_used := 0; end if;
    if v_used >= 20 then raise exception 'limite quotidienne atteinte'; end if;
    update profiles set daily_likes_used = v_used + 1, likes_reset_on = current_date, last_active_at = now() where id = v_me;
  end if;
  insert into swipes (swiper_id, target_id, direction) values (v_me, p_target, p_direction)
    on conflict (swiper_id, target_id) do nothing;
  if p_direction = 'like' and exists
     (select 1 from swipes where swiper_id = p_target and target_id = v_me and direction = 'like') then
    -- l'autre avait liké en premier → il est A (il suit en premier)
    insert into matches (user_a, user_b) values (p_target, v_me)
      on conflict do nothing
      returning id into v_match;
  end if;
  return v_match;
end $$;

-- Avancement du tunnel de validation (une action à la fois, chacun ne peut jouer que son rôle)
create or replace function public.fn_match_step(p_match uuid, p_action text)
returns void language plpgsql security definer set search_path = public as $$
declare m record; v_me uuid := auth.uid();
begin
  select * into m from matches where id = p_match for update;
  if m is null then raise exception 'match introuvable'; end if;
  if v_me not in (m.user_a, m.user_b) then raise exception 'pas ton match'; end if;

  if p_action = 'a_followed' and v_me = m.user_a and m.status = 'pending_a_follow' then
    update matches set step1_a_followed_at = now(), status = 'pending_b_confirm',
                       expires_at = now() + interval '48 hours' where id = p_match;
  elsif p_action = 'b_confirm' and v_me = m.user_b and m.status = 'pending_b_confirm' then
    update matches set step2_b_confirmed_at = now(), status = 'pending_b_followback',
                       expires_at = now() + interval '48 hours' where id = p_match;
  elsif p_action = 'b_followed_back' and v_me = m.user_b and m.status = 'pending_b_followback' then
    update matches set step3_b_followed_back_at = now(), status = 'pending_a_confirm',
                       expires_at = now() + interval '48 hours' where id = p_match;
  elsif p_action = 'a_confirm' and v_me = m.user_a and m.status = 'pending_a_confirm' then
    update matches set step4_a_confirmed_at = now(), status = 'completed', completed_at = now() where id = p_match;
    perform fn_add_trust(m.user_a, 10, 'match_completed', p_match);
    perform fn_add_trust(m.user_b, 10, 'match_completed', p_match);
    if now() - m.created_at < interval '24 hours' then
      perform fn_add_trust(m.user_a, 2, 'fast_bonus', p_match);
      perform fn_add_trust(m.user_b, 2, 'fast_bonus', p_match);
    end if;
  else
    raise exception 'action % impossible depuis le statut % pour cet utilisateur', p_action, m.status;
  end if;
end $$;

-- Signalement
create or replace function public.fn_report(p_match uuid, p_reason text, p_comment text default '')
returns void language plpgsql security definer set search_path = public as $$
declare m record; v_me uuid := auth.uid(); v_other uuid;
begin
  select * into m from matches where id = p_match;
  if m is null or v_me not in (m.user_a, m.user_b) then raise exception 'pas ton match'; end if;
  v_other := case when v_me = m.user_a then m.user_b else m.user_a end;
  insert into reports (reporter_id, reported_id, match_id, reason, comment) values (v_me, v_other, p_match, p_reason, p_comment);
  if m.status not in ('completed','expired') then update matches set status = 'reported' where id = p_match; end if;
end $$;

-- Réponse au contrôle de fidélité (7/30 jours). "Non" crée automatiquement un signalement.
create or replace function public.fn_retention_answer(p_match uuid, p_day int, p_still boolean)
returns void language plpgsql security definer set search_path = public as $$
declare m record; v_me uuid := auth.uid(); v_other uuid;
begin
  select * into m from matches where id = p_match;
  if m is null or v_me not in (m.user_a, m.user_b) or m.status <> 'completed' then raise exception 'match invalide'; end if;
  v_other := case when v_me = m.user_a then m.user_b else m.user_a end;
  insert into retention_checks (match_id, asker_id, day_mark, still_following) values (p_match, v_me, p_day, p_still)
    on conflict do nothing;
  if not p_still then
    insert into reports (reporter_id, reported_id, match_id, reason, comment)
    values (v_me, v_other, p_match, 'unfollowed', 'Contrôle fidélité J' || p_day);
  end if;
end $$;

-- ---------- Fonctions ADMIN (vérification des comptes, signalements) ----------
create or replace function public.fn_is_admin() returns boolean
language sql security definer set search_path = public as
$$ select coalesce((select is_admin from profiles where id = auth.uid()), false) $$;

create or replace function public.fn_verify_account(p_account uuid, p_approve boolean)
returns void language plpgsql security definer set search_path = public as $$
begin
  if not fn_is_admin() then raise exception 'admin uniquement'; end if;
  update social_accounts
    set verification_status = case when p_approve then 'verified' else 'rejected' end,
        verified_at = case when p_approve then now() else null end
    where id = p_account;
end $$;

create or replace function public.fn_resolve_report(p_report uuid, p_confirm boolean)
returns void language plpgsql security definer set search_path = public as $$
declare r record;
begin
  if not fn_is_admin() then raise exception 'admin uniquement'; end if;
  select * into r from reports where id = p_report for update;
  update reports set status = case when p_confirm then 'confirmed' else 'rejected' end, resolved_at = now()
    where id = p_report;
  if p_confirm and r.reason = 'unfollowed' then
    perform fn_add_trust(r.reported_id, -20, 'unfollow_confirmed', r.match_id);
  elsif not p_confirm then
    perform fn_add_trust(r.reporter_id, -5, 'report_abuse', r.match_id);
  end if;
end $$;

-- ---------- Expiration automatique (toutes les heures) ----------
create or replace function public.fn_expire_matches()
returns int language plpgsql security definer set search_path = public as $$
declare m record; v_fault uuid; n int := 0;
begin
  for m in select * from matches
           where status in ('pending_a_follow','pending_b_confirm','pending_b_followback','pending_a_confirm')
             and expires_at < now() for update skip locked loop
    v_fault := case when m.status in ('pending_a_follow','pending_a_confirm') then m.user_a else m.user_b end;
    update matches set status = 'expired', expired_fault = v_fault where id = m.id;
    perform fn_add_trust(v_fault, -10, 'match_expired_fault', m.id);
    n := n + 1;
  end loop;
  return n;
end $$;

select cron.schedule('followmatch-expire', '15 * * * *', $$select public.fn_expire_matches()$$);

-- ============================================================
-- SÉCURITÉ (Row Level Security)
-- ============================================================
alter table public.profiles         enable row level security;
alter table public.social_accounts  enable row level security;
alter table public.swipes           enable row level security;
alter table public.matches          enable row level security;
alter table public.trust_events     enable row level security;
alter table public.reports          enable row level security;
alter table public.retention_checks enable row level security;

-- profils : lisibles par les connectés ; modifiables par soi (champs sûrs uniquement, via droits de colonnes)
create policy profiles_read  on public.profiles for select to authenticated using (true);
create policy profiles_update on public.profiles for update to authenticated using (id = auth.uid());
revoke update on public.profiles from authenticated;
grant  update (display_name, bio, niche, language, last_active_at) on public.profiles to authenticated;

-- comptes sociaux : je crée le mien ; je vois le mien + ceux vérifiés des autres ; je ne mets à jour que mon nombre d'abonnés
create policy sa_insert on public.social_accounts for insert to authenticated with check (user_id = auth.uid());
create policy sa_read   on public.social_accounts for select to authenticated
  using (user_id = auth.uid() or verification_status = 'verified' or fn_is_admin());
create policy sa_update on public.social_accounts for update to authenticated using (user_id = auth.uid());
revoke update on public.social_accounts from authenticated;
grant  update (follower_count) on public.social_accounts to authenticated;

-- swipes / matchs / événements / signalements / contrôles : lecture limitée, écriture uniquement via les fonctions
create policy swipes_read on public.swipes for select to authenticated using (swiper_id = auth.uid());
create policy matches_read on public.matches for select to authenticated using (auth.uid() in (user_a, user_b));
create policy events_read on public.trust_events for select to authenticated using (user_id = auth.uid());
create policy reports_read on public.reports for select to authenticated
  using (reporter_id = auth.uid() or fn_is_admin());
create policy retention_read on public.retention_checks for select to authenticated using (asker_id = auth.uid());

-- ============================================================
-- FIN — Après exécution :
-- 1. Authentication → Providers : activer Email (confirmations activées).
-- 2. Pour te donner les droits admin :
--    update profiles set is_admin = true where id = (select id from auth.users where email = 'TON_EMAIL');
-- ============================================================

-- ======================== migration-02-reseaux.sql ========================
-- ============================================================
-- FollowMatch — Migration 02 : ajout des réseaux Instagram, Snapchat, X
-- À exécuter dans Supabase → SQL Editor → Run
-- ============================================================

-- 1. Autoriser les nouveaux réseaux sur les comptes sociaux
alter table public.social_accounts drop constraint if exists social_accounts_platform_check;
alter table public.social_accounts add constraint social_accounts_platform_check
  check (platform in ('tiktok','instagram','snapchat','x'));

-- 2. Suggestions : renvoyer la plateforme + ne mettre en relation qu'au sein du MÊME réseau
--    (on ne peut pas faire un follow mutuel entre TikTok et Instagram)
drop function if exists public.fn_suggestions(integer);
create function public.fn_suggestions(p_limit int default 15)
returns table (user_id uuid, display_name text, bio text, niche text, trust_score int,
               username text, follower_count int, platform text)
language sql security definer set search_path = public as $$
  select p.id, p.display_name, p.bio, p.niche, p.trust_score, sa.username, sa.follower_count, sa.platform
  from profiles p
  join social_accounts sa on sa.user_id = p.id and sa.verification_status = 'verified'
  join profiles me on me.id = auth.uid()
  join social_accounts mysa on mysa.user_id = me.id and mysa.verification_status = 'verified'
  where p.id <> auth.uid()
    and p.status = 'active'
    and p.trust_score >= 30
    and p.language = me.language
    and sa.platform = mysa.platform                         -- même réseau uniquement
    and (p.niche = me.niche or not exists (                 -- même niche, sinon élargir si la pile est vide
          select 1 from profiles p2
          join social_accounts s2 on s2.user_id = p2.id and s2.verification_status = 'verified' and s2.platform = mysa.platform
          where p2.id <> auth.uid() and p2.status = 'active' and p2.trust_score >= 30
            and p2.language = me.language and p2.niche = me.niche
            and not exists (select 1 from swipes sw where sw.swiper_id = auth.uid() and sw.target_id = p2.id)))
    and sa.follower_count between greatest(0, (mysa.follower_count * 0.3)::int) and greatest(100, (mysa.follower_count * 3)::int)
    and not exists (select 1 from swipes sw where sw.swiper_id = auth.uid() and sw.target_id = p.id)
    and not exists (select 1 from matches m where least(m.user_a,m.user_b) = least(auth.uid(),p.id)
                      and greatest(m.user_a,m.user_b) = greatest(auth.uid(),p.id)
                      and m.status not in ('expired','failed'))
  order by p.trust_score desc, p.last_active_at desc
  limit p_limit;
$$;

-- Vérification
select 'Migration 02 OK — réseaux : tiktok, instagram, snapchat, x' as resultat;

-- ======================== migration-03-multireseaux.sql ========================
-- ============================================================
-- FollowMatch — Migration 03 : matching multi-réseaux (intersection)
-- Un utilisateur déclare plusieurs réseaux ; deux personnes matchent
-- dès qu'elles ont AU MOINS un réseau vérifié en commun.
-- À exécuter dans Supabase → SQL Editor → Run
-- ============================================================

drop function if exists public.fn_suggestions(integer);
create function public.fn_suggestions(p_limit int default 15)
returns table (user_id uuid, display_name text, bio text, niche text, trust_score int,
               accounts jsonb, shared text[])
language sql security definer set search_path = public as $$
  with me as (select id, niche, language from profiles where id = auth.uid()),
       my_nets as (select coalesce(array_agg(distinct platform), '{}') as nets
                   from social_accounts where user_id = auth.uid() and verification_status = 'verified')
  select p.id, p.display_name, p.bio, p.niche, p.trust_score,
    (select jsonb_agg(jsonb_build_object('platform',sa.platform,'username',sa.username,'follower_count',sa.follower_count))
       from social_accounts sa where sa.user_id = p.id and sa.verification_status = 'verified') as accounts,
    (select array_agg(distinct sa.platform)
       from social_accounts sa
       where sa.user_id = p.id and sa.verification_status = 'verified'
         and sa.platform = any(mn.nets)) as shared
  from profiles p, me, my_nets mn
  where p.id <> auth.uid()
    and p.status = 'active'
    and p.trust_score >= 30
    and p.language = me.language
    and p.niche = me.niche
    and exists (select 1 from social_accounts sa                       -- au moins un réseau en commun
                where sa.user_id = p.id and sa.verification_status = 'verified'
                  and sa.platform = any(mn.nets))
    and not exists (select 1 from swipes sw where sw.swiper_id = auth.uid() and sw.target_id = p.id)
    and not exists (select 1 from matches m where least(m.user_a,m.user_b) = least(auth.uid(),p.id)
                      and greatest(m.user_a,m.user_b) = greatest(auth.uid(),p.id)
                      and m.status not in ('expired','failed'))
  order by p.trust_score desc, p.last_active_at desc
  limit p_limit;
$$;

select 'Migration 03 OK — matching par réseaux en commun (intersection)' as resultat;

-- ======================== migration-04-echange-croise.sql ========================
-- ============================================================
-- FollowMatch — Migration 04 : échange croisé (chacun grandit sur SON réseau-objectif)
-- Modèle : chaque membre choisit UN réseau-objectif. A suit B sur l'objectif de B,
-- B suit A sur l'objectif de A. Match possible si je suis présent sur son objectif
-- ET s'il est présent sur le mien. Aucun filtre niche / taille / langue.
-- À exécuter dans Supabase → SQL Editor → Run
-- ============================================================

-- 1. Réseau-objectif sur le profil (un seul à la fois, modifiable)
alter table public.profiles add column if not exists target_platform text
  check (target_platform in ('tiktok','instagram','snapchat','x'));

-- 2. Mémoriser l'objectif de chacun au moment du match (stable même si on change d'objectif après)
alter table public.matches add column if not exists user_a_target text;
alter table public.matches add column if not exists user_b_target text;

-- 3. Choisir / changer son objectif (doit être un réseau qu'on a vérifié)
create or replace function public.fn_set_target(p_platform text)
returns void language plpgsql security definer set search_path = public as $$
begin
  if p_platform not in ('tiktok','instagram','snapchat','x') then
    raise exception 'réseau invalide';
  end if;
  if not exists (select 1 from social_accounts
                 where user_id = auth.uid() and platform = p_platform and verification_status = 'verified') then
    raise exception 'vérifie d''abord ton compte % pour en faire ton objectif', p_platform;
  end if;
  update profiles set target_platform = p_platform where id = auth.uid();
end $$;

-- 4. Suggestions = règle croisée
--    (a) je suis présent sur SON objectif  -> je pourrai le suivre là
--    (b) il est présent sur MON objectif   -> il pourra me suivre là
drop function if exists public.fn_suggestions(integer);
create function public.fn_suggestions(p_limit int default 15)
returns table (user_id uuid, display_name text, bio text, niche text, trust_score int,
               target_platform text, target_username text)
language sql security definer set search_path = public as $$
  with me as (select target_platform as my_target from profiles where id = auth.uid()),
       my_nets as (select coalesce(array_agg(distinct platform), '{}') as nets
                   from social_accounts where user_id = auth.uid() and verification_status = 'verified')
  select p.id, p.display_name, p.bio, p.niche, p.trust_score,
         p.target_platform,
         (select sa.username from social_accounts sa
            where sa.user_id = p.id and sa.platform = p.target_platform and sa.verification_status = 'verified'
            limit 1) as target_username
  from profiles p, me, my_nets mn
  where p.id <> auth.uid()
    and me.my_target is not null
    and p.status = 'active'
    and p.trust_score >= 30
    and p.target_platform is not null
    and p.target_platform = any(mn.nets)                       -- (a) je suis présent sur son objectif
    and exists (select 1 from social_accounts sa               -- (b) il est présent sur mon objectif
                where sa.user_id = p.id and sa.verification_status = 'verified'
                  and sa.platform = me.my_target)
    and not exists (select 1 from swipes sw where sw.swiper_id = auth.uid() and sw.target_id = p.id)
    and not exists (select 1 from matches m where least(m.user_a,m.user_b) = least(auth.uid(),p.id)
                      and greatest(m.user_a,m.user_b) = greatest(auth.uid(),p.id)
                      and m.status not in ('expired','failed'))
  order by p.trust_score desc, p.last_active_at desc
  limit p_limit;
$$;

-- 5. Swipe : au match, on fige l'objectif de chacun (A suit en premier, sur l'objectif de B)
create or replace function public.fn_swipe(p_target uuid, p_direction text)
returns uuid language plpgsql security definer set search_path = public as $$
declare v_match uuid; v_me uuid := auth.uid(); v_used int; v_reset date;
begin
  if p_direction not in ('like','pass') then raise exception 'direction invalide'; end if;
  if (select status from profiles where id = v_me) <> 'active' then raise exception 'compte restreint'; end if;
  if p_direction = 'like' then
    select daily_likes_used, likes_reset_on into v_used, v_reset from profiles where id = v_me for update;
    if v_reset < current_date then v_used := 0; end if;
    if v_used >= 20 then raise exception 'limite quotidienne atteinte'; end if;
    update profiles set daily_likes_used = v_used + 1, likes_reset_on = current_date, last_active_at = now() where id = v_me;
  end if;
  insert into swipes (swiper_id, target_id, direction) values (v_me, p_target, p_direction)
    on conflict (swiper_id, target_id) do nothing;
  if p_direction = 'like' and exists
     (select 1 from swipes where swiper_id = p_target and target_id = v_me and direction = 'like') then
    -- l'autre avait liké en premier -> il est A (il suit en premier, sur l'objectif de B = moi)
    insert into matches (user_a, user_b, user_a_target, user_b_target)
      values (p_target, v_me,
              (select target_platform from profiles where id = p_target),
              (select target_platform from profiles where id = v_me))
      on conflict do nothing
      returning id into v_match;
  end if;
  return v_match;
end $$;

select 'Migration 04 OK — échange croisé (objectif par personne, suivi croisé)' as resultat;

-- ======================== migration-05a-notifications.sql ========================
-- ============================================================
-- FollowMatch — Migration 05a : notifications push (base + déclencheurs)
-- Abonnements push + fonction d'envoi (appelle l'Edge Function send-push)
-- + notifications sur : nouveau match, à toi d'agir. (Rappel 48h : voir 05b.)
-- ============================================================


-- 1. Abonnements push (un appareil = une ligne)
create table if not exists public.push_subscriptions (
  id uuid primary key default gen_random_uuid(),
  user_id uuid not null references public.profiles on delete cascade,
  endpoint text not null unique,
  p256dh text not null,
  auth text not null,
  created_at timestamptz not null default now()
);
create index if not exists push_subscriptions_user on public.push_subscriptions(user_id);
alter table public.push_subscriptions enable row level security;
drop policy if exists ps_all on public.push_subscriptions;
create policy ps_all on public.push_subscriptions for all to authenticated
  using (user_id = auth.uid()) with check (user_id = auth.uid());

-- 2. Pour ne rappeler qu'une fois avant l'expiration
alter table public.matches add column if not exists reminder_sent_at timestamptz;

-- 3. Envoi d'une notif : appelle l'Edge Function (jamais bloquant pour l'action métier)
create or replace function public.fn_notify(p_user uuid, p_title text, p_body text, p_url text default '/', p_tag text default null)
returns void language plpgsql security definer set search_path = public as $$
begin
  perform net.http_post(
    url := 'https://ehoaqwounccjwszfvnef.supabase.co/functions/v1/send-push',
    headers := jsonb_build_object('Content-Type','application/json','x-fm-key','35d1a55a2e278c66e3d0d9c4d7622c4f7d17405bff11c2d5'),
    body := jsonb_build_object('user_id',p_user,'title',p_title,'body',p_body,'url',p_url,'tag',p_tag)
  );
exception when others then null;
end $$;

-- 4. Swipe : au match, on prévient les deux personnes
create or replace function public.fn_swipe(p_target uuid, p_direction text)
returns uuid language plpgsql security definer set search_path = public as $$
declare v_match uuid; v_me uuid := auth.uid(); v_used int; v_reset date;
begin
  if p_direction not in ('like','pass') then raise exception 'direction invalide'; end if;
  if (select status from profiles where id = v_me) <> 'active' then raise exception 'compte restreint'; end if;
  if p_direction = 'like' then
    select daily_likes_used, likes_reset_on into v_used, v_reset from profiles where id = v_me for update;
    if v_reset < current_date then v_used := 0; end if;
    if v_used >= 20 then raise exception 'limite quotidienne atteinte'; end if;
    update profiles set daily_likes_used = v_used + 1, likes_reset_on = current_date, last_active_at = now() where id = v_me;
  end if;
  insert into swipes (swiper_id, target_id, direction) values (v_me, p_target, p_direction)
    on conflict (swiper_id, target_id) do nothing;
  if p_direction = 'like' and exists
     (select 1 from swipes where swiper_id = p_target and target_id = v_me and direction = 'like') then
    insert into matches (user_a, user_b, user_a_target, user_b_target)
      values (p_target, v_me,
              (select target_platform from profiles where id = p_target),
              (select target_platform from profiles where id = v_me))
      on conflict do nothing
      returning id into v_match;
  end if;
  if v_match is not null then
    perform fn_notify(p_target, 'C''est un match ! 🎉',
       coalesce((select display_name from profiles where id = v_me),'Quelqu''un')||' veut échanger avec toi.', '/', 'match');
    perform fn_notify(v_me, 'C''est un match ! 🎉',
       coalesce((select display_name from profiles where id = p_target),'Quelqu''un')||' veut échanger avec toi.', '/', 'match');
  end if;
  return v_match;
end $$;

-- 5. Tunnel : on prévient la personne dont c'est le tour + on réarme le rappel
create or replace function public.fn_match_step(p_match uuid, p_action text)
returns void language plpgsql security definer set search_path = public as $$
declare m record; v_me uuid := auth.uid();
begin
  select * into m from matches where id = p_match for update;
  if m is null then raise exception 'match introuvable'; end if;
  if v_me not in (m.user_a, m.user_b) then raise exception 'pas ton match'; end if;

  if p_action = 'a_followed' and v_me = m.user_a and m.status = 'pending_a_follow' then
    update matches set step1_a_followed_at = now(), status = 'pending_b_confirm',
                       expires_at = now() + interval '48 hours', reminder_sent_at = null where id = p_match;
    perform fn_notify(m.user_b, '👀 À toi de jouer',
       coalesce((select display_name from profiles where id = m.user_a),'Ton partenaire')||' t''a suivi — confirme le follow reçu.', '/', 'turn_'||p_match::text);
  elsif p_action = 'b_confirm' and v_me = m.user_b and m.status = 'pending_b_confirm' then
    update matches set step2_b_confirmed_at = now(), status = 'pending_b_followback',
                       expires_at = now() + interval '48 hours', reminder_sent_at = null where id = p_match;
  elsif p_action = 'b_followed_back' and v_me = m.user_b and m.status = 'pending_b_followback' then
    update matches set step3_b_followed_back_at = now(), status = 'pending_a_confirm',
                       expires_at = now() + interval '48 hours', reminder_sent_at = null where id = p_match;
    perform fn_notify(m.user_a, '🎯 À toi de confirmer',
       coalesce((select display_name from profiles where id = m.user_b),'Ton partenaire')||' t''a suivi en retour — vérifie et confirme.', '/', 'turn_'||p_match::text);
  elsif p_action = 'a_confirm' and v_me = m.user_a and m.status = 'pending_a_confirm' then
    update matches set step4_a_confirmed_at = now(), status = 'completed', completed_at = now() where id = p_match;
    perform fn_add_trust(m.user_a, 10, 'match_completed', p_match);
    perform fn_add_trust(m.user_b, 10, 'match_completed', p_match);
    if now() - m.created_at < interval '24 hours' then
      perform fn_add_trust(m.user_a, 2, 'fast_bonus', p_match);
      perform fn_add_trust(m.user_b, 2, 'fast_bonus', p_match);
    end if;
    perform fn_notify(m.user_a, 'Match complété 🎉', '+10 points de confiance. Bravo !', '/', 'done_'||p_match::text);
    perform fn_notify(m.user_b, 'Match complété 🎉', '+10 points de confiance. Bravo !', '/', 'done_'||p_match::text);
  else
    raise exception 'action % impossible depuis le statut % pour cet utilisateur', p_action, m.status;
  end if;
end $$;

-- 6. Rappel avant expiration : notifie la personne qui doit encore agir (une seule fois)
create or replace function public.fn_push_reminders()
returns void language plpgsql security definer set search_path = public as $$
declare r record; v_actor uuid; v_hours int;
begin
  for r in select * from matches
    where status in ('pending_a_follow','pending_b_confirm','pending_b_followback','pending_a_confirm')
      and reminder_sent_at is null
      and expires_at between now() and now() + interval '6 hours' loop
    v_actor := case when r.status in ('pending_a_follow','pending_a_confirm') then r.user_a else r.user_b end;
    v_hours := greatest(1, ceil(extract(epoch from (r.expires_at - now()))/3600));
    perform fn_notify(v_actor, '⏳ Il te reste '||v_hours||'h', 'Agis sur ton match avant qu''il n''expire (sinon −10 points).', '/', 'rem_'||r.id::text);
    update matches set reminder_sent_at = now() where id = r.id;
  end loop;
end $$;

select 'Migration 05a OK — notifications (match + à toi d''agir) prêtes' as resultat;

-- ======================== migration-06-fiabilite.sql ========================
-- ============================================================
-- FollowsMatch — Migration 06 : Fiabilité & anti-triche
-- Ajoute : blocage d'un membre, exclusion des bloqués du matching,
-- signalement « il ne me suit plus » en self-service (pénalité provisoire).
-- Le signalement classique (fn_report), les contrôles de fidélité
-- (fn_retention_answer) et la pénalité admin (fn_resolve_report) existent déjà.
-- À exécuter dans Supabase → SQL Editor → Run
-- ============================================================

-- 1. BLOCAGE ------------------------------------------------
create table if not exists public.blocks (
  blocker_id uuid not null references public.profiles on delete cascade,
  blocked_id uuid not null references public.profiles on delete cascade,
  created_at timestamptz not null default now(),
  primary key (blocker_id, blocked_id)
);
create index if not exists blocks_blocked on public.blocks(blocked_id);
alter table public.blocks enable row level security;
drop policy if exists blocks_own on public.blocks;
create policy blocks_own on public.blocks for all to authenticated
  using (blocker_id = auth.uid()) with check (blocker_id = auth.uid());

create or replace function public.fn_block(p_target uuid)
returns void language plpgsql security definer set search_path = public as $$
begin
  if p_target = auth.uid() then raise exception 'impossible de se bloquer soi-même'; end if;
  insert into blocks (blocker_id, blocked_id) values (auth.uid(), p_target)
    on conflict do nothing;
end $$;

create or replace function public.fn_unblock(p_target uuid)
returns void language plpgsql security definer set search_path = public as $$
begin
  delete from blocks where blocker_id = auth.uid() and blocked_id = p_target;
end $$;

-- 2. TYPE D'ÉVÉNEMENT PROVISOIRE ----------------------------
-- 'unfollow_reported' = pénalité self-service (ne compte PAS pour le bannissement auto).
-- Seul 'unfollow_confirmed' (confirmé par l'admin) compte pour le ban (3 = banni).
alter table public.trust_events drop constraint if exists trust_events_event_type_check;
alter table public.trust_events add constraint trust_events_event_type_check
  check (event_type in ('match_completed','fast_bonus','match_expired_fault',
                        'unfollow_confirmed','unfollow_reported','report_abuse','signup'));

-- 3. SIGNALEMENT « IL NE ME SUIT PLUS » (self-service) ------
-- Sur un échange complété : crée un signalement + pénalité provisoire immédiate.
-- L'admin peut ensuite confirmer (−20 de plus + compte pour le ban) ou rejeter.
create or replace function public.fn_report_unfollow(p_match uuid)
returns void language plpgsql security definer set search_path = public as $$
declare m record; v_me uuid := auth.uid(); v_other uuid;
begin
  select * into m from matches where id = p_match;
  if m is null or v_me not in (m.user_a, m.user_b) then raise exception 'pas ton match'; end if;
  if m.status <> 'completed' then raise exception 'seulement sur un échange complété'; end if;
  v_other := case when v_me = m.user_a then m.user_b else m.user_a end;
  if exists (select 1 from reports where reporter_id = v_me and match_id = p_match and reason = 'unfollowed') then
    raise exception 'déjà signalé pour ce match';
  end if;
  insert into reports (reporter_id, reported_id, match_id, reason, comment)
    values (v_me, v_other, p_match, 'unfollowed', 'Désabonnement signalé par le partenaire');
  perform fn_add_trust(v_other, -8, 'unfollow_reported', p_match);
end $$;

-- 4. SUGGESTIONS = règle croisée (migration 04) + EXCLUSION DES BLOCAGES
drop function if exists public.fn_suggestions(integer);
create function public.fn_suggestions(p_limit int default 15)
returns table (user_id uuid, display_name text, bio text, niche text, trust_score int,
               target_platform text, target_username text)
language sql security definer set search_path = public as $$
  with me as (select target_platform as my_target from profiles where id = auth.uid()),
       my_nets as (select coalesce(array_agg(distinct platform), '{}') as nets
                   from social_accounts where user_id = auth.uid() and verification_status = 'verified')
  select p.id, p.display_name, p.bio, p.niche, p.trust_score,
         p.target_platform,
         (select sa.username from social_accounts sa
            where sa.user_id = p.id and sa.platform = p.target_platform and sa.verification_status = 'verified'
            limit 1) as target_username
  from profiles p, me, my_nets mn
  where p.id <> auth.uid()
    and me.my_target is not null
    and p.status = 'active'
    and p.trust_score >= 30
    and p.target_platform is not null
    and p.target_platform = any(mn.nets)                       -- (a) je suis présent sur son objectif
    and exists (select 1 from social_accounts sa               -- (b) il est présent sur mon objectif
                where sa.user_id = p.id and sa.verification_status = 'verified'
                  and sa.platform = me.my_target)
    and not exists (select 1 from swipes sw where sw.swiper_id = auth.uid() and sw.target_id = p.id)
    and not exists (select 1 from matches m where least(m.user_a,m.user_b) = least(auth.uid(),p.id)
                      and greatest(m.user_a,m.user_b) = greatest(auth.uid(),p.id)
                      and m.status not in ('expired','failed'))
    and not exists (select 1 from blocks b where                -- (nouveau) exclure les blocages (2 sens)
                      (b.blocker_id = auth.uid() and b.blocked_id = p.id)
                      or (b.blocker_id = p.id and b.blocked_id = auth.uid()))
  order by p.trust_score desc, p.last_active_at desc
  limit p_limit;
$$;

select 'Migration 06 OK — blocage + signalement désabonnement (fiabilité)' as resultat;

-- ======================== migration-07-parrainage.sql ========================
-- ============================================================
-- FollowsMatch — Migration 07 : Parrainage (croissance)
-- Chaque membre a un code d'invitation. Quand un nouveau membre s'inscrit
-- avec ce code, les DEUX gagnent +5 points de confiance.
-- À exécuter dans Supabase → SQL Editor → Run
-- ============================================================

-- 1. Code de parrainage (auto) + qui m'a parrainé
alter table public.profiles add column if not exists referral_code text unique
  default upper(substr(md5(gen_random_uuid()::text), 1, 7));
alter table public.profiles add column if not exists referred_by uuid references public.profiles;
-- filet de sécurité : donner un code aux profils qui n'en auraient pas
update public.profiles set referral_code = upper(substr(md5(gen_random_uuid()::text), 1, 7))
  where referral_code is null;

-- 2. Autoriser le type d'événement 'referral_bonus' dans l'historique de score
alter table public.trust_events drop constraint if exists trust_events_event_type_check;
alter table public.trust_events add constraint trust_events_event_type_check
  check (event_type in ('match_completed','fast_bonus','match_expired_fault',
                        'unfollow_confirmed','unfollow_reported','report_abuse','signup','referral_bonus'));

-- 3. Appliquer un parrainage (le nouveau membre appelle avec le code du parrain)
--    Idempotent : ne fait rien si déjà parrainé, code inconnu, ou soi-même.
create or replace function public.fn_apply_referral(p_code text)
returns void language plpgsql security definer set search_path = public as $$
declare v_me uuid := auth.uid(); v_sponsor uuid;
begin
  if v_me is null or p_code is null or length(trim(p_code)) = 0 then return; end if;
  if (select referred_by from profiles where id = v_me) is not null then return; end if;
  select id into v_sponsor from profiles where upper(referral_code) = upper(trim(p_code));
  if v_sponsor is null or v_sponsor = v_me then return; end if;
  update profiles set referred_by = v_sponsor where id = v_me and referred_by is null;
  perform fn_add_trust(v_me, 5, 'referral_bonus', null);
  perform fn_add_trust(v_sponsor, 5, 'referral_bonus', null);
end $$;

-- 4. Mes stats de parrainage (mon code, nombre d'invités, points gagnés)
create or replace function public.fn_referral_stats()
returns table (my_code text, invited int, points int)
language sql security definer set search_path = public as $$
  select
    (select referral_code from profiles where id = auth.uid()),
    (select count(*)::int from profiles where referred_by = auth.uid()),
    (select coalesce(sum(points_delta),0)::int from trust_events
       where user_id = auth.uid() and event_type = 'referral_bonus');
$$;

select 'Migration 07 OK — parrainage (code + bonus +5/+5)' as resultat;

-- ======================== migration-08-fidelisation.sql ========================
-- ============================================================
-- FollowsMatch — Migration 08 : Fidélisation — classement hebdomadaire
-- Classement des membres par échanges complétés sur les 7 derniers jours.
-- (Les badges et l'objectif du jour sont calculés côté app, sans base.)
-- À exécuter dans Supabase → SQL Editor → Run
-- ============================================================

create or replace function public.fn_leaderboard(p_limit int default 15)
returns table (display_name text, trust_score int, gains int, target_platform text)
language sql security definer set search_path = public as $$
  select p.display_name, p.trust_score,
    (select count(*)::int from matches m
       where m.status = 'completed'
         and (m.user_a = p.id or m.user_b = p.id)
         and m.completed_at > now() - interval '7 days') as gains,
    p.target_platform
  from profiles p
  where p.status = 'active' and p.display_name <> ''
  order by gains desc, p.trust_score desc, p.last_active_at desc
  limit p_limit;
$$;

select 'Migration 08 OK — classement hebdomadaire' as resultat;

-- ======================== migration-09-equite.sql ========================
-- ============================================================
-- FollowsMatch — Migration 09 : Équité de l'échange (souple)
-- Les créateurs de taille proche de la tienne remontent en premier
-- (échange plus juste), mais tout le monde reste proposé. La taille est
-- déclarée par le membre pour l'instant. Renvoie aussi le nb d'abonnés.
-- À exécuter dans Supabase → SQL Editor → Run
-- ============================================================

drop function if exists public.fn_suggestions(integer);
create function public.fn_suggestions(p_limit int default 15)
returns table (user_id uuid, display_name text, bio text, niche text, trust_score int,
               target_platform text, target_username text, target_follower_count int)
language sql security definer set search_path = public as $$
  with me as (select target_platform as my_target from profiles where id = auth.uid()),
       my_nets as (select coalesce(array_agg(distinct platform), '{}') as nets
                   from social_accounts where user_id = auth.uid() and verification_status = 'verified'),
       my_fol as (select coalesce(max(follower_count), 0) as f
                  from social_accounts
                  where user_id = auth.uid() and verification_status = 'verified'
                    and platform = (select my_target from me))
  select p.id, p.display_name, p.bio, p.niche, p.trust_score,
         p.target_platform, sa.username, sa.follower_count
  from profiles p
  join social_accounts sa
    on sa.user_id = p.id and sa.platform = p.target_platform and sa.verification_status = 'verified'
  cross join me cross join my_nets mn cross join my_fol
  where p.id <> auth.uid()
    and me.my_target is not null
    and p.status = 'active'
    and p.trust_score >= 30
    and p.target_platform is not null
    and p.target_platform = any(mn.nets)                       -- (a) je suis présent sur son objectif
    and exists (select 1 from social_accounts s2                -- (b) il est présent sur mon objectif
                where s2.user_id = p.id and s2.verification_status = 'verified'
                  and s2.platform = me.my_target)
    and not exists (select 1 from swipes sw where sw.swiper_id = auth.uid() and sw.target_id = p.id)
    and not exists (select 1 from matches m where least(m.user_a,m.user_b) = least(auth.uid(),p.id)
                      and greatest(m.user_a,m.user_b) = greatest(auth.uid(),p.id)
                      and m.status not in ('expired','failed'))
    and not exists (select 1 from blocks b where
                      (b.blocker_id = auth.uid() and b.blocked_id = p.id)
                      or (b.blocker_id = p.id and b.blocked_id = auth.uid()))
  order by abs(ln((sa.follower_count + 1)::numeric / (my_fol.f + 1)::numeric)) asc,  -- tailles proches d'abord
           p.trust_score desc, p.last_active_at desc
  limit p_limit;
$$;

select 'Migration 09 OK — équité (tailles proches remontent) + abonnés affichés' as resultat;

-- ======================== migration-10-edition-profil.sql ========================
-- FollowsMatch — Migration 10 : édition du profil par l'utilisateur
-- Contexte : un utilisateur doit pouvoir modifier son profil lui-même.
--   • nom / bio           -> déjà autorisé (update sur profiles)
--   • nombre d'abonnés    -> déjà autorisé (grant update (follower_count) sur social_accounts)
--   • ajouter un réseau   -> déjà autorisé (policy sa_insert)
-- Cette migration ajoute les deux morceaux manquants :
--   1) retirer un de SES réseaux
--   2) changer le pseudo d'un réseau -> repasse en "pending" (re-vérification, anti-triche)

-- 1) Suppression : un utilisateur peut supprimer uniquement ses propres réseaux
drop policy if exists sa_delete on public.social_accounts;
create policy sa_delete on public.social_accounts
  for delete using (user_id = auth.uid());

-- 2) Changement de pseudo (via fonction, car l'update direct de "username" est volontairement bloqué)
--    -> repasse le compte en "pending" pour re-vérification par l'admin.
create or replace function public.fn_set_username(p_account uuid, p_username text)
returns void
language plpgsql
security definer
set search_path = public
as $$
declare
  v_owner    uuid;
  v_platform text;
  v_clean    text;
begin
  select user_id, platform into v_owner, v_platform
  from public.social_accounts
  where id = p_account;

  if v_owner is null then
    raise exception 'Compte introuvable';
  end if;
  if v_owner <> auth.uid() then
    raise exception 'Non autorisé';
  end if;

  -- nettoyage : enlève les @ en début et tous les espaces
  v_clean := regexp_replace(btrim(p_username), '^@+', '');
  v_clean := regexp_replace(v_clean, '\s+', '', 'g');
  if v_clean = '' then
    raise exception 'Pseudo vide';
  end if;

  -- unicité (même réseau, même pseudo), hors ce compte
  if exists (
    select 1 from public.social_accounts
    where platform = v_platform
      and lower(username) = lower(v_clean)
      and id <> p_account
  ) then
    raise exception 'Ce pseudo est déjà utilisé sur ce réseau';
  end if;

  update public.social_accounts
  set username = v_clean,
      verification_status = 'pending'
  where id = p_account;
end;
$$;

revoke all on function public.fn_set_username(uuid, text) from public;
grant execute on function public.fn_set_username(uuid, text) to authenticated;

-- ======================== migration-11-photo-profil.sql ========================
-- FollowsMatch — Migration 11 : photo de profil
-- Ajoute la possibilité pour chaque membre d'avoir une vraie photo de profil.
--   1) colonne avatar_url sur profiles
--   2) bucket de stockage "avatars" (lecture publique)
--   3) policies : chacun gère uniquement SES fichiers (dossier = son user_id)
--   4) fn_suggestions renvoie aussi avatar_url (photos sur les cartes de swipe)

-- 1) colonne
alter table public.profiles add column if not exists avatar_url text;

-- 2) bucket public "avatars"
insert into storage.buckets (id, name, public)
values ('avatars', 'avatars', true)
on conflict (id) do nothing;

-- 3) policies de stockage (chemin des fichiers = "<user_id>/avatar.jpg")
drop policy if exists "avatars_read"   on storage.objects;
drop policy if exists "avatars_insert" on storage.objects;
drop policy if exists "avatars_update" on storage.objects;
drop policy if exists "avatars_delete" on storage.objects;

create policy "avatars_read" on storage.objects
  for select using (bucket_id = 'avatars');

create policy "avatars_insert" on storage.objects
  for insert to authenticated
  with check (bucket_id = 'avatars' and (storage.foldername(name))[1] = auth.uid()::text);

create policy "avatars_update" on storage.objects
  for update to authenticated
  using (bucket_id = 'avatars' and (storage.foldername(name))[1] = auth.uid()::text);

create policy "avatars_delete" on storage.objects
  for delete to authenticated
  using (bucket_id = 'avatars' and (storage.foldername(name))[1] = auth.uid()::text);

-- 4) fn_suggestions : identique à la migration 09 + colonne avatar_url (photos des autres sur les cartes)
drop function if exists public.fn_suggestions(integer);
create function public.fn_suggestions(p_limit int default 15)
returns table (user_id uuid, display_name text, bio text, niche text, trust_score int,
               target_platform text, target_username text, target_follower_count int, avatar_url text)
language sql security definer set search_path = public as $$
  with me as (select target_platform as my_target from profiles where id = auth.uid()),
       my_nets as (select coalesce(array_agg(distinct platform), '{}') as nets
                   from social_accounts where user_id = auth.uid() and verification_status = 'verified'),
       my_fol as (select coalesce(max(follower_count), 0) as f
                  from social_accounts
                  where user_id = auth.uid() and verification_status = 'verified'
                    and platform = (select my_target from me))
  select p.id, p.display_name, p.bio, p.niche, p.trust_score,
         p.target_platform, sa.username, sa.follower_count, p.avatar_url
  from profiles p
  join social_accounts sa
    on sa.user_id = p.id and sa.platform = p.target_platform and sa.verification_status = 'verified'
  cross join me cross join my_nets mn cross join my_fol
  where p.id <> auth.uid()
    and me.my_target is not null
    and p.status = 'active'
    and p.trust_score >= 30
    and p.target_platform is not null
    and p.target_platform = any(mn.nets)
    and exists (select 1 from social_accounts s2
                where s2.user_id = p.id and s2.verification_status = 'verified'
                  and s2.platform = me.my_target)
    and not exists (select 1 from swipes sw where sw.swiper_id = auth.uid() and sw.target_id = p.id)
    and not exists (select 1 from matches m where least(m.user_a,m.user_b) = least(auth.uid(),p.id)
                      and greatest(m.user_a,m.user_b) = greatest(auth.uid(),p.id)
                      and m.status not in ('expired','failed'))
    and not exists (select 1 from blocks b where
                      (b.blocker_id = auth.uid() and b.blocked_id = p.id)
                      or (b.blocker_id = p.id and b.blocked_id = auth.uid()))
  order by abs(ln((sa.follower_count + 1)::numeric / (my_fol.f + 1)::numeric)) asc,
           p.trust_score desc, p.last_active_at desc
  limit p_limit;
$$;

select 'Migration 11 OK — photo de profil (bucket avatars + avatar_url + fn_suggestions)' as resultat;

-- ======================== migration-12-fix-avatar-grant.sql ========================
-- FollowsMatch — Migration 12 : corrige l'upload de la photo de profil
-- Bug (session #19) : la table profiles utilise des droits UPDATE par colonne.
-- La colonne avatar_url (ajoutee en migration 11) n'avait pas recu ce droit :
--   -> l'ecriture de l'URL de la photo echouait avec "permission denied for table profiles" (42501).
--   -> la photo montait bien dans le stockage, mais n'etait jamais enregistree sur le profil.
-- Correctif : accorder le droit UPDATE sur cette seule colonne au role authenticated.

grant update (avatar_url) on public.profiles to authenticated;

select 'Migration 12 OK - grant update(avatar_url) on profiles to authenticated' as resultat;
