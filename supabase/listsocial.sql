-- Wortlisten: Likes (öffentlich gezählt) und Favoriten (privat). Nur mit Konto.
alter table public.word_lists add column if not exists likes integer not null default 0;
create index if not exists word_lists_likes_idx on public.word_lists (likes desc, created_at desc);
-- Likes/Plays dürfen nur über Funktionen geändert werden: Schreibrechte nur auf die erlaubten Spalten
revoke insert, update, truncate, trigger, references on public.word_lists from anon, authenticated;
grant insert (name, author, words) on public.word_lists to authenticated;
grant update (name, author, words, updated_at) on public.word_lists to authenticated;
create table if not exists public.word_list_marks (
  list_id uuid not null references public.word_lists(id) on delete cascade,
  user_id uuid not null references public.profiles(id) on delete cascade,
  liked boolean not null default false,
  fav boolean not null default false,
  primary key (list_id, user_id)
);
alter table public.word_list_marks enable row level security; -- kein direkter Zugriff, nur über die Funktionen
revoke all on public.word_list_marks from anon, authenticated;

-- eigene Markierungen: {liked:[ids], fav:[ids]}
create or replace function public.my_list_marks() returns json language sql stable security definer set search_path = public as $$
  select json_build_object(
    'liked', coalesce((select json_agg(list_id) from word_list_marks where user_id = public.require_account() and liked), '[]'::json),
    'fav', coalesce((select json_agg(list_id) from word_list_marks where user_id = auth.uid() and fav), '[]'::json));
$$;

-- Like oder Favorit setzen/entfernen; gibt die neue Like-Zahl der Liste zurück
create or replace function public.mark_list(p_list uuid, p_kind text, p_on boolean) returns integer language plpgsql security definer set search_path = public as $$
declare me uuid := public.require_account(); own uuid; n integer;
begin
  if p_kind not in ('like', 'fav') then raise exception 'bad_kind'; end if;
  if not exists (select 1 from profiles where id = me) then raise exception 'no_profile'; end if;
  select owner into own from word_lists where id = p_list;
  if not found then raise exception 'no_list'; end if;
  if p_kind = 'like' and own = me and p_on then raise exception 'own_list'; end if;
  insert into word_list_marks (list_id, user_id, liked, fav)
    values (p_list, me, p_kind = 'like' and p_on, p_kind = 'fav' and p_on)
  on conflict (list_id, user_id) do update set
    liked = case when p_kind = 'like' then p_on else word_list_marks.liked end,
    fav = case when p_kind = 'fav' then p_on else word_list_marks.fav end;
  delete from word_list_marks where list_id = p_list and user_id = me and not liked and not fav;
  select count(*) into n from word_list_marks where list_id = p_list and liked;
  update word_lists set likes = n where id = p_list;
  return n;
end; $$;

revoke all on function public.my_list_marks() from public, anon;
revoke all on function public.mark_list(uuid, text, boolean) from public, anon;
grant execute on function public.my_list_marks() to authenticated;
grant execute on function public.mark_list(uuid, text, boolean) to authenticated;
