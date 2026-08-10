-- ======================== migration-13 : anti-faux-comptes ciblé ========================
-- Objectif : couper le vrai abus (une personne qui crée des faux comptes pour gonfler
-- son parrainage) SANS bloquer les vrais utilisateurs qui partagent une IP
-- (même maison, bureau, école, 4G/CGNAT).
--
-- 4 leviers :
--   1) On mémorise l'IP d'inscription de chaque compte.
--   2) Le bonus de parrainage n'est plus donné à l'inscription : il est DIFFÉRÉ
--      jusqu'au 1er échange réussi du filleul (un faux compte inactif ne rapporte rien).
--   3) Aucun bonus si parrain et filleul se sont inscrits depuis la MÊME IP
--      (anti auto-parrainage).
--   4) Plafond de filleuls crédités par parrain (anti-ferme de points).
-- La limite souple d'inscriptions par IP est gérée côté serveur (auth.js).

-- 1. Nouvelles colonnes : IP d'inscription + drapeau "bonus de parrainage déjà réglé"
alter table public.profiles add column if not exists signup_ip text;
alter table public.profiles add column if not exists referral_credited boolean not null default false;

-- Les filleuls DÉJÀ crédités par l'ancien système (bonus immédiat) ne doivent pas
-- l'être une seconde fois : on les marque comme réglés.
update public.profiles set referral_credited = true where referred_by is not null;

-- 2. Le trigger de création de profil recopie l'IP d'inscription (transmise dans les
--    métadonnées par l'API à l'inscription e-mail comme Google).
create or replace function public.handle_new_user()
returns trigger language plpgsql security definer set search_path = public as $$
begin
  insert into public.profiles (id, display_name, signup_ip)
  values (new.id,
          coalesce(new.raw_user_meta_data->>'display_name',''),
          nullif(new.raw_user_meta_data->>'signup_ip',''));
  return new;
end $$;

-- 3. Appliquer un parrainage = enregistrer UNIQUEMENT le lien (aucun point tout de suite).
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
  -- Volontairement AUCUN point ici : le bonus est différé au 1er échange réussi.
end $$;

-- 4. Créditer le bonus de parrainage. Appelé au 1er échange réussi du filleul.
--    Conditions : pas déjà réglé, a bien un parrain, IP d'inscription différentes,
--    et le parrain sous le plafond. Le filleul reçoit son bonus unique ; le parrain
--    le sien seulement s'il n'a pas dépassé le plafond.
create or replace function public.fn_try_credit_referral(p_user uuid)
returns void language plpgsql security definer set search_path = public as $$
declare v_sponsor uuid; v_my_ip text; v_sp_ip text; v_sponsor_credits int;
        c_cap constant int := 20;   -- max de filleuls crédités par parrain
begin
  -- déjà réglé pour ce filleul ? (empêche tout double crédit)
  if (select referral_credited from profiles where id = p_user) then return; end if;
  select referred_by, signup_ip into v_sponsor, v_my_ip from profiles where id = p_user;
  if v_sponsor is null then return; end if;               -- pas de parrain : rien à faire
  select signup_ip into v_sp_ip from profiles where id = v_sponsor;

  -- On marque le filleul comme réglé dans tous les cas ci-dessous (une seule tentative).
  update profiles set referral_credited = true where id = p_user;

  -- Même IP d'inscription => très probablement un auto-parrainage : aucun point.
  if v_my_ip is not null and v_sp_ip is not null and v_my_ip = v_sp_ip then
    return;
  end if;

  -- Bonus unique du filleul (il a fait un vrai échange).
  perform fn_add_trust(p_user, 5, 'referral_bonus', null);

  -- Bonus du parrain, seulement s'il n'a pas atteint le plafond de filleuls crédités.
  select count(*) into v_sponsor_credits
    from profiles where referred_by = v_sponsor and referral_credited = true;
  if v_sponsor_credits <= c_cap then
    perform fn_add_trust(v_sponsor, 5, 'referral_bonus', null);
  end if;
end $$;

-- 5. fn_match_step : identique à la version active, + déclenchement du crédit de
--    parrainage au moment où l'échange est réellement complété (étape a_confirm).
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
    -- Bonus de parrainage différé : c'est ici qu'un vrai échange débloque le crédit.
    perform fn_try_credit_referral(m.user_a);
    perform fn_try_credit_referral(m.user_b);
  else
    raise exception 'action % impossible depuis le statut % pour cet utilisateur', p_action, m.status;
  end if;
end $$;

select 'Migration 13 OK — parrainage différé + anti même-IP + plafond' as resultat;
