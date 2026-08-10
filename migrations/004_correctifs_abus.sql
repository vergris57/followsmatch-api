-- ======================== migration-14 : correctifs abus/équité (#5–#8, #14) ========================
-- #5  Contourner un blocage : on revérifie le blocage AU MOMENT de créer le match.
-- #6  Esquiver la pénalité d'expiration : signaler ne "gèle" plus un match en attente.
-- #7  Pénalité "il ne me suit plus" : le −8 provisoire est REMBOURSÉ si l'admin rejette.
-- #8  Match signalé sans issue : plus de gel → plus de blocage à vie ; anciens matchs figés libérés.
-- #14 Classement : la fonction renvoie l'id (le front l'utilise déjà) → surlignage "c'est moi" fiable.

-- Nouveau type d'événement : remboursement d'une pénalité provisoire de désabonnement (#7).
alter table public.trust_events drop constraint if exists trust_events_event_type_check;
alter table public.trust_events add constraint trust_events_event_type_check
  check (event_type in ('match_completed','fast_bonus','match_expired_fault',
                        'unfollow_confirmed','unfollow_reported','report_abuse','signup',
                        'referral_bonus','unfollow_refunded'));

-- #5 — fn_swipe : identique à la version active, + un match n'est PAS créé s'il existe
--      un blocage entre les deux (dans un sens ou l'autre).
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
     (select 1 from swipes where swiper_id = p_target and target_id = v_me and direction = 'like')
     and not exists                                             -- (#5) aucun blocage entre les deux
     (select 1 from blocks b where (b.blocker_id = v_me and b.blocked_id = p_target)
                                or (b.blocker_id = p_target and b.blocked_id = v_me)) then
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

-- #6 — fn_report : on enregistre le signalement mais on ne "gèle" PLUS le match.
--      Un match en attente continue donc son cours et expire normalement (la pénalité
--      de −10 tombe bien sur le fautif). Le signalement reste dans la file admin.
create or replace function public.fn_report(p_match uuid, p_reason text, p_comment text default '')
returns void language plpgsql security definer set search_path = public as $$
declare m record; v_me uuid := auth.uid(); v_other uuid;
begin
  select * into m from matches where id = p_match;
  if m is null or v_me not in (m.user_a, m.user_b) then raise exception 'pas ton match'; end if;
  v_other := case when v_me = m.user_a then m.user_b else m.user_a end;
  insert into reports (reporter_id, reported_id, match_id, reason, comment) values (v_me, v_other, p_match, p_reason, p_comment);
  -- (#6) plus de "update matches set status='reported'" : pas de gel, pas d'esquive de pénalité.
end $$;

-- #7 + #8 — fn_resolve_report : traitement admin d'un signalement.
--   • garde anti double-traitement (un signalement déjà traité ne se re-traite pas) ;
--   • confirmé + "désabonnement" → −20 (comme avant) ;
--   • rejeté → −5 au signaleur (comme avant) ET, si c'était un "désabonnement",
--     REMBOURSEMENT +8 à l'accusé (la pénalité provisoire est annulée). (#7)
create or replace function public.fn_resolve_report(p_report uuid, p_confirm boolean)
returns void language plpgsql security definer set search_path = public as $$
declare r record;
begin
  if not fn_is_admin() then raise exception 'admin uniquement'; end if;
  select * into r from reports where id = p_report for update;
  if r is null then raise exception 'signalement introuvable'; end if;
  if r.status <> 'open' then raise exception 'signalement déjà traité'; end if;
  update reports set status = case when p_confirm then 'confirmed' else 'rejected' end, resolved_at = now()
    where id = p_report;
  if p_confirm and r.reason = 'unfollowed' then
    perform fn_add_trust(r.reported_id, -20, 'unfollow_confirmed', r.match_id);
  elsif not p_confirm then
    perform fn_add_trust(r.reporter_id, -5, 'report_abuse', r.match_id);
    if r.reason = 'unfollowed' then                          -- (#7) rembourse la pénalité provisoire −8
      perform fn_add_trust(r.reported_id, 8, 'unfollow_refunded', r.match_id);
    end if;
  end if;
end $$;

-- #8 — libère les matchs restés figés en "reported" : on les clôt en "expired"
--      (état terminal déjà bien géré par le front : affiché en historique, ré-appariement autorisé).
update public.matches set status = 'expired' where status = 'reported';

-- #14 — fn_leaderboard : identique, + renvoie l'id du profil (le front s'en sert déjà
--       pour surligner "c'est moi" de façon fiable, même en cas de pseudos identiques).
--       On DROP d'abord car on change le type de retour (ajout de la colonne id).
drop function if exists public.fn_leaderboard(integer);
create or replace function public.fn_leaderboard(p_limit int default 15)
returns table (id uuid, display_name text, trust_score int, gains int, target_platform text)
language sql security definer set search_path = public as $$
  select p.id, p.display_name, p.trust_score,
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

select 'Migration 14 OK — correctifs #5 (blocage), #6/#8 (signalement), #7 (remboursement), #14 (classement)' as resultat;
