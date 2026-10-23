-- ===================== Casual mit allen Modi (ohne Elo) =====================
-- Casual: jeder gegen jeden (casual), 1v1 (c1v1), 2v2/3v3/4v4 (c2v2 …). Keine Elo-Änderung, kein Elo-Fenster.
-- Für ausgeglichene Teams wird trotzdem die Ranked-Elo des passenden Modus zum Aufteilen genutzt.
alter table public.mm_queue drop constraint if exists mm_queue_mode_check;
alter table public.mm_queue add constraint mm_queue_mode_check check (mode in ('casual','solo','1v1','2v2','3v3','4v4','c1v1','c2v2','c3v3','c4v4'));
alter table public.parties drop constraint if exists parties_mode_check;
alter table public.parties add constraint parties_mode_check check (mode in ('2v2','3v3','4v4','c2v2','c3v3','c4v4'));

create or replace function public.is_casual(p_mode text) returns boolean language sql immutable as $$ select p_mode in ('casual','c1v1','c2v2','c3v3','c4v4'); $$;
create or replace function public.elo_mode(p_mode text) returns text language sql immutable as $$ select case when p_mode = 'casual' then 'solo' when p_mode like 'c_v_' then substr(p_mode, 2) else p_mode end; $$;
create or replace function public.mode_need(p_mode text) returns integer language sql immutable as $$ select case p_mode when 'casual' then 8 when 'solo' then 10 when '1v1' then 2 when '2v2' then 4 when '3v3' then 6 when '4v4' then 8 when 'c1v1' then 2 when 'c2v2' then 4 when 'c3v3' then 6 when 'c4v4' then 8 end; $$;

create or replace function public.ranked_finalize(p_match uuid, p_result jsonb) returns void language plpgsql security definer set search_path = public as $$
declare m record; n integer; uid_i uuid; place_i integer; r_i integer; g_i integer; uid_j uuid; place_j integer; r_j integer; s numeric; e numeric; d numeric; delta numeric; newelo integer; res jsonb := '{}'::jsonb; tm integer; tavg numeric[]; tplace integer[];
begin
  select * into m from ranked_matches where id = p_match for update;
  if m is null or m.status <> 'running' then return; end if;
  if public.is_casual(m.mode) then update ranked_matches set status = 'done', result = p_result, finalized_at = now() where id = p_match; return; end if;
  create temp table if not exists _rk (uid uuid, team integer, place integer, elo integer, games integer) on commit drop; delete from _rk;
  insert into _rk select (x->>'uid')::uuid, (x->>'team')::int,
      coalesce((select g.o::int from jsonb_array_elements(p_result) with ordinality as g(grp, o) where g.grp ? (x->>'uid') limit 1), 999),
      coalesce(rt.elo, 0), coalesce(rt.games, 0)
    from jsonb_array_elements(m.players) x left join ratings rt on rt.user_id = (x->>'uid')::uuid and rt.mode = m.mode;
  n := (select count(*) from _rk);
  if m.mode in ('solo','1v1') then
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

create or replace function public.queue_join(p_mode text) returns json language plpgsql security definer set search_path = public as $$
declare me uuid := public.require_account(); pa record; cnt integer;
begin
if p_mode not in ('casual','solo','1v1','2v2','3v3','4v4','c1v1','c2v2','c3v3','c4v4') then raise exception 'bad_mode'; end if;
if not exists (select 1 from profiles where id = me) then raise exception 'no_profile'; end if;
select p.* into pa from party_members m join parties p on p.id = m.party_id where m.user_id = me;
if pa.id is not null then
  if p_mode <> pa.mode then raise exception 'party_mode'; end if;
  if pa.leader <> me then raise exception 'party_member'; end if;
  if exists (select 1 from party_members m join profiles p on p.id = m.user_id where m.party_id = pa.id and (p.last_seen is null or p.last_seen < now() - interval '150 seconds')) then raise exception 'party_offline'; end if;
  delete from mm_queue where user_id in (select user_id from party_members where party_id = pa.id) and match_id is null;
  insert into mm_queue (user_id, mode, elo, joined_at, last_seen, match_id, party_id)
  select m.user_id, p_mode, public.elo_of(m.user_id, public.elo_mode(p_mode)), now(), now(), null, pa.id from party_members m where m.party_id = pa.id
  on conflict (user_id) do update set mode = excluded.mode, elo = excluded.elo, joined_at = now(), last_seen = now(), match_id = null, party_id = excluded.party_id;
  return public.queue_poll();
end if;
insert into mm_queue (user_id, mode, elo, joined_at, last_seen, match_id, party_id) values (me, p_mode, public.elo_of(me, public.elo_mode(p_mode)), now(), now(), null, null)
on conflict (user_id) do update set mode = excluded.mode, elo = excluded.elo, joined_at = now(), last_seen = now(), match_id = null, party_id = null;
return public.queue_poll();
end; $$;

create or replace function public.mm_try_form(p_mode text) returns uuid language plpgsql security definer set search_path = public as $$
declare anchor record; gr record; r record; need integer := public.mode_need(p_mode); k integer; waited numeric; win integer; picked uuid[] := '{}'; elos integer[]; n integer; mid uuid; code text := ''; plist jsonb := '[]'::jsonb; i integer; t integer;
  gids uuid[] := '{}'; gsz integer[] := '{}'; gsum integer[] := '{}'; total integer := 0; c integer; mask integer; s0 integer; e0 integer; etot integer; d integer; best integer; bestdiff integer;
begin
perform pg_advisory_xact_lock(hashtext('mm:' || p_mode));
if p_mode in ('2v2','3v3','4v4','c2v2','c3v3','c4v4') then
  k := need / 2;
  select * into anchor from (select coalesce(party_id, user_id) g, avg(elo) ae, min(joined_at) j, bool_and(last_seen > now() - interval '20 seconds') fresh
    from mm_queue where mode = p_mode and match_id is null group by 1) x where fresh order by j limit 1;
  if anchor is null then return null; end if;
  waited := extract(epoch from now() - anchor.j); win := case when public.is_casual(p_mode) then 100000 else public.mm_window(waited) end;
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
  win := case when public.is_casual(p_mode) then 100000 else public.mm_window(waited) end;
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

create or replace function public.party_create(p_mode text) returns json language plpgsql security definer set search_path = public as $$
declare me uuid := public.require_account(); pid uuid;
begin
if p_mode not in ('2v2','3v3','4v4','c2v2','c3v3','c4v4') then raise exception 'bad_mode'; end if;
if not exists (select 1 from profiles where id = me) then raise exception 'no_profile'; end if;
perform public.party_leave_internal(me);
delete from mm_queue where user_id = me and match_id is null;
insert into parties (leader, mode) values (me, p_mode) returning id into pid;
insert into party_members (user_id, party_id) values (me, pid);
return public.party_state();
end; $$;

create or replace function public.party_set_mode(p_mode text) returns json language plpgsql security definer set search_path = public as $$
declare me uuid := public.require_account(); pid uuid;
begin
if p_mode not in ('2v2','3v3','4v4','c2v2','c3v3','c4v4') then raise exception 'bad_mode'; end if;
select id into pid from parties where leader = me; if pid is null then raise exception 'not_leader'; end if;
if (select count(*) from party_members where party_id = pid) > public.mode_need(p_mode) / 2 then raise exception 'party_too_big'; end if;
delete from mm_queue where party_id = pid and match_id is null;
update parties set mode = p_mode where id = pid;
return public.party_state();
end; $$;

revoke all on function public.is_casual(text), public.elo_mode(text), public.mode_need(text), public.ranked_finalize(uuid, jsonb), public.mm_try_form(text) from public, anon, authenticated;
revoke all on function public.queue_join(text) from public, anon; grant execute on function public.queue_join(text) to authenticated;
revoke all on function public.party_create(text) from public, anon; grant execute on function public.party_create(text) to authenticated;
revoke all on function public.party_set_mode(text) from public, anon; grant execute on function public.party_set_mode(text) to authenticated;
