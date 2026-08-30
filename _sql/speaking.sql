-- LanguagePin · "Com'è andata?" — la risposta dello studente dopo il tap
--
-- REGOLA DI FONDO, e non è un dettaglio tecnico:
-- questa tabella NON tocca punti, giorni, soglie o lezioni. Mai.
-- Il premio dipende solo da `checkins`, che scrive la Edge Function dopo aver
-- verificato il CMAC del tag. Se la risposta di uno studente valesse punti,
-- diventerebbe una casella da spuntare e il dato non varrebbe piu' niente.
-- Cosi' invece non c'e' nessun motivo per mentire, e i numeri sono veri.
--
-- `checkins` resta immutabile: qui si INSERISCE accanto, non si aggiorna là.

create table if not exists public.speaking_log (
  id          bigint generated always as identity primary key,
  checkin_id  bigint not null references public.checkins(id) on delete cascade,
  user_id     uuid   not null references auth.users(id) on delete cascade,
  venue_id    bigint not null references public.venues(id) on delete cascade,
  -- 'full'    = ho detto tutto in italiano
  -- 'mixed'   = ho fatto un misto
  -- 'english' = sono passato all'inglese
  spoke       text   not null check (spoke in ('full','mixed','english')),
  created_at  timestamptz not null default now(),
  -- una sola risposta per check-in: si risponde, non si ritratta
  unique (checkin_id)
);

create index if not exists speaking_log_user_idx  on public.speaking_log (user_id);
create index if not exists speaking_log_venue_idx on public.speaking_log (venue_id);

alter table public.speaking_log enable row level security;

-- Lo studente puo' scrivere UNA riga, solo per se stesso, e solo su un check-in
-- che gli appartiene davvero. Non puo' rispondere per conto di altri.
create policy "rispondi solo per i tuoi check-in"
  on public.speaking_log for insert to authenticated
  with check (
    user_id = auth.uid()
    and exists (
      select 1 from public.checkins c
      where c.id = checkin_id and c.user_id = auth.uid()
    )
  );

-- Puo' rileggere solo le proprie risposte.
create policy "leggi solo le tue risposte"
  on public.speaking_log for select to authenticated
  using (user_id = auth.uid());

revoke all    on public.speaking_log from anon, authenticated;
grant  select, insert on public.speaking_log to authenticated;

-- ─────────────────────────────────────────────────────────────────────────
-- Il badge: quante volte hai tenuto tutta la conversazione in italiano.
-- Non conta i giorni, non conta i locali: conta le volte che hai parlato.
-- ─────────────────────────────────────────────────────────────────────────
create or replace view public.speaking_me as
select
  count(*) filter (where spoke = 'full')                      as full_it,
  count(*) filter (where spoke = 'mixed')                     as misto,
  count(*) filter (where spoke = 'english')                   as inglese,
  count(*)                                                    as risposte,
  count(distinct venue_id) filter (where spoke = 'full')      as locali_full
from public.speaking_log
where user_id = auth.uid();

revoke all    on public.speaking_me from anon, authenticated;
grant  select on public.speaking_me to authenticated;

-- ─────────────────────────────────────────────────────────────────────────
-- Il dato che vale per i locali. Nessun nome, nessun user_id: solo il numero
-- di persone e la percentuale di conversazioni rette in italiano.
-- Questo e' cio' che mostri al ristoratore quando torni a proporgli il rinnovo.
-- Non e' accessibile dal browser: lo leggi tu dal pannello.
-- ─────────────────────────────────────────────────────────────────────────
create or replace view public.venue_speaking as
select
  v.id, v.name, v.venue_type, v.area,
  count(s.*)                                        as risposte,
  count(*) filter (where s.spoke = 'full')          as full_it,
  count(*) filter (where s.spoke = 'english')       as persi_in_inglese,
  round(100.0 * count(*) filter (where s.spoke = 'full')
        / nullif(count(s.*), 0), 0)                 as pct_italiano,
  count(distinct s.user_id)                         as persone
from public.venues v
left join public.speaking_log s on s.venue_id = v.id
group by v.id, v.name, v.venue_type, v.area;

revoke all on public.venue_speaking from anon, authenticated;

select 'speaking_log pronta' as esito,
       (select count(*) from public.speaking_log) as risposte;
