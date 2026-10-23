-- ===================== Gruppen (Ranked 2v2/3v3/4v4) & Einladungen =====================
-- Gruppe: Freunde gehen zusammen in die Ranked-Suche und landen im selben Team.
-- Einladungen: in eine private Lobby (Lobby-Code) oder in die eigene Gruppe – nur an bestätigte Freunde.
create table public.parties (id uuid primary key default gen_random_uuid(), leader uuid not null references public.profiles(id) on delete cascade, mode text not null check (mode in ('2v2','3v3','4v4')), created_at timestamptz not null default now());
alter table public.parties enable row level security;
create table public.party_members (user_id uuid primary key references public.profiles(id) on delete cascade, party_id uuid not null references public.parties(id) on delete cascade, joined_at timestamptz not null default now());
alter table public.party_members enable row level security;
create table public.invites (id uuid primary key default gen_random_uuid(), from_uid uuid not null references public.profiles(id) on delete cascade, to_uid uuid not null references public.profiles(id) on delete cascade, kind text not null check (kind in ('lobby','party')), lobby_code text check (lobby_code is null or lobby_code ~ '^[A-Z0-9]{4,6}$'), party_id uuid references public.parties(id) on delete cascade, created_at timestamptz not null default now(), unique (from_uid, to_uid, kind));
alter table public.invites enable row level security;
create index invites_to on public.invites (to_uid, created_at);
alter table public.mm_queue add column if not exists party_id uuid;

create or replace function public.are_friends(a uuid, b uuid) returns boolean language sql stable security definer set search_path = public as $$
select exists (select 1 from friendships where status = 'accepted' and ((requester = a and addressee = b) or (requester = b and addressee = a))); $$;

-- Gruppe verlassen (intern): laufende Suche der Gruppe abbrechen, Leitung weitergeben, leere Gruppe auflösen
create or replace function public.party_leave_internal(p_user uuid) returns void language plpgsql security definer set search_path = public as $$
declare pid uuid; nxt uuid;
begin
select party_id into pid from party_members where user_id = p_user; if pid is null then return; end if;
delete from mm_queue where party_id = pid and match_id is null;
delete from party_members where user_id = p_user;
select user_id into nxt from party_members where party_id = pid order by joined_at limit 1;
if nxt is null then delete from parties where id = pid; else update parties set leader = nxt where id = pid and leader = p_user; end if;
end; $$;

create or replace function public.party_state() returns json language sql stable security definer set search_path = public as $$
select (select json_build_object('id', pa.id, 'mode', pa.mode, 'leader', pa.leader, 'size', public.mode_need(pa.mode) / 2,
  'searching', exists (select 1 from mm_queue q where q.party_id = pa.id and q.match_id is null),
  'members', (select json_agg(json_build_object('uid', p.id, 'name', p.name, 'avatar_url', p.avatar_url, 'presence', public.presence_of(p.last_seen, p.last_input), 'elo', public.elo_of(p.id, pa.mode)) order by m.joined_at)
    from party_members m join profiles p on p.id = m.user_id where m.party_id = pa.id))
from party_members me join parties pa on pa.id = me.party_id where me.user_id = auth.uid()); $$;

create or replace function public.party_create(p_mode text) returns json language plpgsql security definer set search_path = public as $$
declare me uuid := public.require_account(); pid uuid;
begin
if p_mode not in ('2v2','3v3','4v4') then raise exception 'bad_mode'; end if;
if not exists (select 1 from profiles where id = me) then raise exception 'no_profile'; end if;
perform public.party_leave_internal(me);
delete from mm_queue where user_id = me and match_id is null;
insert into parties (leader, mode) values (me, p_mode) returning id into pid;
insert into party_members (user_id, party_id) values (me, pid);
return public.party_state();
end; $$;

create or replace function public.party_leave() returns void language plpgsql security definer set search_path = public as $$
begin perform public.party_leave_internal(public.require_account()); end; $$;

create or replace function public.party_kick(p_user uuid) returns json language plpgsql security definer set search_path = public as $$
declare me uuid := public.require_account(); pid uuid;
begin
select id into pid from parties where leader = me;
if pid is null or p_user = me or not exists (select 1 from party_members where user_id = p_user and party_id = pid) then raise exception 'not_allowed'; end if;
perform public.party_leave_internal(p_user);
return public.party_state();
end; $$;

create or replace function public.party_set_mode(p_mode text) returns json language plpgsql security definer set search_path = public as $$
declare me uuid := public.require_account(); pid uuid;
begin
if p_mode not in ('2v2','3v3','4v4') then raise exception 'bad_mode'; end if;
select id into pid from parties where leader = me; if pid is null then raise exception 'not_leader'; end if;
if (select count(*) from party_members where party_id = pid) > public.mode_need(p_mode) / 2 then raise exception 'party_too_big'; end if;
delete from mm_queue where party_id = pid and match_id is null;
update parties set mode = p_mode where id = pid;
return public.party_state();
end; $$;

create or replace function public.invite_friend(p_to uuid, p_kind text, p_code text default null) returns text language plpgsql security definer set search_path = public as $$
declare me uuid := public.require_account(); pid uuid; pmode text;
begin
if p_kind not in ('lobby','party') then raise exception 'bad_kind'; end if;
if not public.are_friends(me, p_to) then raise exception 'not_friends'; end if;
if (select count(*) from invites where from_uid = me and created_at > now() - interval '1 minute') >= 15 then raise exception 'too_fast'; end if;
if p_kind = 'lobby' then
  if coalesce(upper(p_code), '') !~ '^[A-Z0-9]{4,6}$' then raise exception 'bad_code'; end if;
  insert into invites (from_uid, to_uid, kind, lobby_code) values (me, p_to, 'lobby', upper(p_code))
  on conflict (from_uid, to_uid, kind) do update set lobby_code = excluded.lobby_code, party_id = null, created_at = now();
else
  select m.party_id, pa.mode into pid, pmode from party_members m join parties pa on pa.id = m.party_id where m.user_id = me;
  if pid is null then raise exception 'no_party'; end if;
  if exists (select 1 from party_members where user_id = p_to and party_id = pid) then return 'already'; end if;
  if (select count(*) from party_members where party_id = pid) >= public.mode_need(pmode) / 2 then raise exception 'party_full'; end if;
  insert into invites (from_uid, to_uid, kind, party_id) values (me, p_to, 'party', pid)
  on conflict (from_uid, to_uid, kind) do update set party_id = excluded.party_id, lobby_code = null, created_at = now();
end if;
return 'sent';
end; $$;

create or replace function public.respond_invite(p_id uuid, p_accept boolean) returns json language plpgsql security definer set search_path = public as $$
declare me uuid := public.require_account(); inv record; pmode text;
begin
delete from invites where id = p_id and to_uid = me returning * into inv;
if inv is null then return json_build_object('status', 'gone'); end if;
if not p_accept then return json_build_object('status', 'declined'); end if;
if inv.created_at < now() - interval '15 minutes' then return json_build_object('status', 'expired'); end if;
if inv.kind = 'lobby' then return json_build_object('status', 'ok', 'kind', 'lobby', 'code', inv.lobby_code); end if;
select mode into pmode from parties where id = inv.party_id;
if pmode is null then return json_build_object('status', 'gone'); end if;
if exists (select 1 from party_members where user_id = me and party_id = inv.party_id) then return json_build_object('status', 'ok', 'kind', 'party', 'party', public.party_state()); end if;
if (select count(*) from party_members where party_id = inv.party_id) >= public.mode_need(pmode) / 2 then return json_build_object('status', 'full'); end if;
if exists (select 1 from mm_queue where party_id = inv.party_id and match_id is null) then return json_build_object('status', 'busy'); end if;
perform public.party_leave_internal(me);
delete from mm_queue where user_id = me and match_id is null;
insert into party_members (user_id, party_id) values (me, inv.party_id);
return json_build_object('status', 'ok', 'kind', 'party', 'party', public.party_state());
end; $$;

-- Wird von der Seite regelmäßig aufgerufen (nur mit Konto): Online-Status + offene Einladungen + Gruppe
create or replace function public.poll_state(p_active boolean) returns json language plpgsql security definer set search_path = public as $$
declare me uuid := public.require_account();
begin
update profiles set last_seen = now(), last_input = case when p_active then now() else last_input end where id = me;
delete from invites where to_uid = me and created_at < now() - interval '15 minutes';
return json_build_object(
  'invites', (select coalesce(json_agg(json_build_object('id', i.id, 'kind', i.kind, 'code', i.lobby_code, 'from', p.name, 'from_uid', p.id, 'avatar_url', p.avatar_url, 'mode', pa.mode, 'at', i.created_at) order by i.created_at desc), '[]'::json)
    from invites i join profiles p on p.id = i.from_uid left join parties pa on pa.id = i.party_id where i.to_uid = me and public.are_friends(me, i.from_uid)),
  'party', public.party_state());
end; $$;

-- Elo-Fenster: startet bei ±100, wächst um 150 pro Minute; ab 4 Minuten Wartezeit wird mit jeder Elo aufgefüllt.
-- Fair bleibt es über die Elo-Rechnung: Siege gegen Stärkere bringen mehr, Niederlagen gegen Schwächere kosten mehr.
create or replace function public.mm_window(p_waited_sec numeric) returns integer language sql immutable as $$
select case when p_waited_sec >= 240 then 100000 else 100 + floor(p_waited_sec / 60.0 * 150)::int end; $$;
revoke all on function public.mm_window(numeric) from public, anon, authenticated;

-- Warteschlange: als Gruppe suchen (nur der Gruppenleiter, Modus = Gruppenmodus)
create or replace function public.queue_join(p_mode text) returns json language plpgsql security definer set search_path = public as $$
declare me uuid := public.require_account(); pa record; cnt integer;
begin
if p_mode not in ('casual','solo','2v2','3v3','4v4') then raise exception 'bad_mode'; end if;
if not exists (select 1 from profiles where id = me) then raise exception 'no_profile'; end if;
select p.* into pa from party_members m join parties p on p.id = m.party_id where m.user_id = me;
if pa.id is not null then
  if p_mode <> pa.mode then raise exception 'party_mode'; end if;
  if pa.leader <> me then raise exception 'party_member'; end if;
  if exists (select 1 from party_members m join profiles p on p.id = m.user_id where m.party_id = pa.id and (p.last_seen is null or p.last_seen < now() - interval '150 seconds')) then raise exception 'party_offline'; end if;
  delete from mm_queue where user_id in (select user_id from party_members where party_id = pa.id) and match_id is null;
  insert into mm_queue (user_id, mode, elo, joined_at, last_seen, match_id, party_id)
  select m.user_id, p_mode, public.elo_of(m.user_id, p_mode), now(), now(), null, pa.id from party_members m where m.party_id = pa.id
  on conflict (user_id) do update set mode = excluded.mode, elo = excluded.elo, joined_at = now(), last_seen = now(), match_id = null, party_id = excluded.party_id;
  return public.queue_poll();
end if;
insert into mm_queue (user_id, mode, elo, joined_at, last_seen, match_id, party_id) values (me, p_mode, case when p_mode = 'casual' then 0 else public.elo_of(me, p_mode) end, now(), now(), null, null)
on conflict (user_id) do update set mode = excluded.mode, elo = excluded.elo, joined_at = now(), last_seen = now(), match_id = null, party_id = null;
return public.queue_poll();
end; $$;

-- Suche abbrechen: in einer Gruppe bricht das die Suche für die ganze Gruppe ab
create or replace function public.queue_leave() returns void language plpgsql security definer set search_path = public as $$
declare me uuid := public.require_account(); pid uuid;
begin
select party_id into pid from mm_queue where user_id = me and match_id is null;
if pid is not null then delete from mm_queue where party_id = pid and match_id is null;
else delete from mm_queue where user_id = me and match_id is null; end if;
end; $$;

-- Match bilden. Team-Modi: Gruppen bleiben zusammen, die Teams werden nach Elo möglichst ausgeglichen aufgeteilt.
create or replace function public.mm_try_form(p_mode text) returns uuid language plpgsql security definer set search_path = public as $$
declare anchor record; gr record; r record; need integer := public.mode_need(p_mode); k integer; waited numeric; win integer; picked uuid[] := '{}'; elos integer[]; n integer; mid uuid; code text := ''; plist jsonb := '[]'::jsonb; i integer; t integer;
  gids uuid[] := '{}'; gsz integer[] := '{}'; gsum integer[] := '{}'; total integer := 0; c integer; mask integer; s0 integer; e0 integer; etot integer; d integer; best integer; bestdiff integer;
begin
perform pg_advisory_xact_lock(hashtext('mm:' || p_mode));
if p_mode in ('2v2','3v3','4v4') then
  k := need / 2;
  select * into anchor from (select coalesce(party_id, user_id) g, avg(elo) ae, min(joined_at) j, bool_and(last_seen > now() - interval '20 seconds') fresh
    from mm_queue where mode = p_mode and match_id is null group by 1) x where fresh order by j limit 1;
  if anchor is null then return null; end if;
  waited := extract(epoch from now() - anchor.j); win := public.mm_window(waited);
  for gr in select * from (select coalesce(party_id, user_id) g, count(*)::int gn, sum(elo)::int se, avg(elo) ae, min(joined_at) j, bool_and(last_seen > now() - interval '20 seconds') fresh
      from mm_queue where mode = p_mode and match_id is null group by 1) x
      where fresh and gn <= k and abs(ae - anchor.ae) <= win order by (g = anchor.g) desc, abs(ae - anchor.ae), j loop
    if total + gr.gn > need then continue; end if;
    gids := gids || gr.g; gsz := gsz || gr.gn; gsum := gsum || gr.se; total := total + gr.gn;
    if total = need then
      c := array_length(gids, 1); etot := 0; for i in 1..c loop etot := etot + gsum[i]; end loop;
      best := null; bestdiff := null;
      for mask in 0..((1 << (c - 1)) - 1) loop
        s0 := gsz[1]; e0 := gsum[1];
        for i in 2..c loop if ((mask >> (i - 2)) & 1) = 0 then s0 := s0 + gsz[i]; e0 := e0 + gsum[i]; end if; end loop;
        if s0 = k then d := abs(2 * e0 - etot); if bestdiff is null or d < bestdiff then bestdiff := d; best := mask; end if; end if;
      end loop;
      exit when best is not null;
      total := total - gsz[c]; gids := gids[1:c - 1]; gsz := gsz[1:c - 1]; gsum := gsum[1:c - 1];
    end if;
  end loop;
  if best is null then return null; end if;
  for i in 1..c loop
    t := case when i = 1 or ((best >> (i - 2)) & 1) = 0 then 0 else 1 end;
    for r in select user_id, elo from mm_queue where mode = p_mode and match_id is null and coalesce(party_id, user_id) = gids[i] order by elo desc loop
      plist := plist || jsonb_build_object('uid', r.user_id, 'team', t, 'elo', r.elo); picked := picked || r.user_id;
    end loop;
  end loop;
else
  select * into anchor from mm_queue where mode = p_mode and match_id is null and last_seen > now() - interval '20 seconds' order by joined_at limit 1;
  if anchor is null then return null; end if;
  waited := extract(epoch from now() - anchor.joined_at);
  win := case when p_mode = 'casual' then 100000 else public.mm_window(waited) end;
  select array_agg(user_id order by abs(elo - anchor.elo), joined_at), array_agg(elo order by abs(elo - anchor.elo), joined_at) into picked, elos
  from mm_queue where mode = p_mode and match_id is null and last_seen > now() - interval '20 seconds' and abs(elo - anchor.elo) <= win;
  n := coalesce(array_length(picked, 1), 0);
  if n >= need then picked := picked[1:need]; elos := elos[1:need]; n := need;
  elsif p_mode = 'casual' and waited >= 30 and n >= 3 then null;
  elsif p_mode = 'solo' and waited >= 180 and n >= 4 then null;
  else return null; end if;
  for i in 1..n loop plist := plist || jsonb_build_object('uid', picked[i], 'team', null, 'elo', elos[i]); end loop;
end if;
for i in 1..5 loop code := code || substr('ABCDEFGHJKLMNPQRSTUVWXYZ23456789', 1 + floor(random() * 32)::int, 1); end loop;
insert into ranked_matches (mode, lobby_code, host_id, players) values (p_mode, code, picked[1], plist) returning id into mid;
update mm_queue set match_id = mid where user_id = any(picked);
return mid;
end; $$;

revoke all on function public.are_friends(uuid, uuid), public.party_leave_internal(uuid), public.mm_try_form(text) from public, anon, authenticated;
revoke all on function public.party_state() from public, anon; grant execute on function public.party_state() to authenticated;
revoke all on function public.party_create(text) from public, anon; grant execute on function public.party_create(text) to authenticated;
revoke all on function public.party_leave() from public, anon; grant execute on function public.party_leave() to authenticated;
revoke all on function public.party_kick(uuid) from public, anon; grant execute on function public.party_kick(uuid) to authenticated;
revoke all on function public.party_set_mode(text) from public, anon; grant execute on function public.party_set_mode(text) to authenticated;
revoke all on function public.invite_friend(uuid, text, text) from public, anon; grant execute on function public.invite_friend(uuid, text, text) to authenticated;
revoke all on function public.respond_invite(uuid, boolean) from public, anon; grant execute on function public.respond_invite(uuid, boolean) to authenticated;
revoke all on function public.poll_state(boolean) from public, anon; grant execute on function public.poll_state(boolean) to authenticated;
revoke all on function public.queue_join(text) from public, anon; grant execute on function public.queue_join(text) to authenticated;
revoke all on function public.queue_leave() from public, anon; grant execute on function public.queue_leave() to authenticated;
