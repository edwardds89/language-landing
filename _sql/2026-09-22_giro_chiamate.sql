-- LanguagePin · Giro di chiamate
-- 22 settembre 2026 · progetto Supabase "languagepin" (org edwardds89)
--
-- Tabelle di supporto alla pagina https://languagepin.co.uk/staff-chiamate.html
--   venue_contacts : telefono e dati di contatto dei locali
--   calls          : un record per ogni telefonata fatta
--
-- I contatti NON stanno in `venues`, che e' leggibile da chiunque abbia la chiave
-- pubblica del sito. Qui la lettura e' ristretta agli indirizzi di is_lp_staff().
--
-- Lo script e' idempotente: si puo' rieseguire senza rompere niente.
-- ATTENZIONE: nel SQL Editor di Supabase compare l'avviso "Potential issue detected".
-- Finche' non si conferma con "Run query" NON viene eseguito nulla, e non appare
-- nessun errore. Verificare sempre che gli oggetti esistano davvero.

-- ============================================================ 1 · allowlist
create or replace function public.is_lp_staff()
returns boolean
language sql
stable
security definer
set search_path = public
as $$
  select lower(coalesce(auth.jwt() ->> 'email', '')) in (
    'edoardo@myself.com',              -- account con cui Edoardo e' loggato sul sito
    'edoardodesantislnd@gmail.com',
    'luigi.g.consorti@gmail.com'
  );
$$;

comment on function public.is_lp_staff() is
  'Allowlist per email. Per dare accesso a qualcuno: rieseguire questa funzione con l''indirizzo in piu''.';

-- ====================================================== 2 · venue_contacts
create table if not exists public.venue_contacts (
  venue_id      bigint primary key references public.venues(id) on delete cascade,
  phone         text,
  contact_name  text,          -- il nome da chiedere, in MAIUSCOLO sul foglio
  found_when    text,          -- quando si trova quella persona
  score         smallint,      -- punteggio 0-15 del modello di verifica
  wave          text,          -- onda1 | onda2 | onda3 | riserva | ferie | senza_numero
  call_window   text,          -- finestra consigliata, IN ORA ITALIANA
  closed_days   text,          -- es. 'lun' oppure 'lun,dom'
  postcode      text,          -- es. EC1V
  zone          text,          -- cluster a piedi, es. 'Clerkenwell'
  updated_at    timestamptz not null default now()
);

alter table public.venue_contacts enable row level security;

drop policy if exists venue_contacts_staff on public.venue_contacts;
create policy venue_contacts_staff on public.venue_contacts
  for all to authenticated
  using (public.is_lp_staff())
  with check (public.is_lp_staff());

create index if not exists venue_contacts_wave_idx on public.venue_contacts(wave);
create index if not exists venue_contacts_zone_idx on public.venue_contacts(zone);

-- =============================================================== 3 · calls
create table if not exists public.calls (
  id             bigint generated always as identity primary key,
  venue_id       bigint not null references public.venues(id) on delete cascade,
  called_at      timestamptz not null default now(),
  outcome        text not null check (outcome in
                   ('si','richiamare','no','non_risponde','numero_errato')),
  answered_by    text,          -- chi ha risposto al telefono
  contact_name   text,          -- la persona giusta da ricontattare
  found_when     text,          -- quando la si trova
  callback_at    timestamptz,   -- giorno e ora del richiamo
  quiet_hours    text,          -- orari tranquilli -> diventera' il recommended time
  italian_staff  text,          -- quanti italiani e in quali turni
  objection      text,          -- obiezione o condizione posta
  notes          text,
  created_by     uuid  not null default auth.uid(),
  created_email  text  not null default (auth.jwt() ->> 'email')
);

alter table public.calls enable row level security;

drop policy if exists calls_staff on public.calls;
create policy calls_staff on public.calls
  for all to authenticated
  using (public.is_lp_staff())
  with check (public.is_lp_staff());

create index if not exists calls_venue_idx    on public.calls(venue_id, called_at desc);
create index if not exists calls_callback_idx on public.calls(callback_at)
  where outcome = 'richiamare';

-- ========================================================= 4 · permessi
-- SENZA QUESTI la pagina risponde "permission denied for table venue_contacts".
-- Le tabelle nuove in questo progetto non ereditano i privilegi di default.
grant select, insert, update, delete on table public.venue_contacts to authenticated;
grant select, insert, update, delete on table public.calls           to authenticated;
grant execute on function public.is_lp_staff()                       to authenticated;

-- ============================ 5 · vista comoda: ultimo esito per locale
-- Non usata dalla pagina: serve per interrogare il giro a colpo d'occhio.
create or replace view public.v_call_status
with (security_invoker = true) as
select
  v.id                  as venue_id,
  v.name,
  v.venue_type,
  v.area,
  v.borough,
  c.wave,
  c.zone,
  c.postcode,
  c.phone,
  c.contact_name        as target_name,
  c.call_window,
  c.score,
  last_call.outcome     as last_outcome,
  last_call.called_at   as last_called_at,
  last_call.callback_at as next_callback_at
from public.venues v
left join public.venue_contacts c on c.venue_id = v.id
left join lateral (
  select outcome, called_at, callback_at
  from public.calls k
  where k.venue_id = v.id
  order by k.called_at desc
  limit 1
) last_call on true
where v.is_active;

grant select on public.v_call_status to authenticated;

-- ============================================================ 6 · controlli
-- select count(*) from public.venues where is_active;          -- atteso 109
-- select count(*) from public.venue_contacts;                  -- atteso 106
-- select count(*) from public.venue_contacts where phone is not null;  -- atteso 99
-- select count(*) from public.venue_contacts where wave = 'onda1';     -- atteso 25
-- select public.is_lp_staff();                                 -- atteso true
--
-- Locali attivi ancora senza contatto (atteso: AMARO BAR, Bar Termini, Canada Water Cafe):
-- select v.name from public.venues v
-- where v.is_active and not exists (select 1 from public.venue_contacts c where c.venue_id = v.id)
-- order by v.name;
