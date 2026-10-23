-- ===================== Online-Status für Freunde =====================
-- Freundescode sieht nur noch man selbst; Freunde sehen stattdessen den Online-Status.
-- Die Seite meldet sich jede Minute (nur angemeldet): last_seen = Seite offen, last_input = letzte Eingabe.
alter table public.profiles add column if not exists last_seen timestamptz;
alter table public.profiles add column if not exists last_input timestamptz;

-- online: Seite offen und Eingabe in den letzten 10 Min · away: Seite offen, aber 10 Min keine Eingabe · offline: sonst
create or replace function public.presence_of(p_seen timestamptz, p_input timestamptz) returns text language sql stable as $$
select case when p_seen is null or p_seen < now() - interval '150 seconds' then 'offline'
when p_input is not null and p_input > now() - interval '10 minutes' then 'online' else 'away' end; $$;

create or replace function public.heartbeat(p_active boolean) returns void language plpgsql security definer set search_path = public as $$
declare me uuid := public.require_account();
begin
update profiles set last_seen = now(), last_input = case when p_active then now() else last_input end where id = me;
end; $$;

drop function if exists public.list_friends();
create function public.list_friends() returns table(id uuid, name text, kind text, since timestamptz, avatar_url text, presence text, last_seen timestamptz) language sql security definer set search_path = public as $$
select p.id, p.name, case when f.status = 'accepted' then 'friend' when f.addressee = public.require_account() then 'incoming' else 'outgoing' end, f.created_at, p.avatar_url,
case when f.status = 'accepted' then public.presence_of(p.last_seen, p.last_input) end, case when f.status = 'accepted' then p.last_seen end
from friendships f join profiles p on p.id = case when f.requester = auth.uid() then f.addressee else f.requester end
where f.requester = public.require_account() or f.addressee = auth.uid() order by f.created_at desc; $$;

create or replace function public.get_profile(p_user uuid default null) returns json language plpgsql security definer set search_path = public as $$ declare me uuid := public.require_account(); target uuid := coalesce(p_user, me); r json; begin if target <> me and not exists (select 1 from friendships where status = 'accepted' and ((requester = me and addressee = target) or (requester = target and addressee = me))) then raise exception 'not_allowed'; end if; select json_build_object('id', p.id, 'name', p.name, 'avatar_url', p.avatar_url, 'friend_code', case when p.id = me then p.friend_code end, 'presence', case when p.id <> me then public.presence_of(p.last_seen, p.last_input) end, 'last_seen', case when p.id <> me then p.last_seen end, 'since', p.created_at, 'is_me', p.id = me, 'stats', (select json_build_object('matches', count(*), 'wins', count(*) filter (where won), 'team_matches', count(*) filter (where mode = 'team'), 'team_wins', count(*) filter (where mode = 'team' and won), 'solo_matches', count(*) filter (where mode = 'solo'), 'solo_wins', count(*) filter (where mode = 'solo' and won), 'photos', coalesce(sum(photos), 0), 'valid_photos', coalesce(sum(valid_photos), 0), 'cells', coalesce(sum(cells), 0), 'lines', coalesce(sum(lines), 0)) from match_results where user_id = p.id), 'ratings', (select coalesce(json_object_agg(mode, json_build_object('elo', elo, 'games', games, 'wins', wins, 'peak', peak)), '{}'::json) from ratings where user_id = p.id), 'recent', (select coalesce(json_agg(x order by x.played_at desc), '[]'::json) from (select played_at, won, mode, size, players, photos, valid_photos, cells, lines from match_results where user_id = p.id order by played_at desc limit 10) x)) into r from profiles p where p.id = target; if r is null then raise exception 'no_profile'; end if; return r; end; $$;

revoke all on function public.presence_of(timestamptz, timestamptz) from public, anon, authenticated;
revoke all on function public.heartbeat(boolean) from public, anon; grant execute on function public.heartbeat(boolean) to authenticated;
revoke all on function public.list_friends() from public, anon; grant execute on function public.list_friends() to authenticated;
revoke all on function public.get_profile(uuid) from public, anon; grant execute on function public.get_profile(uuid) to authenticated;
