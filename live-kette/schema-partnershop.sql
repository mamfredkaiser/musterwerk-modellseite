-- =====================================================================
-- Live-Kette Musterwerk Vorteilsportal: der Partnershop mit eigenem Server
-- Stand 10.09.2026 abends, Arbeitspaket 5, Nachtrag (Ergebnis 5 aus dem
-- Folgeprompt, Luecke 9 im Standsbericht)
--
-- Bis hierher kam der Server-Postback des Deeplink-Partners aus dem
-- Browser der Partnerseite: ein fetch auf /postback/partnershop, der so
-- tat, als sei er das Shopsystem. Seit diesem Nachtrag gibt es das
-- Shopsystem als eigene Edge Function partnershop, und sie braucht einen
-- Ort, an dem sie sich ihre Bestellungen merkt. Das ist diese Tabelle.
--
-- Die Tabelle gehoert im Modell dem Partner, nicht dem Portal. Sie liegt
-- nur deshalb in derselben Datenbank, weil ein zweites Supabase-Projekt
-- fuer eine Attrappe zu viel waere. Das Portal liest sie nie: keine Sicht
-- in modell, kein Join im Trichter, kein Widget. Was das Portal ueber eine
-- Bestellung weiss, steht in postbacks, und nur das, was der Shop gemeldet
-- hat. Die Abfrage 12 in abfragen-klickout.sql legt beide Seiten fuer den
-- Abgleich nebeneinander; das ist der Blick eines Pruefers, nicht der des
-- Portals.
--
-- Ausfuehren im Supabase-SQL-Editor des Projekts zdiivmckxenneeyvtldg,
-- nach schema-klickout.sql. Mehrfach ausfuehrbar.
-- =====================================================================

-- ---------------------------------------------------------------------
-- 1. Die Bestellungen des Shops
-- Eine Zeile je Bestellung. Der Ausgang (Freigabe oder Storno) wird beim
-- Bestellen gewuerfelt, acht Prozent Storno wie im synthetischen
-- Grundbestand, oder auf der Partnerseite vorgegeben, damit eine
-- Vorfuehrung beide Faelle zeigen kann. abschluss_faellig_am sagt, wann
-- der Ausgang im Shop eintritt: Freigabe nach 14 Tagen, Storno nach 2 bis
-- 13 Tagen, also innerhalb der Rueckgabefrist und vor der Freigabe.
--
-- Die Spalten *_gemeldet_am und *_antwort sind der Postausgang des Shops:
-- was er dem Portal wann gemeldet hat und was zurueckkam. Eine Meldung, die
-- scheitert, bleibt ohne Datum stehen, und der naechste Lauf holt sie nach.
-- ---------------------------------------------------------------------

create table if not exists public.partnershop_bestellungen (
    id                      bigint generated always as identity primary key,
    bestellnummer           text          not null unique,         -- vom Shop vergeben, B- und sechs Hexstellen
    bestellt_am             timestamptz   not null default now(),  -- Uhr des Shop-Servers
    klick_id                text,          -- cbk aus der Adresse der Partnerseite; fehlt sie, meldet der Shop trotzdem
    kampagne                text,          -- utm_campaign aus der Adresse, beim Portal die Angebotsnummer
    shop                    text,          -- Name des Shops, nur Beschriftung der Attrappe
    bestellwert             numeric(10,2) not null,
    waehrung                text          not null default 'EUR',
    ausgang                 text          not null,   -- freigabe oder storno
    ausgang_grund           text          not null,   -- gewuerfelt oder vorgegeben
    abschluss_faellig_am    timestamptz   not null,   -- wann Freigabe oder Storno im Shop eintritt
    status                  text          not null default 'offen',   -- offen, bestaetigt, storniert
    bestellung_gemeldet_am  timestamptz,   -- Serveruhr, als die Meldung "offen" beim Portal angenommen wurde
    bestellung_antwort      jsonb,         -- HTTP-Status und Antwort des Portals auf diese Meldung
    abschluss_gemeldet_am   timestamptz,   -- Serveruhr, als Freigabe oder Storno angenommen wurde
    abschluss_uhr_shop      timestamptz,   -- Uhr des Shops in diesem Moment; bei vorgestellter Uhr in der Zukunft
    vorgespult_tage         integer,       -- um wie viele Tage die Uhr des Shops vorgestellt war, sonst NULL
    abschluss_antwort       jsonb,
    versuche                integer       not null default 0,   -- Meldeversuche insgesamt
    letzter_fehler          text,
    in_arbeit_seit          timestamptz,   -- Sperre, damit zwei Laeufe dieselbe Zeile nicht zweimal melden
    qualitaet               text          not null default 'ok',
    constraint partnershop_bestellungen_ausgang_chk check (ausgang in ('freigabe', 'storno')),
    constraint partnershop_bestellungen_status_chk  check (status in ('offen', 'bestaetigt', 'storniert'))
);

comment on table public.partnershop_bestellungen is
    'Bestellungen des Deeplink-Partners, gefuehrt von der Edge Function partnershop. Gehoert im Modell dem Partner; das Portal liest die Tabelle nie und weiss nur, was in postbacks gemeldet wurde. Keine IP, kein User-Agent, keine Person: die Klick-ID ist die einzige Referenz auf das Portal.';
comment on column public.partnershop_bestellungen.abschluss_faellig_am is
    'Zeitpunkt, an dem der Ausgang im Shop eintritt: Freigabe 14 Tage nach der Bestellung, Storno 2 bis 13 Tage danach. Der Lauf partnershop/lauf meldet ihn, sobald die Uhr des Shops diesen Zeitpunkt erreicht hat.';
comment on column public.partnershop_bestellungen.abschluss_uhr_shop is
    'Uhr des Shops beim Melden des Abschlusses. Liegt sie nach abschluss_gemeldet_am, war die Uhr fuer die Vorfuehrung vorgestellt (Spalte vorgespult_tage).';
comment on column public.partnershop_bestellungen.in_arbeit_seit is
    'Von einem Lauf gesetzt, solange er die Zeile meldet, danach wieder NULL. Eine Sperre aelter als zwei Minuten gilt als verwaist und wird uebernommen.';

create index if not exists partnershop_bestellungen_offen_idx
    on public.partnershop_bestellungen (abschluss_faellig_am)
    where abschluss_gemeldet_am is null;
create index if not exists partnershop_bestellungen_klick_idx
    on public.partnershop_bestellungen (klick_id) where klick_id is not null;

-- ---------------------------------------------------------------------
-- 2. Zeilenschutz und Rechte
-- Wie bei allen Tabellen der Kette: RLS an, keine Richtlinie fuer anon und
-- authenticated, die Edge Function schreibt mit dem Dienstschluessel.
-- update braucht sie, weil der Postausgang in derselben Zeile steht.
-- ---------------------------------------------------------------------

alter table public.partnershop_bestellungen enable row level security;

revoke all on table public.partnershop_bestellungen from anon, authenticated;
grant select, insert, update on table public.partnershop_bestellungen to service_role;
-- Die Sequenz bekommt in Supabase ueber die Standardrechte auch anon und
-- authenticated; ueber die Schnittstelle ist sie nicht erreichbar, das Recht
-- wird trotzdem entzogen, weil niemand ausser dem Shop es braucht.
revoke all on sequence public.partnershop_bestellungen_id_seq from anon, authenticated;
grant usage, select on sequence public.partnershop_bestellungen_id_seq to service_role;

-- ---------------------------------------------------------------------
-- 3. Aufraeumen
-- Vor einer Vorfuehrung gehoert der Shop mit aufgeraeumt. Sonst meldet ein
-- spaeterer Lauf alte Bestellungen, deren Klick-IDs klickout_aufraeumen(0)
-- schon entfernt hat, und der Trichter zeigt verwaiste Postbacks, die mit
-- dem Gespraech nichts zu tun haben. p_tage = 0 leert die Tabelle.
-- ---------------------------------------------------------------------

create or replace function public.partnershop_aufraeumen(
    p_tage integer default 30
) returns integer
language plpgsql
security definer
set search_path = public
as $$
declare
    geloescht integer;
begin
    delete from public.partnershop_bestellungen
     where bestellt_am < now() - make_interval(days => p_tage);
    get diagnostics geloescht = row_count;
    return geloescht;
end;
$$;

comment on function public.partnershop_aufraeumen(integer) is
    'Loescht Bestellungen des Partnershops, die aelter als p_tage sind, und gibt die Zahl zurueck. 0 leert die Tabelle; vor einer Vorfuehrung zusammen mit klickout_aufraeumen(0).';

-- PUBLIC gehoert dazu, siehe schema.sql Abschnitt 4: die Funktion ist
-- security definer und darf ueber die Schnittstelle niemand aufrufen.
revoke all on function public.partnershop_aufraeumen(integer) from public, anon, authenticated;
grant execute on function public.partnershop_aufraeumen(integer) to service_role;
