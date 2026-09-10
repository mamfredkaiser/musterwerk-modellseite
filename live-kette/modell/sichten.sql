-- =====================================================================
-- Modellschicht der Live-Kette: die Begriffe aus Teil C als Sichten
-- Stand 10.09.2026, Arbeitspaket 5; Sicht uebergabe ergaenzt am 10.09.2026
-- abends (Nachtrag, Ergebnis 6 aus dem Folgeprompt)
--
-- Die Rohtabellen in public bleiben, wie sie sind: rohereignisse,
-- klickouts, postbacks, dazu der Katalog. Dieses Skript legt daneben das
-- Schema modell an, mit einer Sicht je Entitaet aus Teil C Abschnitt 5:
--   besuch, besuch_angemeldet, ereignis, auslieferung, klick_out, transaktion,
--   uebergabe
-- Dazu zwei Hilfen, die mehrere Sichten brauchen (angebot_katalog,
-- mediacode_bereich) und die Stammdaten der zwei Mandanten.
--
-- Warum ein eigenes Schema: Rohzeilen und Modell sollen getrennt bleiben,
-- und Rechte lassen sich je Schema vergeben. Das Schema modell ist nicht
-- ueber die Schnittstelle von Supabase freigegeben; wer von aussen etwas
-- daraus braucht, bekommt eine einzelne Funktion in public, die nur der
-- Dienstschluessel ausfuehren darf (siehe kennzahlen.sql).
--
-- Jede Sicht rechnet bei jeder Abfrage neu. Bei ein paar tausend Zeilen ist
-- das richtig so; eine materialisierte Sicht waere eine zweite Wahrheit, die
-- veralten kann, ohne dass es jemand merkt.
--
-- Ausfuehren im Supabase-SQL-Editor nach schema.sql, schema-katalog.sql und
-- schema-klickout.sql. Mehrfach ausfuehrbar.
-- =====================================================================

create schema if not exists modell;
comment on schema modell is
    'Modellschicht der Live-Kette: Sichten mit den Begriffen aus Teil C ueber den Rohtabellen in public, dazu die Kennzahltabelle. Nicht ueber die Schnittstelle freigegeben.';

revoke all on schema modell from public, anon, authenticated;
grant usage on schema modell to service_role;


-- ---------------------------------------------------------------------
-- 1. Stammdaten der Mandanten
-- Dieselben Werte wie MANDANTEN in index.html. Der Arbeitgeber-Report
-- braucht Reporting-Stufe und Betriebsvereinbarung, die Aktivierungsquote
-- braeuchte die Belegschaft. Im Betrieb kaemen die Zeilen aus dem
-- Portalsystem und Salesforce; hier stehen sie einmal von Hand.
-- ---------------------------------------------------------------------

create table if not exists modell.mandant (
    mandant                 text primary key,
    name                    text    not null,
    branche                 text,
    belegschaft             integer,
    belegschaft_stand       date,
    reporting_stufe         integer not null check (reporting_stufe between 1 and 3),
    betriebsvereinbarung    boolean not null,
    klick_schluessel_stufe  integer not null check (klick_schluessel_stufe in (1, 2)),
    standorte               text[]
);

comment on table modell.mandant is
    'Stammdaten der Mandanten wie MANDANTEN in index.html. Reporting-Stufe und Betriebsvereinbarung steuern, welche Stufe der Arbeitgeber-Report ausliefert.';

insert into modell.mandant values
    ('musterwerk', 'Musterwerk AG',   'Maschinenbau', 1840, '2026-06-30', 3, true,  2, array['Werk Nord', 'Verwaltung Süd']),
    ('nordkontor', 'Nordkontor GmbH', 'Handel',        610, '2026-08-31', 2, false, 1, array['Kontor Hafen', 'Kontor Ost'])
on conflict (mandant) do update set
    name = excluded.name, branche = excluded.branche, belegschaft = excluded.belegschaft,
    belegschaft_stand = excluded.belegschaft_stand, reporting_stufe = excluded.reporting_stufe,
    betriebsvereinbarung = excluded.betriebsvereinbarung,
    klick_schluessel_stufe = excluded.klick_schluessel_stufe, standorte = excluded.standorte;

alter table modell.mandant enable row level security;


-- ---------------------------------------------------------------------
-- 2. Hilfen
-- ---------------------------------------------------------------------

-- Partnerart je Angebot. Die Regel ist dieselbe wie in
-- public.klickout_trichter, in der Edge Function klickout, in der Seite und
-- in klickout_seed.py; sie wird hier nicht geaendert, nur einmal fuer alle
-- Sichten dieses Schemas hingeschrieben.
create or replace view modell.angebot_katalog as
select a.angebot_id,
       a.titel,
       a.kategorie,
       a.unterkategorie,
       a.anbieter_id,
       b.name                       as anbieter_name,
       a.typ,
       b.rueckkanal,
       case when b.rueckkanal = 'keiner' then 'ohne'
            when a.typ = 'Code' or b.rueckkanal = 'Code' then 'gutschein'
            else 'deeplink' end     as partnerart,
       a.rabatt_prozent,
       a.ersparnis_euro
  from public.angebote a
  left join public.anbieter b on b.anbieter_id = a.anbieter_id;

comment on view modell.angebot_katalog is
    'Angebot mit Anbieter, Rueckkanal und Partnerart nach der Regel aus schema-klickout.sql (keiner heisst ohne, Code heisst gutschein, sonst deeplink).';

-- Bereich eines Mediacodes nach der Werteliste UTM_MEDIUM der Seite:
-- A Kampagnen des Hauses, B Kanaele des Arbeitgebers, C Kanaele der
-- Anbieter, Auffang fuer auffang.unbekannt, ungueltig fuer alles andere.
-- Aendert sich die Werteliste in index.html, aendert sie sich hier.
create or replace function modell.mediacode_bereich(p_mediacode text)
returns text
language sql
immutable
as $$
    select case
        when p_mediacode is null or p_mediacode = '' then null
        when p_mediacode = 'auffang.unbekannt' then 'Auffang'
        when split_part(p_mediacode, '.', 1) in ('cpc', 'display', 'paidsocial', 'social', 'email', 'referral',
                                                  'affiliate', 'event', 'webinar', 'print') then 'A'
        when split_part(p_mediacode, '.', 1) in ('hr-email', 'intranet', 'print-qr', 'onboarding', 'messenger',
                                                  'event-intern', 'push') then 'B'
        when split_part(p_mediacode, '.', 1) in ('partner-email', 'partner-web', 'partner-social', 'deeplink') then 'C'
        else 'ungueltig'
    end;
$$;

comment on function modell.mediacode_bereich(text) is
    'Bereich A, B oder C nach dem ersten Teil des Mediacodes (Werteliste UTM_MEDIUM in index.html), Auffang fuer auffang.unbekannt, ungueltig fuer alles andere.';


-- ---------------------------------------------------------------------
-- 3. Ereignis
-- Die Rohzeile mit Namen aus Teil C: Besuch statt Sitzung, Ereignisart in
-- Punktnotation, dazu Kategorie und Partnerart aus dem Katalog. Suchbegriff
-- und userKey bleiben draussen; wer sie braucht, geht an die Rohzeile, und
-- das ist dann eine sichtbare Entscheidung.
-- ---------------------------------------------------------------------

create or replace view modell.ereignis as
select r.id                                   as ereignis_id,
       r.sitzung                              as besuch_id,
       r.quelle,
       r.empfangen_am                         as zeit,
       r.gesendet_am                          as zeit_browser,
       r.ereignis                             as ereignisart,
       split_part(r.ereignis, '.', 1)         as ereignisbereich,
       (r.ereignis like 'live.%' or r.ereignis like 'demo.%' or r.ereignis = '(unbekannt)') as technisch,
       r.seitenname,
       r.seitengruppe_1,
       r.seitengruppe_2,
       r.seitengruppe_3,
       r.seitengruppe_4,
       r.mandant,
       r.plattform,
       r.mediacode,
       r.variante,
       r.angebot,
       coalesce(r.anbieter, k.anbieter_id)    as anbieter,
       k.kategorie,
       k.partnerart,
       r.belegung,
       r.slot,
       r.position,
       r.klick_id,
       (r.user_key is not null)               as angemeldet,
       r.geraeteklasse,
       r.qualitaet
  from public.rohereignisse r
  left join modell.angebot_katalog k on k.angebot_id = r.angebot;

comment on view modell.ereignis is
    'Ereignis nach Teil C: je Rohzeile eine Zeile, Sitzung als Besuch, Ereignisart in Punktnotation, Kategorie und Partnerart aus dem Katalog; ohne Suchbegriff und ohne userKey.';


-- ---------------------------------------------------------------------
-- 4. Besuch
-- Ein Besuch ist eine Seitenladung der Modellseite, samt der Zwischenseite,
-- die dieselbe Kennung ueber die Adresse mitbekommt. Die Seite speichert
-- nichts auf dem Geraet und erkennt deshalb niemanden wieder; ein Neuladen
-- ist ein neuer Besuch. So steht es in Teil G, und so bleibt es hier.
-- ---------------------------------------------------------------------

create or replace view modell.besuch as
select r.sitzung                                                                              as besuch_id,
       r.quelle,
       (array_agg(r.mandant   order by r.empfangen_am, r.id) filter (where r.mandant   is not null))[1] as mandant,
       (array_agg(r.plattform order by r.empfangen_am, r.id) filter (where r.plattform is not null))[1] as plattform,
       (array_agg(r.mediacode order by r.empfangen_am, r.id) filter (where r.mediacode is not null))[1] as einstiegs_mediacode,
       modell.mediacode_bereich(
           (array_agg(r.mediacode order by r.empfangen_am, r.id) filter (where r.mediacode is not null))[1]) as einstiegs_bereich,
       min(r.empfangen_am)                                                                    as erste_zeit,
       max(r.empfangen_am)                                                                    as letzte_zeit,
       count(*)                                                                               as ereignisse,
       count(*) filter (where r.ereignis = 'offer.detail.open')                               as angebotsansichten,
       count(distinct r.klick_id) filter (where r.ereignis in ('offer.clickout', 'offer.code.show')) as klick_outs,
       bool_or(r.user_key is not null)                                                        as angemeldet,
       bool_and(r.ereignis like 'live.%' or r.ereignis like 'demo.%' or r.ereignis = '(unbekannt)') as technisch,
       count(*) filter (where r.qualitaet <> 'ok')                                            as auffaellige_ereignisse
  from public.rohereignisse r
 group by r.sitzung, r.quelle;

comment on view modell.besuch is
    'Besuch nach Teil C: eine Seitenladung (Sitzungskennung ohne Speicher), mit Mandant, Plattform und Einstiegs-Mediacode des ersten Ereignisses, erster und letzter Zeit und Zahl der Ereignisse. technisch heisst: nur Pruef- und Schalterereignisse.';


-- ---------------------------------------------------------------------
-- 5. Besuch, angemeldet und verkettet
-- Nur fuer Zeilen mit userKey. Seitenladungen desselben userKey, zwischen
-- denen weniger als 30 Minuten liegen, werden zu einem Besuch verkettet;
-- dieselbe Luecke wie die Sessionisierung in SQL-Rohdaten/abfragen.sql.
-- Gemessen wird die Luecke gegen das bisher spaeteste Ende der Kette, damit
-- zwei offene Reiter nicht als zwei Besuche zaehlen. Was vor der Anmeldung
-- in derselben Seitenladung geschah, bleibt im einfachen Besuch und kommt
-- hier nicht vor: ohne userKey gibt es nichts zu verketten.
-- ---------------------------------------------------------------------

create or replace view modell.besuch_angemeldet as
with seitenladung as (
    select r.quelle,
           r.user_key,
           r.sitzung,
           min(r.empfangen_am) as erste_zeit,
           max(r.empfangen_am) as letzte_zeit,
           count(*)            as ereignisse,
           (array_agg(r.mandant   order by r.empfangen_am, r.id) filter (where r.mandant   is not null))[1] as mandant,
           (array_agg(r.plattform order by r.empfangen_am, r.id) filter (where r.plattform is not null))[1] as plattform,
           (array_agg(r.mediacode order by r.empfangen_am, r.id) filter (where r.mediacode is not null))[1] as mediacode
      from public.rohereignisse r
     where r.user_key is not null
     group by r.quelle, r.user_key, r.sitzung
),
luecke as (
    select s.*,
           max(s.letzte_zeit) over (partition by s.quelle, s.user_key order by s.erste_zeit, s.sitzung
                                    rows between unbounded preceding and 1 preceding) as bisheriges_ende
      from seitenladung s
),
kette as (
    select l.*,
           sum(case when l.bisheriges_ende is null
                      or l.erste_zeit - l.bisheriges_ende >= interval '30 minutes' then 1 else 0 end)
               over (partition by l.quelle, l.user_key order by l.erste_zeit, l.sitzung) as kette_nr
      from luecke l
)
select k.user_key || ':' || k.kette_nr                                               as besuch_id,
       k.quelle,
       k.user_key,
       (array_agg(k.mandant   order by k.erste_zeit) filter (where k.mandant   is not null))[1] as mandant,
       (array_agg(k.plattform order by k.erste_zeit) filter (where k.plattform is not null))[1] as plattform,
       (array_agg(k.mediacode order by k.erste_zeit) filter (where k.mediacode is not null))[1] as einstiegs_mediacode,
       min(k.erste_zeit)                                                            as erste_zeit,
       max(k.letzte_zeit)                                                           as letzte_zeit,
       sum(k.ereignisse)::bigint                                                    as ereignisse,
       count(*)                                                                     as seitenladungen,
       array_agg(k.sitzung order by k.erste_zeit)                                   as sitzungen
  from kette k
 group by k.quelle, k.user_key, k.kette_nr;

comment on view modell.besuch_angemeldet is
    'Besuch fuer angemeldete Zeilen: Seitenladungen desselben userKey mit weniger als 30 Minuten Luecke zu einem Besuch verkettet, mit Mandant, Plattform, Einstiegs-Mediacode, erster und letzter Zeit, Zahl der Ereignisse und der verketteten Sitzungen.';


-- ---------------------------------------------------------------------
-- 6. Auslieferung und Teaser-Klick
-- Aus teaser.render, teaser.visible und teaser.click: eine Zeile je Besuch,
-- Belegung und Position. Kehrt jemand in derselben Seitenladung zur
-- Startseite zurueck, wird der Teaser erneut gerendert; das bleibt eine
-- Auslieferung, und die Zahl der Renderings steht daneben.
-- ---------------------------------------------------------------------

create or replace view modell.auslieferung as
select r.sitzung                                                          as besuch_id,
       r.quelle,
       r.belegung,
       r.position,
       max(r.slot)                                                        as slot,
       max(r.parameter->>'platzierung')                                   as platzierung,
       max(r.mandant)                                                     as mandant,
       max(r.angebot)                                                     as angebot,
       max(r.anbieter)                                                    as anbieter,
       min(r.empfangen_am) filter (where r.ereignis = 'teaser.render')    as ausgeliefert_am,
       min(r.empfangen_am)                                                as erste_zeit,
       count(*) filter (where r.ereignis = 'teaser.render')               as renderings,
       bool_or(r.ereignis = 'teaser.visible')                             as sichtbar,
       bool_or(r.ereignis = 'teaser.click')                               as geklickt,
       count(*) filter (where r.ereignis = 'teaser.click')                as klicks
  from public.rohereignisse r
 where r.ereignis in ('teaser.render', 'teaser.visible', 'teaser.click')
   and r.belegung is not null
 group by r.sitzung, r.quelle, r.belegung, r.position;

comment on view modell.auslieferung is
    'Auslieferung und Teaser-Klick nach Teil C: je Besuch, Belegung und Position, ob der Teaser gerendert, sichtbar (mindestens 50 Prozent im Fenster) und geklickt wurde.';


-- ---------------------------------------------------------------------
-- 7. Klick-out
-- Je Klick-ID eine Zeile, aus zwei Wahrheiten zusammengesetzt: was der
-- Browser gesehen hat (offer.clickout oder offer.code.show, dazu
-- redirect.write mit Ergebnis und gemessener Dauer) und was der Endpunkt in
-- klickouts geschrieben hat. Eine Klick-ID, die nur der Browser kennt,
-- steht hier mit zeile_da falsch; das ist der Serverfehler. Eine, die nur
-- der Partner kennt, steht hier nicht, weil niemand im Portal den Klick
-- gesehen hat; sie erscheint in modell.transaktion.
-- ---------------------------------------------------------------------

create or replace view modell.klick_out as
with browser as (
    select r.klick_id,
           min(r.quelle)                                                                          as quelle,
           min(r.empfangen_am) filter (where r.ereignis in ('offer.clickout', 'offer.code.show'))  as klick_zeit,
           bool_or(r.ereignis in ('offer.clickout', 'offer.code.show'))                           as sah_klick,
           (array_agg(r.sitzung   order by r.empfangen_am) filter (where r.sitzung   is not null))[1] as besuch_id,
           (array_agg(r.mandant   order by r.empfangen_am) filter (where r.mandant   is not null))[1] as mandant,
           (array_agg(r.angebot   order by r.empfangen_am) filter (where r.angebot   is not null))[1] as angebot,
           (array_agg(r.anbieter  order by r.empfangen_am) filter (where r.anbieter  is not null))[1] as anbieter,
           (array_agg(r.belegung  order by r.empfangen_am) filter (where r.belegung  is not null))[1] as belegung,
           (array_agg(r.mediacode order by r.empfangen_am) filter (where r.mediacode is not null))[1] as mediacode,
           (array_agg(r.plattform order by r.empfangen_am) filter (where r.plattform is not null))[1] as plattform,
           (array_agg(r.user_key  order by r.empfangen_am) filter (where r.user_key  is not null))[1] as user_key,
           (array_agg(r.parameter->>'fall' order by r.empfangen_am)
                filter (where r.parameter ? 'fall'))[1]                                            as fall,
           (array_agg(r.parameter->>'ergebnis' order by r.empfangen_am)
                filter (where r.ereignis = 'redirect.write'))[1]                                   as ergebnis,
           (array_agg(r.parameter->>'dauer_ms' order by r.empfangen_am)
                filter (where r.ereignis = 'redirect.write'))[1]                                   as dauer_ms
      from public.rohereignisse r
     where r.klick_id is not null
       and r.ereignis in ('offer.clickout', 'offer.code.show', 'redirect.write')
     group by r.klick_id
),
landung as (
    select p.klick_id, min(p.empfangen_am) as gelandet_am
      from public.postbacks p
     where p.art = 'landung' and p.klick_id is not null
     group by p.klick_id
),
ids as (
    select klick_id from browser where sah_klick
    union
    select klick_id from public.klickouts
)
select ids.klick_id,
       coalesce(k.quelle, b.quelle)                                  as quelle,
       coalesce(k.erzeugt_am, b.klick_zeit, k.geschrieben_am)        as zeit,
       coalesce(k.mandant, b.mandant)                                as mandant,
       coalesce(k.angebot, b.angebot)                                as angebot,
       coalesce(k.anbieter, b.anbieter, kat.anbieter_id)             as anbieter,
       kat.kategorie,
       coalesce(k.belegung, b.belegung)                              as belegung,
       coalesce(k.partner, kat.partnerart, 'unbekannt')              as partnerart,
       coalesce(k.fall, b.fall, 'keiner')                            as fehlerfall,
       k.antwort_ms                                                  as antwortzeit_server_ms,
       case when b.dauer_ms ~ '^[0-9]+$' then b.dauer_ms::integer end as antwortzeit_browser_ms,
       b.ergebnis                                                    as schreiben_laut_browser,
       coalesce(b.sah_klick, false)                                  as browser_sah_klick,
       (k.klick_id is not null)                                      as zeile_da,
       k.geschrieben_am,
       coalesce(k.angekommen_am, l.gelandet_am)                      as angekommen_am,
       coalesce(k.sitzung, b.besuch_id)                              as besuch_id,
       coalesce(k.mediacode, b.mediacode)                            as mediacode,
       coalesce(b.plattform, k.parameter->>'plattform', 'web')       as plattform,
       coalesce(k.user_key, b.user_key)                              as user_key,
       k.code,
       case
         when k.klick_id is not null and coalesce(k.angekommen_am, l.gelandet_am) is not null then 'beide Seiten'
         when k.klick_id is not null                                                          then 'nur Tabelle'
         when l.gelandet_am is not null                                                       then 'nur Partner'
         else 'keine Seite'
       end                                                           as befund
  from ids
  left join public.klickouts k       on k.klick_id = ids.klick_id
  left join browser b                on b.klick_id = ids.klick_id
  left join landung l                on l.klick_id = ids.klick_id
  left join modell.angebot_katalog kat on kat.angebot_id = coalesce(k.angebot, b.angebot);

comment on view modell.klick_out is
    'Klick-out nach Teil C: je Klick-ID, die der Browser sah oder der Endpunkt schrieb, Zeit, Mandant, Angebot, Anbieter, Belegung, Partnerart, Fehlerfall, Antwortzeit, ob der Browser den Klick sah, ob die Zeile in klickouts steht, und der Befund wie in klickout_wahrheiten.';


-- ---------------------------------------------------------------------
-- 8. Transaktion
-- Je Bestellung oder Code-Einloesung eine Zeile, gleich wie oft und auf
-- welchem Weg sie gemeldet wurde (Pixel, Server, Storno, Freigabe). Der
-- Status ist ein Verlauf, hier als sein letzter Stand:
--   storniert   eine Storno-Meldung liegt vor
--   bestaetigt  eine Freigabe liegt vor (freigabe_am): beim Deeplink die
--               Server-Meldung mit Status bestaetigt, die nach 14 Tagen
--               kommt; beim Code die Monatsabrechnung des Partners, weil der
--               Partner Codes nur abrechnet und keine eigene Freigabe schickt
--   offen       sonst
-- Eine Code-Einloesung hat keine Klick-ID. Sie bekommt die Zahl der
-- Klick-outs mit demselben Code als kandidaten (Abfrage 6 in
-- abfragen-klickout.sql), nicht einen davon. Den Mandanten und das Angebot
-- bekommt sie nur, wenn alle Kandidaten dieselben haben; der Code haengt an
-- Belegung, Monat und Mandant, deshalb ist das der Normalfall.
-- ---------------------------------------------------------------------

create or replace view modell.transaktion as
with meldung as (
    select p.*,
           coalesce(p.klick_id, p.code, '')           as schluessel,
           coalesce(p.bestellnummer, 'id-' || p.id)   as nummer
      from public.postbacks p
     where p.art in ('bestellung', 'storno', 'code_einloesung')
),
t as (
    select m.quelle,
           m.schluessel,
           m.nummer,
           case when bool_or(m.art = 'code_einloesung') then 'code_einloesung' else 'bestellung' end as art,
           max(m.klick_id)                                                          as klick_id,
           max(m.code)                                                              as code,
           max(m.partner)                                                           as partner,
           max(m.bestellwert)                                                       as bestellwert,
           min(coalesce(m.bestellt_am, m.empfangen_am)) filter (where m.art <> 'storno') as bestellt_am,
           min(m.empfangen_am)                                                      as erste_meldung_am,
           max(m.empfangen_am)                                                      as letzte_meldung_am,
           min(coalesce(m.gemeldet_am, m.empfangen_am)) filter (where m.art = 'code_einloesung') as abgerechnet_am,
           min(m.empfangen_am) filter (where m.status in ('bestaetigt', 'bestätigt')) as freigabe_meldung_am,
           min(m.empfangen_am) filter (where m.art = 'storno' or m.status = 'storniert') as storniert_am,
           bool_or(m.weg = 'pixel')                                                 as per_pixel,
           bool_or(m.weg = 's2s')                                                   as per_server,
           count(*)                                                                 as meldungen
      from meldung m
     group by m.quelle, m.schluessel, m.nummer
),
kandidat as (
    select k.code,
           count(*)                   as kandidaten,
           count(distinct k.mandant)  as mandanten,
           min(k.mandant)             as mandant,
           count(distinct k.angebot)  as angebote,
           min(k.angebot)             as angebot
      from public.klickouts k
     where k.code is not null
     group by k.code
),
z as (
    select t.*,
           case when t.art = 'code_einloesung' then t.abgerechnet_am else t.freigabe_meldung_am end as freigabe_am,
           ko.klick_id is not null                                                                  as klick_im_modell,
           ko.zeile_da, ko.browser_sah_klick,
           kd.kandidaten,
           case when t.art = 'code_einloesung' then case when kd.mandanten = 1 then kd.mandant end
                else ko.mandant end                                                                 as mandant,
           case when t.art = 'code_einloesung' then case when kd.angebote = 1 then kd.angebot end
                else ko.angebot end                                                                 as angebot,
           ko.besuch_id,
           ko.user_key
      from t
      left join modell.klick_out ko on ko.klick_id = t.klick_id
      left join kandidat kd         on kd.code = t.code and t.art = 'code_einloesung'
)
select md5(z.quelle || '|' || z.art || '|' || z.schluessel || '|' || z.nummer)   as transaktion_id,
       z.quelle,
       z.art,
       z.klick_id,
       z.code,
       z.nummer                                                                  as bestellnummer,
       z.partner                                                                 as partnerart,
       z.mandant,
       z.angebot,
       kat.kategorie,
       kat.anbieter_id                                                           as anbieter,
       z.bestellwert,
       case when z.bestellwert is null then null
            when kat.rabatt_prozent > 0 and kat.rabatt_prozent < 90
                 then round(z.bestellwert * kat.rabatt_prozent / (100 - kat.rabatt_prozent), 2)
            else kat.ersparnis_euro end                                          as ersparnis_euro,
       z.bestellt_am,
       case when z.art = 'bestellung' then z.bestellt_am + interval '14 days' end as freigabe_erwartet_am,
       z.freigabe_am,
       z.storniert_am,
       case when z.storniert_am is not null then 'storniert'
            when z.freigabe_am  is not null then 'bestaetigt'
            else 'offen' end                                                     as status,
       z.per_pixel,
       z.per_server,
       z.meldungen,
       z.kandidaten,
       case when z.art = 'code_einloesung' then 'code'
            when z.klick_im_modell then 'klick_id'
            else 'keine' end                                                     as zuordnung,
       z.zeile_da                                                                as klick_in_tabelle,
       z.browser_sah_klick,
       z.besuch_id,
       z.user_key,
       z.erste_meldung_am,
       z.letzte_meldung_am
  from z
  left join modell.angebot_katalog kat on kat.angebot_id = z.angebot;

comment on view modell.transaktion is
    'Transaktion nach Teil C: je Bestellung oder Code-Einloesung eine Zeile mit Status offen, bestaetigt, storniert nach freigabe_am (Server-Freigabe, beim Code die Monatsabrechnung); Code-Einloesungen tragen die Zahl der Kandidaten-Klicks, keine Zuordnung zu einem Klick.';


-- ---------------------------------------------------------------------
-- 8b. Uebergabe (Nachtrag, Ergebnis 6)
-- Der Sprung aus der App in die Webansicht, Teil C und synthetischer
-- Datensatz (Entitaet uebergabe). Die Seite sieht davon nur ihre Haelfte:
-- das Ereignis app.uebergabe, das der Einstieg index.html?von=app
-- &uebergabe=<Kennung>&login=ja|nein erzeugt. Die App-Seite fehlt, weil es
-- keinen App-Simulator gibt; die Kennung ist das Stueck, das beide Seiten
-- verbinden wuerde.
--
-- Je Kennung eine Zeile. Kommt dieselbe Kennung zweimal (geteilter Link,
-- Neuladen vor dem Entfernen aus der Adresse), zaehlt die erste
-- Seitenladung, und seitenladungen sagt, wie oft. Fehlt die Kennung, wird die
-- Seitenladung selbst zum Schluessel.
--
-- zusammenhang_verloren heisst: das Ereignis kam ohne userKey an. Dann ist der
-- Web-Besuch ein neuer anonymer Besuch ohne Vorgaenger, und nichts in den
-- Rohzeilen verbindet ihn mit dem Konto, das die App kannte. Meldet sich
-- jemand in derselben Seitenladung spaeter selbst an, steht das in
-- spaeter_angemeldet: der Zusammenhang ist dann ueber den userKey
-- wiederhergestellt, aber um den Preis einer zweiten Anmeldung.
-- abweichung markiert Zeilen, bei denen die App login=ja sagt und die
-- Webansicht trotzdem abgemeldet ankam, etwa bei einem abgelaufenen Token.
-- ---------------------------------------------------------------------

create or replace view modell.uebergabe as
with ereignis as (
    select r.id, r.quelle, r.sitzung, r.empfangen_am, r.mandant, r.plattform, r.seitenname,
           (r.user_key is not null)                                        as angemeldet,
           nullif(r.parameter->>'uebergabe', '')                           as kennung,
           coalesce(nullif(r.parameter->>'login_mitgenommen', ''), 'unbekannt') as login_mitgenommen
      from public.rohereignisse r
     where r.ereignis = 'app.uebergabe'
),
je_kennung as (
    select e.quelle,
           coalesce(e.kennung, 'ohne-kennung:' || e.sitzung)                        as uebergabe_id,
           bool_and(e.kennung is null)                                              as kennung_fehlt,
           min(e.empfangen_am)                                                      as zeit,
           (array_agg(e.sitzung            order by e.empfangen_am, e.id))[1]       as besuch_id,
           (array_agg(e.mandant            order by e.empfangen_am, e.id))[1]       as mandant,
           (array_agg(e.plattform          order by e.empfangen_am, e.id))[1]       as plattform,
           (array_agg(e.seitenname         order by e.empfangen_am, e.id))[1]       as landeseite,
           (array_agg(e.login_mitgenommen  order by e.empfangen_am, e.id))[1]       as login_mitgenommen,
           (array_agg(e.angemeldet         order by e.empfangen_am, e.id))[1]       as angemeldet_bei_ankunft,
           count(distinct e.sitzung)                                                as seitenladungen
      from ereignis e
     group by 1, 2
),
besuch as (
    select r.quelle, r.sitzung,
           bool_or(r.user_key is not null)                                              as im_besuch_angemeldet,
           count(*) filter (where r.ereignis = 'offer.detail.open')                     as angebotsansichten,
           count(distinct r.klick_id) filter (where r.ereignis in ('offer.clickout', 'offer.code.show')) as klick_outs,
           max(r.empfangen_am)                                                          as letzte_zeit
      from public.rohereignisse r
     where r.sitzung in (select besuch_id from je_kennung)
     group by 1, 2
)
select u.uebergabe_id,
       u.quelle,
       u.zeit,
       u.besuch_id,
       u.mandant,
       'app'::text                                                           as von,
       coalesce(u.plattform, 'web')                                          as nach,
       u.landeseite,
       u.login_mitgenommen,
       u.angemeldet_bei_ankunft,
       not u.angemeldet_bei_ankunft                                          as zusammenhang_verloren,
       (not u.angemeldet_bei_ankunft and coalesce(b.im_besuch_angemeldet, false)) as spaeter_angemeldet,
       (u.login_mitgenommen = 'ja' and not u.angemeldet_bei_ankunft)
         or (u.login_mitgenommen = 'nein' and u.angemeldet_bei_ankunft)     as abweichung,
       u.kennung_fehlt,
       u.seitenladungen,
       coalesce(b.angebotsansichten, 0)                                      as angebotsansichten,
       coalesce(b.klick_outs, 0)                                             as klick_outs,
       b.letzte_zeit
  from je_kennung u
  left join besuch b on b.quelle = u.quelle and b.sitzung = u.besuch_id;

comment on view modell.uebergabe is
    'Uebergabe nach Teil C: je Kennung aus app.uebergabe der Sprung aus der App in die Webansicht, mit login_mitgenommen laut Adresse, angemeldet bei Ankunft laut Rohzeile, zusammenhang_verloren (ohne userKey angekommen) und was im Web-Besuch danach geschah. Nur die Web-Haelfte; die App-Seite gibt es in der Live-Kette nicht.';

-- ---------------------------------------------------------------------
-- 9. Rechte
-- Wie bei den Rohtabellen: RLS an den Tabellen, nichts fuer anon und
-- authenticated. Das Dashboard liest ueber den Session Pooler als
-- Eigentuemer, genau wie live_ereignisse_stunde. Die Funktion ist
-- unkritisch, bekommt aber trotzdem kein Recht fuer PUBLIC.
-- ---------------------------------------------------------------------

revoke all on all tables in schema modell from public, anon, authenticated;
revoke all on function modell.mediacode_bereich(text) from public, anon, authenticated;
grant select on all tables in schema modell to service_role;
grant execute on function modell.mediacode_bereich(text) to service_role;
