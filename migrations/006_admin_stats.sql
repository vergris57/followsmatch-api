-- ======================== migration-16 : tableau de bord admin ========================
-- fn_admin_stats() : renvoie TOUTES les stats de l'app en un seul objet JSON.
-- Réservé aux admins (fn_is_admin). Que des agrégats + les pseudos du top 10 (rien de nominatif sensible).

create or replace function public.fn_admin_stats()
returns jsonb language plpgsql security definer set search_path = public as $$
declare res jsonb;
begin
  if not fn_is_admin() then raise exception 'admin uniquement'; end if;
  select jsonb_build_object(
    'generated_at', now(),
    'users', jsonb_build_object(
      'total',      (select count(*) from profiles),
      'active',     (select count(*) from profiles where status='active'),
      'restricted', (select count(*) from profiles where status='restricted'),
      'banned',     (select count(*) from profiles where status='banned'),
      'new_today',  (select count(*) from profiles where created_at >= current_date),
      'new_7d',     (select count(*) from profiles where created_at >= now() - interval '7 days'),
      'new_30d',    (select count(*) from profiles where created_at >= now() - interval '30 days'),
      'active_7d',  (select count(*) from profiles where last_active_at >= now() - interval '7 days')
    ),
    'accounts', jsonb_build_object(
      'total',     (select count(*) from social_accounts),
      'verified',  (select count(*) from social_accounts where verification_status='verified'),
      'pending',   (select count(*) from social_accounts where verification_status='pending'),
      'rejected',  (select count(*) from social_accounts where verification_status='rejected'),
      'tiktok',    (select count(*) from social_accounts where platform='tiktok'),
      'instagram', (select count(*) from social_accounts where platform='instagram')
    ),
    'matches', jsonb_build_object(
      'total',           (select count(*) from matches),
      'in_progress',     (select count(*) from matches where status like 'pending%'),
      'completed',       (select count(*) from matches where status='completed'),
      'expired',         (select count(*) from matches where status='expired'),
      'failed',          (select count(*) from matches where status='failed'),
      'reported',        (select count(*) from matches where status='reported'),
      'completed_today', (select count(*) from matches where status='completed' and completed_at >= current_date),
      'completed_7d',    (select count(*) from matches where status='completed' and completed_at >= now() - interval '7 days')
    ),
    'trust', jsonb_build_object(
      'avg',      (select coalesce(round(avg(trust_score))::int, 0) from profiles),
      'max',      (select coalesce(max(trust_score), 0) from profiles),
      'elite',    (select count(*) from profiles where trust_score >= 80),
      'fiable',   (select count(*) from profiles where trust_score >= 60 and trust_score < 80),
      'standard', (select count(*) from profiles where trust_score >= 30 and trust_score < 60),
      'risque',   (select count(*) from profiles where trust_score < 30)
    ),
    'reports', jsonb_build_object(
      'open',      (select count(*) from reports where status='open'),
      'confirmed', (select count(*) from reports where status='confirmed'),
      'rejected',  (select count(*) from reports where status='rejected')
    ),
    'referrals', jsonb_build_object(
      'linked',   (select count(*) from profiles where referred_by is not null),
      'credited', (select count(*) from profiles where referral_credited = true)
    ),
    'targets', jsonb_build_object(
      'tiktok',    (select count(*) from profiles where target_platform = 'tiktok'),
      'instagram', (select count(*) from profiles where target_platform = 'instagram'),
      'none',      (select count(*) from profiles where target_platform is null)
    ),
    -- Inscriptions par jour sur 14 jours (le plus ancien d'abord), avec les jours à 0.
    'signups_14d', (
      select coalesce(jsonb_agg(
        jsonb_build_object(
          'd', to_char(current_date - i, 'YYYY-MM-DD'),
          'n', (select count(*) from profiles where created_at::date = current_date - i)
        ) order by i desc), '[]'::jsonb)
      from generate_series(0, 13) as i
    ),
    -- Top 10 membres (par score, puis activité récente).
    'top_users', (
      select coalesce(jsonb_agg(
        jsonb_build_object('name', display_name, 'score', trust_score, 'exchanges', ex)
        order by trust_score desc, ex desc), '[]'::jsonb)
      from (
        select p.display_name, p.trust_score,
          (select count(*) from matches m
             where m.status = 'completed' and (m.user_a = p.id or m.user_b = p.id))::int as ex
        from profiles p
        where p.status = 'active' and p.display_name <> ''
        order by p.trust_score desc, p.last_active_at desc
        limit 10
      ) t
    )
  ) into res;
  return res;
end $$;

select 'Migration 16 OK — fn_admin_stats (tableau de bord admin)' as resultat;
