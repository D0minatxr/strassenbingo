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
