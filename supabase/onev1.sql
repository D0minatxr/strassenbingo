-- ===================== Ranked 1v1 =====================
-- Zwei Spieler gegeneinander, eigene Elo und eigene Bestenliste. Gewertet wie Solo (paarweise Elo).
alter table public.ratings drop constraint if exists ratings_mode_check;
alter table public.ratings add constraint ratings_mode_check check (mode in ('solo','1v1','2v2','3v3','4v4'));
alter table public.mm_queue drop constraint if exists mm_queue_mode_check;
alter table public.mm_queue add constraint mm_queue_mode_check check (mode in ('casual','solo','1v1','2v2','3v3','4v4'));

create or replace function public.mode_need(p_mode text) returns integer language sql immutable as $$ select case p_mode when 'casual' then 8 when 'solo' then 10 when '1v1' then 2 when '2v2' then 4 when '3v3' then 6 when '4v4' then 8 end; $$;

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
if p_mode not in ('casual','solo','1v1','2v2','3v3','4v4') then raise exception 'bad_mode'; end if;
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

revoke all on function public.mode_need(text), public.ranked_finalize(uuid, jsonb) from public, anon, authenticated;
revoke all on function public.queue_join(text) from public, anon; grant execute on function public.queue_join(text) to authenticated;
