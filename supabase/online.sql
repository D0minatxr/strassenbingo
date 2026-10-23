-- ===================== Profil bearbeiten: Name & Bild =====================
-- avatar_url: eigenes hochgeladenes Bild (öffentliche Supabase-Storage-Adresse) oder fertiger Avatar "p:<Nummer>"
alter table public.profiles add column if not exists avatar_url text;
alter table public.profiles add constraint profiles_avatar_ok check (avatar_url is null or avatar_url ~ '^p:[0-9]{1,2}$' or avatar_url ~ '^https://[a-z0-9]+\.supabase\.co/storage/v1/object/public/avatars/[0-9a-f-]{36}\.jpg(\?v=[0-9]{1,15})?$');
create or replace function public.update_profile(p_name text, p_avatar_url text) returns void language plpgsql security definer set search_path = public as $$
declare me uuid := public.require_account(); n text := btrim(coalesce(p_name, ''));
begin
  if char_length(n) < 2 or char_length(n) > 20 then raise exception 'name_length'; end if;
  if p_avatar_url is not null and p_avatar_url !~ '^p:[0-9]{1,2}$' and p_avatar_url !~ ('/avatars/' || me::text || '\.jpg(\?v=[0-9]{1,15})?$') then raise exception 'bad_avatar'; end if;
  update profiles set name = n, avatar_url = p_avatar_url where id = me;
end; $$;
-- Der selbst gewählte Name wird beim Anmelden nicht mehr überschrieben
create or replace function public.ensure_profile(p_name text) returns table(friend_code text, name text) language plpgsql security definer set search_path = public as $$ #variable_conflict use_column
declare me uuid := public.require_account(); c text; begin if not exists (select 1 from profiles where id = me) then loop c := lpad(floor(random() * 1000000)::int::text, 6, '0'); exit when not exists (select 1 from profiles p where p.friend_code = c); end loop; insert into profiles (id, friend_code, name) values (me, c, left(coalesce(nullif(btrim(p_name), ''), 'Spieler'), 20)); end if; return query select p.friend_code, p.name from profiles p where p.id = me; end; $$;
drop function if exists public.list_friends();
create function public.list_friends() returns table(id uuid, name text, friend_code text, kind text, since timestamptz, avatar_url text) language sql security definer set search_path = public as $$ select p.id, p.name, case when f.status = 'accepted' then p.friend_code else null end, case when f.status = 'accepted' then 'friend' when f.addressee = public.require_account() then 'incoming' else 'outgoing' end, f.created_at, p.avatar_url from friendships f join profiles p on p.id = case when f.requester = auth.uid() then f.addressee else f.requester end where f.requester = public.require_account() or f.addressee = auth.uid() order by f.created_at desc; $$;

-- ===================== Bilder-Speicher: jeder nur seine eigene Datei <user-id>.jpg =====================
insert into storage.buckets (id, name, public, file_size_limit, allowed_mime_types) values ('avatars', 'avatars', true, 300000, array['image/jpeg'])
on conflict (id) do update set public = true, file_size_limit = 300000, allowed_mime_types = array['image/jpeg'];
create policy "avatar lesen eigenes" on storage.objects for select to authenticated using (bucket_id = 'avatars' and name = auth.uid()::text || '.jpg');
create policy "avatar hochladen eigenes" on storage.objects for insert to authenticated with check (bucket_id = 'avatars' and name = auth.uid()::text || '.jpg' and not coalesce((auth.jwt()->>'is_anonymous')::boolean, false));
create policy "avatar ersetzen eigenes" on storage.objects for update to authenticated using (bucket_id = 'avatars' and name = auth.uid()::text || '.jpg') with check (bucket_id = 'avatars' and name = auth.uid()::text || '.jpg');
create policy "avatar loeschen eigenes" on storage.objects for delete to authenticated using (bucket_id = 'avatars' and name = auth.uid()::text || '.jpg');

-- ===================== Online & Ranked =====================
create table public.ratings (user_id uuid not null references public.profiles(id) on delete cascade, mode text not null check (mode in ('solo','2v2','3v3','4v4')), elo integer not null default 0 check (elo >= 0), games integer not null default 0, wins integer not null default 0, peak integer not null default 0, updated_at timestamptz not null default now(), primary key (user_id, mode));
alter table public.ratings enable row level security;
create table public.mm_queue (user_id uuid primary key references public.profiles(id) on delete cascade, mode text not null check (mode in ('casual','solo','2v2','3v3','4v4')), elo integer not null default 0, joined_at timestamptz not null default now(), last_seen timestamptz not null default now(), match_id uuid);
alter table public.mm_queue enable row level security;
create table public.ranked_matches (id uuid primary key default gen_random_uuid(), mode text not null, lobby_code text not null, host_id uuid not null, players jsonb not null, created_at timestamptz not null default now(), status text not null default 'running' check (status in ('running','done','void')), result jsonb, finalized_at timestamptz);
alter table public.ranked_matches enable row level security;
create table public.ranked_reports (match_id uuid not null references public.ranked_matches(id) on delete cascade, reporter uuid not null, result jsonb not null, created_at timestamptz not null default now(), primary key (match_id, reporter));
alter table public.ranked_reports enable row level security;

create or replace function public.mode_need(p_mode text) returns integer language sql immutable as $$ select case p_mode when 'casual' then 8 when 'solo' then 10 when '2v2' then 4 when '3v3' then 6 when '4v4' then 8 end; $$;
create or replace function public.elo_of(p_user uuid, p_mode text) returns integer language sql stable security definer set search_path = public as $$ select coalesce((select elo from ratings where user_id = p_user and mode = p_mode), 0); $$;
create or replace function public.mm_window(p_waited_sec numeric) returns integer language sql immutable as $$ select 100 + floor(p_waited_sec / 60.0 * 100)::int; $$;

-- Bildet ein Match aus der Warteschlange: Elo-Fenster ±100, wächst um 100 pro Minute Wartezeit
create or replace function public.mm_try_form(p_mode text) returns uuid language plpgsql security definer set search_path = public as $$
declare anchor record; need integer := public.mode_need(p_mode); waited numeric; win integer; picked uuid[]; elos integer[]; n integer; mid uuid; code text := ''; plist jsonb := '[]'::jsonb; i integer; t integer;
begin
  perform pg_advisory_xact_lock(hashtext('mm:' || p_mode));
  select * into anchor from mm_queue where mode = p_mode and match_id is null and last_seen > now() - interval '20 seconds' order by joined_at limit 1;
  if anchor is null then return null; end if;
  waited := extract(epoch from now() - anchor.joined_at);
  win := case when p_mode = 'casual' then 100000 else public.mm_window(waited) end;
  select array_agg(user_id order by abs(elo - anchor.elo), joined_at), array_agg(elo order by abs(elo - anchor.elo), joined_at) into picked, elos
    from mm_queue where mode = p_mode and match_id is null and last_seen > now() - interval '20 seconds' and abs(elo - anchor.elo) <= win;
  n := coalesce(array_length(picked, 1), 0);
  if n >= need then picked := picked[1:need]; elos := elos[1:need]; n := need;
  elsif p_mode = 'casual' and waited >= 30 and n >= 3 then null;      -- Online: ab 3 Spielern nach 30 s
  elsif p_mode = 'solo' and waited >= 180 and n >= 4 then null;       -- Solo-Ranked: ab 4 Spielern nach 3 Min
  else return null; end if;
  if p_mode in ('2v2','3v3','4v4') then
    select array_agg(u order by e desc), array_agg(e order by e desc) into picked, elos from unnest(picked, elos) as x(u, e);
    for i in 1..n loop t := case when ((i - 1) % 4) in (0, 3) then 0 else 1 end; plist := plist || jsonb_build_object('uid', picked[i], 'team', t, 'elo', elos[i]); end loop;
  else
    for i in 1..n loop plist := plist || jsonb_build_object('uid', picked[i], 'team', null, 'elo', elos[i]); end loop;
  end if;
  for i in 1..5 loop code := code || substr('ABCDEFGHJKLMNPQRSTUVWXYZ23456789', 1 + floor(random() * 32)::int, 1); end loop;
  insert into ranked_matches (mode, lobby_code, host_id, players) values (p_mode, code, picked[1], plist) returning id into mid;
  update mm_queue set match_id = mid where user_id = any(picked);
  return mid;
end; $$;

create or replace function public.queue_poll() returns json language plpgsql security definer set search_path = public as $$
declare me uuid := public.require_account(); q record; m record; cnt integer;
begin
  update mm_queue set last_seen = now() where user_id = me returning * into q;
  if q is null then return json_build_object('status', 'idle'); end if;
  if q.match_id is null then perform public.mm_try_form(q.mode); select * into q from mm_queue where user_id = me; end if;
  if q.match_id is not null then
    select * into m from ranked_matches where id = q.match_id;
    delete from mm_queue where user_id = me;
    return json_build_object('status', 'matched', 'match', json_build_object('id', m.id, 'mode', m.mode, 'code', m.lobby_code, 'host', m.host_id,
      'players', (select json_agg(json_build_object('uid', p.id, 'name', p.name, 'avatar_url', p.avatar_url, 'team', (x->>'team')::int, 'elo', (x->>'elo')::int) order by o)
                  from jsonb_array_elements(m.players) with ordinality as e(x, o) join profiles p on p.id = (x->>'uid')::uuid)));
  end if;
  select count(*) into cnt from mm_queue where mode = q.mode and match_id is null and last_seen > now() - interval '20 seconds';
  return json_build_object('status', 'waiting', 'mode', q.mode, 'in_queue', cnt, 'needed', public.mode_need(q.mode), 'elo', q.elo,
    'range', public.mm_window(extract(epoch from now() - q.joined_at)), 'waited', extract(epoch from now() - q.joined_at)::int);
end; $$;
create or replace function public.queue_join(p_mode text) returns json language plpgsql security definer set search_path = public as $$
declare me uuid := public.require_account();
begin
  if p_mode not in ('casual','solo','2v2','3v3','4v4') then raise exception 'bad_mode'; end if;
  if not exists (select 1 from profiles where id = me) then raise exception 'no_profile'; end if;
  insert into mm_queue (user_id, mode, elo, joined_at, last_seen, match_id) values (me, p_mode, case when p_mode = 'casual' then 0 else public.elo_of(me, p_mode) end, now(), now(), null)
  on conflict (user_id) do update set mode = excluded.mode, elo = excluded.elo, joined_at = now(), last_seen = now(), match_id = null;
  return public.queue_poll();
end; $$;
create or replace function public.queue_leave() returns void language plpgsql security definer set search_path = public as $$ begin delete from mm_queue where user_id = public.require_account() and match_id is null; end; $$;

-- Elo: fair nach Gegner-Stärke; je höher die Elo, desto kleiner die Gewinne und größer die Verluste; nie unter 0
create or replace function public.elo_k(p_elo integer, p_games integer, p_gain boolean) returns numeric language sql immutable as $$
  select (case when p_games < 10 then 60 else 40 end)::numeric
       * case when p_gain then greatest(0.5, 1 - least(p_elo, 2000) / 4000.0) else 1 + least(p_elo, 2000) / 8000.0 end; $$;

-- p_result: Gruppen von Spieler-IDs, beste zuerst, z. B. [["a"],["b","c"],["d"]] (gleiche Gruppe = gleicher Platz)
create or replace function public.ranked_finalize(p_match uuid, p_result jsonb) returns void language plpgsql security definer set search_path = public as $$
declare m record; n integer; uid_i uuid; place_i integer; r_i integer; g_i integer; uid_j uuid; place_j integer; r_j integer; s numeric; e numeric; d numeric; delta numeric; newelo integer; res jsonb := '{}'::jsonb; tm integer; tavg numeric[]; tplace integer[];
begin
  select * into m from ranked_matches where id = p_match for update;
  if m is null or m.status <> 'running' then return; end if;
  if m.mode = 'casual' then update ranked_matches set status = 'done', result = p_result, finalized_at = now() where id = p_match; return; end if;
  create temp table if not exists _rk (uid uuid, team integer, place integer, elo integer, games integer) on commit drop; delete from _rk;
  insert into _rk select (x->>'uid')::uuid, (x->>'team')::int,
      coalesce((select g.o::int from jsonb_array_elements(p_result) with ordinality as g(grp, o) where g.grp ? (x->>'uid') limit 1), 999),
      coalesce(rt.elo, 0), coalesce(rt.games, 0)
    from jsonb_array_elements(m.players) x left join ratings rt on rt.user_id = (x->>'uid')::uuid and rt.mode = m.mode;
  n := (select count(*) from _rk);
  if m.mode = 'solo' then
    for uid_i, place_i, r_i, g_i in select uid, place, elo, games from _rk loop
      delta := 0;
      for uid_j, place_j, r_j in select uid, place, elo from _rk where uid <> uid_i loop
        s := case when place_i < place_j then 1 when place_i = place_j then 0.5 else 0 end;
        e := 1 / (1 + power(10, (r_j - r_i) / 400.0)); d := s - e;
        delta := delta + public.elo_k(r_i, g_i, d > 0) * d / greatest(n - 1, 1);
      end loop;
      newelo := greatest(0, round(r_i + delta)::int);
      res := res || jsonb_build_object(uid_i::text, jsonb_build_object('old', r_i, 'new', newelo, 'place', place_i));
      insert into ratings (user_id, mode, elo, games, wins, peak) values (uid_i, m.mode, newelo, 1, (place_i = 1)::int, newelo)
        on conflict (user_id, mode) do update set elo = newelo, games = ratings.games + 1, wins = ratings.wins + (place_i = 1)::int, peak = greatest(ratings.peak, newelo), updated_at = now();
    end loop;
  else
    tavg := array[(select coalesce(avg(elo), 0) from _rk where team = 0), (select coalesce(avg(elo), 0) from _rk where team = 1)];
    tplace := array[(select min(place) from _rk where team = 0), (select min(place) from _rk where team = 1)];
    for uid_i, tm, r_i, g_i in select uid, team, elo, games from _rk loop
      s := case when tplace[tm + 1] < tplace[2 - tm] then 1 when tplace[tm + 1] = tplace[2 - tm] then 0.5 else 0 end;
      e := 1 / (1 + power(10, (tavg[2 - tm] - tavg[tm + 1]) / 400.0)); d := s - e;
      newelo := greatest(0, round(r_i + public.elo_k(r_i, g_i, d > 0) * d)::int);
      res := res || jsonb_build_object(uid_i::text, jsonb_build_object('old', r_i, 'new', newelo, 'place', tplace[tm + 1]));
      insert into ratings (user_id, mode, elo, games, wins, peak) values (uid_i, m.mode, newelo, 1, (s = 1)::int, newelo)
        on conflict (user_id, mode) do update set elo = newelo, games = ratings.games + 1, wins = ratings.wins + (s = 1)::int, peak = greatest(ratings.peak, newelo), updated_at = now();
    end loop;
  end if;
  update ranked_matches set status = 'done', result = res, finalized_at = now() where id = p_match;
end; $$;

-- Jeder Spieler meldet das Ergebnis; gewertet wird, wenn die Mehrheit (oder alle eingegangenen Meldungen nach 60 s) übereinstimmen
create or replace function public.report_result(p_match uuid, p_result jsonb) returns text language plpgsql security definer set search_path = public as $$
declare me uuid := public.require_account(); m record; n integer; best jsonb; votes integer; total integer;
begin
  select * into m from ranked_matches where id = p_match;
  if m is null then raise exception 'no_match'; end if;
  if not exists (select 1 from jsonb_array_elements(m.players) x where x->>'uid' = me::text) then raise exception 'not_in_match'; end if;
  if jsonb_typeof(p_result) <> 'array' or length(p_result::text) > 4000 then raise exception 'bad_result'; end if;
  if m.status = 'running' then
    insert into ranked_reports (match_id, reporter, result) values (p_match, me, p_result) on conflict (match_id, reporter) do nothing;
    n := jsonb_array_length(m.players);
    select result, count(*) into best, votes from ranked_reports where match_id = p_match group by result order by count(*) desc limit 1;
    select count(*) into total from ranked_reports where match_id = p_match;
    if votes > n / 2
       or (votes = total and votes >= 2 and (select min(created_at) from ranked_reports where match_id = p_match) < now() - interval '60 seconds')
       or (m.created_at < now() - interval '40 minutes') then
      perform public.ranked_finalize(p_match, best);
    end if;
    select * into m from ranked_matches where id = p_match;
  end if;
  return case m.status when 'running' then 'pending' else m.status end;
end; $$;

create or replace function public.leaderboard(p_mode text) returns json language sql stable security definer set search_path = public as $$
  with ranked as (select r.user_id, rank() over (order by r.elo desc) as rank, p.name, p.avatar_url, r.elo, r.games, r.wins, r.updated_at from ratings r join profiles p on p.id = r.user_id where r.mode = p_mode and r.games > 0)
  select json_build_object(
    'top', coalesce((select json_agg(json_build_object('rank', rank, 'name', name, 'avatar_url', avatar_url, 'elo', elo, 'games', games, 'wins', wins) order by rank, wins desc, updated_at) from (select * from ranked order by rank, wins desc, updated_at limit 10) t), '[]'::json),
    'me', (select json_build_object('rank', rank, 'elo', elo) from ranked where user_id = auth.uid() and not coalesce((auth.jwt()->>'is_anonymous')::boolean, false)),
    'players', (select count(*) from ranked)); $$;

-- Profil enthält Bild und Ranked-Elo
create or replace function public.get_profile(p_user uuid default null) returns json language plpgsql security definer set search_path = public as $$ declare me uuid := public.require_account(); target uuid := coalesce(p_user, me); r json; begin if target <> me and not exists (select 1 from friendships where status = 'accepted' and ((requester = me and addressee = target) or (requester = target and addressee = me))) then raise exception 'not_allowed'; end if; select json_build_object('id', p.id, 'name', p.name, 'avatar_url', p.avatar_url, 'friend_code', p.friend_code, 'since', p.created_at, 'is_me', p.id = me, 'stats', (select json_build_object('matches', count(*), 'wins', count(*) filter (where won), 'team_matches', count(*) filter (where mode = 'team'), 'team_wins', count(*) filter (where mode = 'team' and won), 'solo_matches', count(*) filter (where mode = 'solo'), 'solo_wins', count(*) filter (where mode = 'solo' and won), 'photos', coalesce(sum(photos), 0), 'valid_photos', coalesce(sum(valid_photos), 0), 'cells', coalesce(sum(cells), 0), 'lines', coalesce(sum(lines), 0)) from match_results where user_id = p.id), 'ratings', (select coalesce(json_object_agg(mode, json_build_object('elo', elo, 'games', games, 'wins', wins, 'peak', peak)), '{}'::json) from ratings where user_id = p.id), 'recent', (select coalesce(json_agg(x order by x.played_at desc), '[]'::json) from (select played_at, won, mode, size, players, photos, valid_photos, cells, lines from match_results where user_id = p.id order by played_at desc limit 10) x)) into r from profiles p where p.id = target; if r is null then raise exception 'no_profile'; end if; return r; end; $$;

-- Rechte: nur über Funktionen
revoke all on function public.update_profile(text, text) from public; grant execute on function public.update_profile(text, text) to authenticated;
revoke all on function public.ensure_profile(text) from public; grant execute on function public.ensure_profile(text) to authenticated;
revoke all on function public.list_friends() from public; grant execute on function public.list_friends() to authenticated;
revoke all on function public.get_profile(uuid) from public; grant execute on function public.get_profile(uuid) to authenticated;
revoke all on function public.mode_need(text) from public;
revoke all on function public.elo_of(uuid, text) from public;
revoke all on function public.mm_window(numeric) from public;
revoke all on function public.mm_try_form(text) from public;
revoke all on function public.queue_poll() from public; grant execute on function public.queue_poll() to authenticated;
revoke all on function public.queue_join(text) from public; grant execute on function public.queue_join(text) to authenticated;
revoke all on function public.queue_leave() from public; grant execute on function public.queue_leave() to authenticated;
revoke all on function public.elo_k(integer, integer, boolean) from public;
revoke all on function public.ranked_finalize(uuid, jsonb) from public;
revoke all on function public.report_result(uuid, jsonb) from public; grant execute on function public.report_result(uuid, jsonb) to authenticated;
revoke all on function public.leaderboard(text) from public; grant execute on function public.leaderboard(text) to anon, authenticated;
revoke all on function public.mode_need(text), public.elo_of(uuid, text), public.mm_window(numeric), public.mm_try_form(text), public.elo_k(integer, integer, boolean), public.ranked_finalize(uuid, jsonb) from anon, authenticated;
