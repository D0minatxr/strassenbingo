-- Straßenbingo: Tabelle für Wortlisten + Zugriffsregeln (Row Level Security)
create table public.word_lists (
  id uuid primary key default gen_random_uuid(),
  name text not null check (char_length(name) between 1 and 60),
  author text not null default '' check (char_length(author) <= 30),
  words text[] not null check (cardinality(words) between 1 and 300 and char_length(array_to_string(words, '')) <= 12000),
  owner uuid not null default auth.uid(),
  uses integer not null default 0,
  created_at timestamptz not null default now(),
  updated_at timestamptz not null default now()
);
alter table public.word_lists enable row level security;
grant select on public.word_lists to anon, authenticated;
grant insert (name, author, words) on public.word_lists to authenticated;
grant update (name, author, words, updated_at) on public.word_lists to authenticated;
grant delete on public.word_lists to authenticated;
create policy "alle lesen" on public.word_lists for select to anon, authenticated using (true);
create policy "anlegen" on public.word_lists for insert to authenticated with check (owner = auth.uid());
create policy "eigene aendern" on public.word_lists for update to authenticated using (owner = auth.uid()) with check (owner = auth.uid());
create policy "eigene loeschen" on public.word_lists for delete to authenticated using (owner = auth.uid());
create or replace function public.use_word_list(list_id uuid) returns void language sql security definer set search_path = public as $$ update public.word_lists set uses = uses + 1 where id = list_id; $$;
revoke all on function public.use_word_list(uuid) from public;
grant execute on function public.use_word_list(uuid) to anon, authenticated;
-- Voraussetzung: Authentication > Sign In / Providers > "Allow anonymous sign-ins" ist eingeschaltet.

-- Übernahme von Gast-Wortlisten in ein Konto (beim Anmelden)
create table public.list_transfers (code uuid primary key default gen_random_uuid(), from_uid uuid not null, created_at timestamptz not null default now());
alter table public.list_transfers enable row level security;
create or replace function public.prepare_transfer() returns uuid language sql security definer set search_path = public as $$ insert into public.list_transfers (from_uid) values (auth.uid()) returning code; $$;
create or replace function public.claim_transfer(c uuid) returns integer language plpgsql security definer set search_path = public as $$ declare f uuid; n integer := 0; begin if auth.uid() is null then return 0; end if; delete from public.list_transfers where code = c and created_at > now() - interval '1 day' returning from_uid into f; if f is null or f = auth.uid() then return 0; end if; update public.word_lists set owner = auth.uid() where owner = f; get diagnostics n = row_count; return n; end; $$;
revoke all on function public.prepare_transfer() from public;
revoke all on function public.claim_transfer(uuid) from public;
grant execute on function public.prepare_transfer() to authenticated;
grant execute on function public.claim_transfer(uuid) to authenticated;
-- Auth-Einstellungen: Site URL = https://d0minatxr.github.io/strassenbingo/ , Redirect URL = https://d0minatxr.github.io/strassenbingo/**
