-- Piano Trainer: Sync über alle Geräte.
-- Einmal im Supabase-Dashboard unter "SQL Editor" einfügen und auf "Run" klicken.
--
-- Prinzip: Es gibt keine Konten. Jedes Gerät, das den gleichen 24-stelligen Sync-Code kennt,
-- sieht die gleichen Daten. Gespeichert wird nur ein SHA-256-Fingerabdruck des Codes, nie der Code.
-- Die Tabellen selbst sind für die App gesperrt; sie liest und schreibt nur über die drei
-- Funktionen unten, die jeweils den Code prüfen.

create extension if not exists pgcrypto with schema extensions;

create table if not exists public.pt_sync (
  id         text primary key,                 -- Fingerabdruck des Sync-Codes
  state      jsonb not null default '{}'::jsonb, -- Fortschritt, Einstellungen, Stimmen-Wahl
  updated_at timestamptz not null default now()
);

create table if not exists public.pt_songs (
  sync_id    text not null references public.pt_sync(id) on delete cascade,
  name       text not null,
  data       text,                             -- MIDI-Datei als Base64
  played     bigint not null default 0,        -- zuletzt geöffnet (ms seit 1970)
  deleted    boolean not null default false,   -- gelöscht, damit es auf allen Geräten verschwindet
  updated_at timestamptz not null default now(),
  primary key (sync_id, name)
);

alter table public.pt_sync  enable row level security;
alter table public.pt_songs enable row level security;
revoke all on public.pt_sync, public.pt_songs from anon, authenticated;

create or replace function public.pt_id(p_code text) returns text
language plpgsql immutable set search_path = public, extensions as $$
begin
  if p_code is null or length(p_code) < 20 then raise exception 'Ungültiger Sync-Code'; end if;
  return encode(extensions.digest(upper(p_code), 'sha256'), 'hex');
end $$;

-- Stand holen: Einstellungen plus Liste der Songs (ohne die Dateien selbst)
create or replace function public.pt_pull(p_code text) returns jsonb
language plpgsql security definer set search_path = public, extensions as $$
declare k text := pt_id(p_code);
begin
  return jsonb_build_object(
    'state', (select state from pt_sync where id = k),
    'songs', coalesce((select jsonb_agg(jsonb_build_object(
               'name', name, 'played', played, 'deleted', deleted,
               't', (extract(epoch from updated_at) * 1000)::bigint))
             from pt_songs where sync_id = k), '[]'::jsonb));
end $$;

-- Song-Dateien holen, die auf diesem Gerät fehlen
create or replace function public.pt_get(p_code text, p_names text[]) returns jsonb
language plpgsql security definer set search_path = public, extensions as $$
declare k text := pt_id(p_code);
begin
  return coalesce((select jsonb_agg(jsonb_build_object('name', name, 'data', data, 'played', played))
                   from pt_songs where sync_id = k and name = any(p_names) and not deleted), '[]'::jsonb);
end $$;

-- Stand speichern; p_state null lässt den gespeicherten Stand unverändert
create or replace function public.pt_push(p_code text, p_state jsonb, p_songs jsonb) returns void
language plpgsql security definer set search_path = public, extensions as $$
declare k text := pt_id(p_code); s jsonb;
begin
  if pg_column_size(p_state) > 2000000 then raise exception 'Stand zu groß'; end if;
  insert into pt_sync (id, state) values (k, coalesce(p_state, '{}'::jsonb))
    on conflict (id) do update
    set state = coalesce(p_state, pt_sync.state), updated_at = now();
  for s in select * from jsonb_array_elements(coalesce(p_songs, '[]'::jsonb)) loop
    continue when s->>'name' is null or length(coalesce(s->>'data', '')) > 3000000;
    insert into pt_songs (sync_id, name, data, played, deleted)
      values (k, s->>'name', s->>'data', coalesce((s->>'played')::bigint, 0), coalesce((s->>'deleted')::boolean, false))
    on conflict (sync_id, name) do update set
      deleted    = excluded.deleted,
      data       = case when excluded.deleted then null else coalesce(excluded.data, pt_songs.data) end,
      played     = greatest(pt_songs.played, excluded.played),
      updated_at = now();
  end loop;
end $$;

revoke all on function public.pt_pull(text), public.pt_get(text, text[]), public.pt_push(text, jsonb, jsonb) from public;
grant execute on function public.pt_pull(text), public.pt_get(text, text[]), public.pt_push(text, jsonb, jsonb) to anon, authenticated;
