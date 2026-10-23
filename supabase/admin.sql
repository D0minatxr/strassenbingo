-- Meldungen (Bugs, Ideen, Spieler, Fotos), Admin-Postfach und Nachrichten an Spieler.
-- Admin ist nur, wer in public.admins steht (vom Server geprüft).
create table if not exists public.admins (user_id uuid primary key references public.profiles(id) on delete cascade);
alter table public.admins enable row level security;
revoke all on public.admins from anon, authenticated;

create table if not exists public.reports (
  id uuid primary key default gen_random_uuid(),
  created_at timestamptz not null default now(),
  reporter uuid references public.profiles(id) on delete set null,
  kind text not null check (kind in ('bug', 'idea', 'player', 'photo')),
  reason text not null default '' check (char_length(reason) <= 60),
  body text not null default '' check (char_length(body) <= 2000),
  context jsonb not null default '{}'::jsonb check (length(context::text) <= 8000),
  target uuid references public.profiles(id) on delete set null,
  target_name text not null default '' check (char_length(target_name) <= 40),
  word text not null default '' check (char_length(word) <= 80),
  image text check (image is null or length(image) <= 700000),
  votes jsonb not null default '[]'::jsonb check (length(votes::text) <= 8000),
  status text not null default 'open' check (status in ('open', 'done')),
  done_at timestamptz
);
create index if not exists reports_status_idx on public.reports (status, created_at desc);
alter table public.reports enable row level security;
revoke all on public.reports from anon, authenticated;

create table if not exists public.admin_messages (
  id uuid primary key default gen_random_uuid(),
  created_at timestamptz not null default now(),
  user_id uuid not null references public.profiles(id) on delete cascade,
  report_id uuid references public.reports(id) on delete set null,
  title text not null check (char_length(title) between 1 and 120),
  body text not null check (char_length(body) between 1 and 3000),
  read_at timestamptz
);
create index if not exists admin_messages_user_idx on public.admin_messages (user_id, created_at desc);
alter table public.admin_messages enable row level security;
revoke all on public.admin_messages from anon, authenticated;

create or replace function public.is_admin() returns boolean language sql stable security definer set search_path = public as $$
  select auth.uid() is not null and exists (select 1 from admins where user_id = auth.uid());
$$;
create or replace function public.require_admin() returns uuid language plpgsql stable security definer set search_path = public as $$
begin if not public.is_admin() then raise exception 'not_admin'; end if; return auth.uid(); end; $$;

-- Meldung abschicken (nur mit Konto, max. 10 pro Stunde)
create or replace function public.submit_report(p_kind text, p_reason text, p_body text, p_context jsonb, p_target uuid, p_target_name text, p_word text, p_image text, p_votes jsonb)
returns uuid language plpgsql security definer set search_path = public as $$
declare me uuid := public.require_account(); rid uuid; b text := btrim(coalesce(p_body, ''));
begin
  if not exists (select 1 from profiles where id = me) then raise exception 'no_profile'; end if;
  if p_kind not in ('bug', 'idea', 'player', 'photo') then raise exception 'bad_kind'; end if;
  if (select count(*) from reports where reporter = me and created_at > now() - interval '1 hour') >= 10 then raise exception 'too_many'; end if;
  if p_kind in ('bug', 'idea', 'player') and char_length(b) < 3 then raise exception 'body_required'; end if;
  if p_image is not null and (p_kind <> 'photo' or p_image !~ '^data:image/(jpeg|png|webp);base64,[A-Za-z0-9+/]+={0,2}$' or length(p_image) > 700000) then raise exception 'bad_image'; end if;
  insert into reports (reporter, kind, reason, body, context, target, target_name, word, image, votes)
  values (me, p_kind, left(coalesce(p_reason, ''), 60), left(b, 2000),
          case when jsonb_typeof(p_context) = 'object' and length(p_context::text) <= 8000 then p_context else '{}'::jsonb end,
          (select id from profiles where id = p_target), left(coalesce(p_target_name, ''), 40), left(coalesce(p_word, ''), 80), p_image,
          case when jsonb_typeof(p_votes) = 'array' and length(p_votes::text) <= 8000 then p_votes else '[]'::jsonb end)
  returning id into rid;
  return rid;
end; $$;

-- Admin: Liste (ohne Bild, das kommt einzeln)
create or replace function public.admin_reports(p_status text) returns json language plpgsql stable security definer set search_path = public as $$
declare r json;
begin
  perform public.require_admin();
  select coalesce(json_agg(x order by x.created_at desc), '[]'::json) into r from (
    select rp.id, rp.created_at, rp.kind, rp.reason, rp.body, rp.context, rp.target, rp.target_name, rp.word, rp.votes, rp.status, rp.done_at,
           rp.image is not null as has_image, rp.reporter, p.name as reporter_name, p.friend_code as reporter_code, t.name as target_profile_name,
           (select count(*) from admin_messages m where m.report_id = rp.id) as replies
    from reports rp left join profiles p on p.id = rp.reporter left join profiles t on t.id = rp.target
    where rp.status = coalesce(p_status, 'open') order by rp.created_at desc limit 200) x;
  return r;
end; $$;
create or replace function public.admin_report_image(p_id uuid) returns text language plpgsql stable security definer set search_path = public as $$
begin perform public.require_admin(); return (select image from reports where id = p_id); end; $$;
create or replace function public.admin_set_status(p_id uuid, p_status text) returns void language plpgsql security definer set search_path = public as $$
begin
  perform public.require_admin();
  if p_status not in ('open', 'done') then raise exception 'bad_status'; end if;
  update reports set status = p_status, done_at = case when p_status = 'done' then now() else null end where id = p_id;
end; $$;
create or replace function public.admin_delete_report(p_id uuid) returns void language plpgsql security definer set search_path = public as $$
begin perform public.require_admin(); delete from reports where id = p_id; end; $$;
create or replace function public.admin_counts() returns json language plpgsql stable security definer set search_path = public as $$
begin perform public.require_admin(); return json_build_object('open', (select count(*) from reports where status = 'open')); end; $$;

-- Admin: Nachricht an Spieler (Melder, Beteiligte) – landet in deren Postfach
create or replace function public.admin_send(p_report uuid, p_to uuid[], p_title text, p_body text) returns integer language plpgsql security definer set search_path = public as $$
declare n integer;
begin
  perform public.require_admin();
  if coalesce(array_length(p_to, 1), 0) = 0 or array_length(p_to, 1) > 20 then raise exception 'bad_recipients'; end if;
  if char_length(btrim(coalesce(p_body, ''))) < 1 then raise exception 'body_required'; end if;
  insert into admin_messages (user_id, report_id, title, body)
  select p.id, (select id from reports where id = p_report), left(coalesce(nullif(btrim(p_title), ''), 'Nachricht vom Admin'), 120), left(btrim(p_body), 3000)
  from profiles p where p.id = any(p_to);
  get diagnostics n = row_count;
  return n;
end; $$;

-- Spieler: eigenes Postfach
create or replace function public.my_messages() returns json language sql stable security definer set search_path = public as $$
  select coalesce(json_agg(x order by x.created_at desc), '[]'::json) from (
    select id, created_at, title, body, read_at from admin_messages where user_id = public.require_account() order by created_at desc limit 50) x;
$$;
create or replace function public.unread_messages() returns integer language sql stable security definer set search_path = public as $$
  select count(*)::int from admin_messages where user_id = public.require_account() and read_at is null;
$$;
create or replace function public.read_messages() returns void language sql security definer set search_path = public as $$
  update admin_messages set read_at = now() where user_id = public.require_account() and read_at is null;
$$;

revoke all on function public.is_admin(), public.require_admin(), public.submit_report(text, text, text, jsonb, uuid, text, text, text, jsonb),
  public.admin_reports(text), public.admin_report_image(uuid), public.admin_set_status(uuid, text), public.admin_delete_report(uuid), public.admin_counts(),
  public.admin_send(uuid, uuid[], text, text), public.my_messages(), public.unread_messages(), public.read_messages() from public, anon;
grant execute on function public.is_admin(), public.submit_report(text, text, text, jsonb, uuid, text, text, text, jsonb),
  public.admin_reports(text), public.admin_report_image(uuid), public.admin_set_status(uuid, text), public.admin_delete_report(uuid), public.admin_counts(),
  public.admin_send(uuid, uuid[], text, text), public.my_messages(), public.unread_messages(), public.read_messages() to authenticated;
revoke all on function public.require_admin() from authenticated;

-- Admin festlegen: Konto „MauTschateo“ mit Freundescode 912192
insert into public.admins (user_id) select id from public.profiles where friend_code = '912192' and name = 'MauTschateo' on conflict do nothing;
