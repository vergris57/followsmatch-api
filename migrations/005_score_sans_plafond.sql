-- ======================== migration-15 : score de confiance sans plafond ========================
-- Demande : le score de confiance ne doit plus s'arrêter à 100 — il peut monter sans limite.
-- On lève le plafond aux DEUX endroits (sinon la règle de la base refuserait toute valeur > 100).
-- On conserve un plancher à 0 (pas de score négatif : la jauge et l'affichage restent cohérents).

-- 1. La contrainte de la base interdisait > 100 : on la remplace par « >= 0 ».
alter table public.profiles drop constraint if exists profiles_trust_score_check;
alter table public.profiles add constraint profiles_trust_score_check check (trust_score >= 0);

-- 2. fn_add_trust : on retire le plafond « least(100, …) » (le plancher greatest(0, …) reste).
create or replace function public.fn_add_trust(p_user uuid, p_delta int, p_type text, p_match uuid default null)
returns void language plpgsql security definer set search_path = public as $$
begin
  insert into trust_events (user_id, match_id, event_type, points_delta) values (p_user, p_match, p_type, p_delta);
  update profiles set trust_score = greatest(0, trust_score + p_delta) where id = p_user;
  if p_type = 'unfollow_confirmed' and
     (select count(*) from trust_events where user_id = p_user and event_type = 'unfollow_confirmed') >= 3 then
    update profiles set status = 'banned' where id = p_user;
  end if;
end $$;

select 'Migration 15 OK — score de confiance sans plafond (plancher 0 conservé)' as resultat;
