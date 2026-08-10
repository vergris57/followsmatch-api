-- Avatars servis par l'API (remplace le bucket Storage Supabase 'avatars').
-- Petites images JPEG compressées côté client -> stockage bytea simple et suffisant.
create table if not exists public.avatars (
  user_id uuid primary key references public.profiles(id) on delete cascade,
  bytes bytea not null,
  content_type text not null default 'image/jpeg',
  updated_at timestamptz not null default now()
);
