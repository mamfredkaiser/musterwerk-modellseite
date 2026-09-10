-- =====================================================================
-- Live-Kette Musterwerk Vorteilsportal: Klick-out-Strecke
-- Stand 10.09.2026, Arbeitspaket 4
--
-- Drei Tabellen fuer drei Wahrheiten:
--   klickouts          was der eigene Weiterleitungs-Endpunkt geschrieben hat
--   postbacks          was vom Partner zurueckkam (Pixel im Browser oder Server)
--   webtrekk_requests  derselbe Messpunkt im Webtrekk-Format, positionsweise zerlegt
-- Die vierte Wahrheit, die des Browsers auf der Zwischenseite, steht in
-- rohereignisse (Messpunkte redirect.*). Der Trichter am Ende dieser Datei
-- legt die vier nebeneinander.
--
-- Ausfuehren im Supabase-SQL-Editor des Projekts zdiivmckxenneeyvtldg,
-- nach schema.sql und schema-katalog.sql. Mehrfach ausfuehrbar.
-- =====================================================================

-- ---------------------------------------------------------------------
-- 1. klickouts: die Zuordnungstabelle, serverseitig geschrieben
-- Eine Zeile je Klick-ID. Sie entsteht auf der Zwischenseite weiter.html
-- ueber die Edge Function klickout, bevor der Browser weitergeleitet wird.
-- Ob der Nutzer beim Partner ankam, traegt spaeter der Landungs-Pixel in
-- angekommen_am nach. Fehlt der Wert, ist die Klick-ID auf einer Seite
-- allein: das ist die Verlustquelle, um die es geht.
-- ---------------------------------------------------------------------

create table if not exists public.klickouts (
    id                bigint generated always as identity primary key,
    klick_id          text         not null unique,
    geschrieben_am    timestamptz  not null default now(),   -- Uhr des Servers
    erzeugt_am        timestamptz,                           -- Uhr des Browsers, Parameter ts
    antwort_ms        integer,                               -- wie lange der Server gebraucht hat
    quelle            text         not null default 'live',  -- live oder synthetisch
    mandant           text,
    angebot           text,
    anbieter          text,
    typ               text,        -- Deeplink oder Code, aus dem Katalog
    rueckkanal        text,        -- Netzwerk, Direkt, Code, keiner, aus dem Katalog
    partner           text,        -- deeplink, gutschein oder ohne: welche Partnerseite das Ziel ist
    ziel              text,        -- die Adresse, an die weitergeleitet wurde
    belegung          text,
    code              text,        -- Gutscheincode je Belegung und Monat, nur bei Code-Angeboten
    mediacode         text,
    strecke           text,        -- Suchstrecke, wenn der Klick aus der Suche kam
    sitzung           text,        -- Sitzungskennung der Modellseite, per Adresse uebergeben
    user_key          text,        -- nur Mandanten der Klick-Schluessel-Stufe zwei, nur angemeldet
    fall              text         not null default 'keiner', -- keiner, langsam, fehler, abbruch
    geraeteklasse     text,
    angekommen_am     timestamptz,                           -- erster Landungs-Pixel des Partners
    parameter         jsonb        not null default '{}'::jsonb,
    qualitaet         text         not null default 'ok'
);

comment on table public.klickouts is
    'Zuordnungstabelle der Klick-IDs, geschrieben vom eigenen Weiterleitungs-Endpunkt vor der Weiterleitung. Keine IP, kein User-Agent im Klartext. Aufbewahrung 30 Tage wie rohereignisse.';
comment on column public.klickouts.angekommen_am is
    'Zeitpunkt des ersten Landungs-Pixels beim Partner. NULL heisst: die Klick-ID wurde geschrieben, aber niemand ist angekommen, oder der Partner hat keinen Pixel.';
comment on column public.klickouts.fall is
    'Vorgefuehrter Fehlerfall der Zwischenseite: keiner, langsam (Server wartet sieben Sekunden), fehler (Server antwortet 500 und schreibt nichts, diese Zeile kann es dann nicht geben), abbruch (Browser bricht nach 250 ms ab, der Server schreibt trotzdem).';
comment on column public.klickouts.quelle is
    'live fuer echte Klicks der Modellseite, synthetisch fuer den Seed aus klickout_seed.py. Der Trichter unterscheidet beides.';

create index if not exists klickouts_geschrieben_idx on public.klickouts (geschrieben_am desc);
create index if not exists klickouts_angebot_idx     on public.klickouts (angebot);
create index if not exists klickouts_code_idx        on public.klickouts (code) where code is not null;
create index if not exists klickouts_sitzung_idx     on public.klickouts (sitzung);

-- ---------------------------------------------------------------------
-- 2. postbacks: der Rueckkanal
-- Alles, was von einer Partnerseite zurueckkommt, gleich auf welchem Weg.
-- art: landung (der Pixel beim Ankommen), bestellung, storno,
--      code_einloesung (Meldung ueber den Gutscheincode, ohne Klick-ID)
-- weg: pixel (Bild im Browser des Nutzers) oder s2s (vom Server des Partners)
-- Eine Meldung mit unbekannter Klick-ID wird geschrieben und markiert,
-- nicht verworfen: sie ist der Beleg dafuer, dass der Weiterleitungs-
-- Endpunkt eine Zeile nicht geschrieben hat.
-- ---------------------------------------------------------------------

create table if not exists public.postbacks (
    id                bigint generated always as identity primary key,
    empfangen_am      timestamptz  not null default now(),
    gemeldet_am       timestamptz,          -- Uhr des Partners; bei Code-Meldungen oft Wochen spaeter
    bestellt_am       timestamptz,          -- wann die Bestellung beim Partner stattfand
    quelle            text         not null default 'live',
    art               text         not null,   -- landung, bestellung, storno, code_einloesung
    weg               text         not null,   -- pixel oder s2s
    partner           text,                    -- deeplink, gutschein, ohne
    klick_id          text,                    -- NULL bei Meldungen ueber den Code
    code              text,
    bestellnummer     text,
    bestellwert       numeric(10,2),
    waehrung          text         default 'EUR',
    status            text,                    -- offen, bestaetigt, storniert
    klick_bekannt     boolean,                 -- gab es die Klick-ID in klickouts?
    geraeteklasse     text,
    parameter         jsonb        not null default '{}'::jsonb,
    qualitaet         text         not null default 'ok'
);

comment on table public.postbacks is
    'Rueckmeldungen der Partnerseiten: Landungs-Pixel, Bestellungen, Stornos, Code-Einloesungen. Pixel kommen aus dem Browser des Nutzers, s2s vom Server des Partners (hier: simuliert in derselben Edge Function unter dem Pfad /partnershop).';
comment on column public.postbacks.klick_bekannt is
    'Wahr, wenn zur Klick-ID beim Empfang eine Zeile in klickouts existierte. Falsch heisst: der Partner meldet einen Klick, den der eigene Endpunkt nie geschrieben hat.';

create index if not exists postbacks_empfangen_idx on public.postbacks (empfangen_am desc);
create index if not exists postbacks_klick_idx     on public.postbacks (klick_id) where klick_id is not null;
create index if not exists postbacks_code_idx      on public.postbacks (code) where code is not null;
create index if not exists postbacks_art_idx       on public.postbacks (art, empfangen_am desc);

-- ---------------------------------------------------------------------
-- 3. webtrekk_requests: der Request im Webtrekk-Format, zerlegt
-- Die Edge Function wtpixel nimmt GET .../wtpixel/<track-id>/wt?p=...
-- entgegen, trennt p an den Kommata und benennt die zehn Positionen
-- (docs.mapp.com/docs/request-structure, abgerufen 10.09.2026). Die
-- nummerierten Parameter cg, cp, cs, ck, cb, ca, cc, uc landen als
-- jsonb-Abbildungen, damit eine neue Nummer keine Migration braucht.
-- ---------------------------------------------------------------------

create table if not exists public.webtrekk_requests (
    id                  bigint generated always as identity primary key,
    empfangen_am        timestamptz  not null default now(),
    track_id            text,          -- aus dem Pfad, hier immer die erfundene
    methode             text,          -- GET (Bild oder fetch) oder POST (sendBeacon)
    -- die zehn Positionen des Parameters p
    version             text,          -- Position 1, 600 nach der Server-zu-Server-Doku
    seitenname          text,          -- Position 2, contentId
    javascript          text,          -- Position 3, 1 oder 0
    aufloesung          text,          -- Position 4, Breite x Hoehe
    farbtiefe           text,          -- Position 5, Bit
    cookies             text,          -- Position 6, 1 oder 0
    clientzeit          timestamptz,   -- Position 7, Millisekunden seit 1970, hier umgerechnet
    clientzeit_roh      text,          -- Position 7 wie empfangen, falls nicht lesbar
    referrer            text,          -- Position 8, URL-kodiert empfangen, hier dekodiert
    fenster             text,          -- Position 9, Groesse des Browserfensters
    java                text,          -- Position 10, 1 oder 0
    p_positionen        integer,       -- wie viele Positionen p tatsaechlich hatte
    -- benannte Parameter
    aktion              text,          -- ct, Name einer Aktion; NULL bei Seitenaufrufen
    kampagne            text,          -- mc, Form wt_mc=<mediacode>
    kampagnenaktion     text,          -- mca
    ever_id             text,          -- eid, 19 Stellen; hier nie gesetzt, weil anonym
    custom_ever_id      text,          -- ceid
    kunden_id           text,          -- cd
    anonym              text,          -- nc
    erster_request      text,          -- one
    neue_sitzung        text,          -- fns
    sprache             text,          -- la
    seiten_url          text,          -- pu
    zeitzone            text,          -- tz
    ende                text,          -- eor, in der Doku nicht belegt, deshalb nur abgelegt
    inhaltsgruppen      jsonb        not null default '{}'::jsonb,  -- cg1 bis cg499
    seitenparameter     jsonb        not null default '{}'::jsonb,  -- cp1 bis cp499
    sitzungsparameter   jsonb        not null default '{}'::jsonb,  -- cs1 bis cs499
    aktionsparameter    jsonb        not null default '{}'::jsonb,  -- ck1 bis ck499
    ecommerce           jsonb        not null default '{}'::jsonb,  -- ba, co, qn, st, oi, ov, cb, ca
    rest                jsonb        not null default '{}'::jsonb,  -- alles andere
    geraeteklasse       text,
    qualitaet           text         not null default 'ok'
);

comment on table public.webtrekk_requests is
    'Requests im Webtrekk-Format gegen den eigenen Sammler, positionsweise zerlegt. Kein echter Mapp-Zugang: die Track-ID ist erfunden, der Trackserver ist die Edge Function wtpixel.';

create index if not exists webtrekk_requests_empfangen_idx on public.webtrekk_requests (empfangen_am desc);
create index if not exists webtrekk_requests_aktion_idx    on public.webtrekk_requests (aktion, empfangen_am desc);

-- ---------------------------------------------------------------------
-- 4. Zeilenschutz und Rechte
-- Wie bei rohereignisse: RLS an, keine Richtlinie fuer anon und
-- authenticated, der Dienstschluessel schreibt. Und wieder die Zeilen,
-- ohne die PostgREST mit 42501 antwortet.
-- ---------------------------------------------------------------------

alter table public.klickouts         enable row level security;
alter table public.postbacks         enable row level security;
alter table public.webtrekk_requests enable row level security;

revoke all on table public.klickouts, public.postbacks, public.webtrekk_requests from anon, authenticated;

grant select, insert, update on table public.klickouts         to service_role;
grant select, insert         on table public.postbacks         to service_role;
grant select, insert         on table public.webtrekk_requests to service_role;
grant usage, select on sequence public.klickouts_id_seq         to service_role;
grant usage, select on sequence public.postbacks_id_seq         to service_role;
grant usage, select on sequence public.webtrekk_requests_id_seq to service_role;

-- ---------------------------------------------------------------------
-- 5. Aufraeumen
-- Dieselbe Frist wie rohereignisse. Die bestehende Funktion bleibt, wie
-- sie ist; diese hier raeumt die drei neuen Tabellen und laesst
-- synthetische Zeilen stehen, weil die kein Datum tragen, das altert.
-- ---------------------------------------------------------------------

create or replace function public.klickout_aufraeumen(
    p_tage integer default 30
) returns table (tabelle text, geloescht integer)
language plpgsql
security definer
set search_path = public
as $$
declare
    n integer;
begin
    delete from public.postbacks
     where empfangen_am < now() - make_interval(days => p_tage) and quelle = 'live';
    get diagnostics n = row_count;
    tabelle := 'postbacks'; geloescht := n; return next;

    delete from public.klickouts
     where geschrieben_am < now() - make_interval(days => p_tage) and quelle = 'live';
    get diagnostics n = row_count;
    tabelle := 'klickouts'; geloescht := n; return next;

    delete from public.webtrekk_requests
     where empfangen_am < now() - make_interval(days => p_tage);
    get diagnostics n = row_count;
    tabelle := 'webtrekk_requests'; geloescht := n; return next;
end;
$$;

revoke all on function public.klickout_aufraeumen(integer) from anon, authenticated;
grant execute on function public.klickout_aufraeumen(integer) to service_role;

-- ---------------------------------------------------------------------
-- 6. Der Trichter
-- Vier Wahrheiten je Partnerart, aus den Tabellen gelesen, nicht gepflegt:
--   browser_klicks   Messpunkte offer.clickout und offer.code.show in rohereignisse
--                    (die Seite hat den Klick gesehen)
--   tabelle          Zeilen in klickouts (der Endpunkt hat geschrieben)
--   angekommen       davon mit Landungs-Pixel (der Partner hat den Nutzer gesehen)
--   bestellungen     Postbacks der Art bestellung oder code_einloesung
--   verwaist         Postbacks mit einer Klick-ID, die klickouts nicht kennt
-- p_quelle: live, synthetisch oder alle. p_stunden begrenzt das Fenster,
-- NULL heisst ohne Grenze.
-- Der Browser-Zaehler kennt keine Partnerart, weil die Seite sie nicht
-- schickt; er wird ueber den Katalog (angebote, anbieter) zugeordnet.
-- ---------------------------------------------------------------------

create or replace function public.klickout_trichter(
    p_quelle  text    default 'live',
    p_stunden integer default null
) returns table (
    partner          text,
    browser_klicks   bigint,
    tabelle          bigint,
    angekommen       bigint,
    bestellungen     bigint,
    bestellwert      numeric,
    verwaist         bigint,
    luecke_tabelle   bigint,   -- Browser sah den Klick, Tabelle hat keine Zeile
    luecke_ankunft   bigint    -- Tabelle hat die Zeile, Partner sah niemanden
)
language sql
stable
security definer
set search_path = public
as $$
    with grenze as (
        select case when p_stunden is null then timestamptz '1970-01-01'
                    else now() - make_interval(hours => p_stunden) end as ab
    ),
    -- Partnerart je Angebot, dieselbe Regel wie in der Edge Function klickout
    art as (
        select a.angebot_id,
               case when b.rueckkanal = 'keiner' then 'ohne'
                    when a.typ = 'Code' or b.rueckkanal = 'Code' then 'gutschein'
                    else 'deeplink' end as partner
          from public.angebote a
          join public.anbieter b on b.anbieter_id = a.anbieter_id
    ),
    browser as (
        select coalesce(art.partner, 'unbekannt') as partner, count(*) as n
          from public.rohereignisse r
          left join art on art.angebot_id = r.angebot
         where r.ereignis in ('offer.clickout', 'offer.code.show')
           and r.empfangen_am >= (select ab from grenze)
           and (p_quelle = 'alle' or p_quelle = 'live')
         group by 1
    ),
    ko as (
        select coalesce(k.partner, 'unbekannt') as partner,
               count(*) as n,
               count(k.angekommen_am) as angekommen
          from public.klickouts k
         where k.geschrieben_am >= (select ab from grenze)
           and (p_quelle = 'alle' or k.quelle = p_quelle)
         group by 1
    ),
    -- Eine Bestellung kann zweimal gemeldet werden, einmal per Pixel und
    -- einmal vom Server. Gezaehlt wird sie einmal, ueber Klick-ID oder Code
    -- plus Bestellnummer; der Wert ist der hoechste gemeldete.
    bestellungen as (
        select coalesce(p.partner, 'unbekannt') as partner,
               coalesce(p.klick_id, p.code, '') as schluessel,
               coalesce(p.bestellnummer, p.id::text) as bestellnummer,
               max(p.bestellwert) as wert
          from public.postbacks p
         where p.art in ('bestellung', 'code_einloesung')
           and p.empfangen_am >= (select ab from grenze)
           and (p_quelle = 'alle' or p.quelle = p_quelle)
         group by 1, 2, 3
    ),
    pb as (
        select partner, count(*) as bestellungen, coalesce(sum(wert), 0) as bestellwert
          from bestellungen
         group by 1
    ),
    verwaist as (
        select coalesce(p.partner, 'unbekannt') as partner,
               count(distinct p.klick_id) as n
          from public.postbacks p
         where p.klick_id is not null and p.klick_bekannt = false
           and p.empfangen_am >= (select ab from grenze)
           and (p_quelle = 'alle' or p.quelle = p_quelle)
         group by 1
    ),
    alle as (
        select partner from browser
        union select partner from ko
        union select partner from pb
        union select partner from verwaist
    )
    select alle.partner,
           coalesce(browser.n, 0)          as browser_klicks,
           coalesce(ko.n, 0)               as tabelle,
           coalesce(ko.angekommen, 0)      as angekommen,
           coalesce(pb.bestellungen, 0)    as bestellungen,
           coalesce(pb.bestellwert, 0)     as bestellwert,
           coalesce(verwaist.n, 0)         as verwaist,
           greatest(coalesce(browser.n, 0) - coalesce(ko.n, 0), 0)      as luecke_tabelle,
           greatest(coalesce(ko.n, 0) - coalesce(ko.angekommen, 0), 0)  as luecke_ankunft
      from alle
      left join browser  on browser.partner  = alle.partner
      left join ko       on ko.partner       = alle.partner
      left join pb       on pb.partner       = alle.partner
      left join verwaist on verwaist.partner = alle.partner
     order by case alle.partner when 'deeplink' then 1 when 'gutschein' then 2 when 'ohne' then 3 else 4 end;
$$;

comment on function public.klickout_trichter is
    'Trichter je Partnerart aus rohereignisse, klickouts und postbacks. p_quelle live, synthetisch oder alle; p_stunden begrenzt das Fenster.';

revoke all on function public.klickout_trichter(text, integer) from anon, authenticated;
grant execute on function public.klickout_trichter(text, integer) to service_role;

-- ---------------------------------------------------------------------
-- 7. Die Fehlerfaelle je Klick-ID
-- Eine Zeile je Klick-ID mit den vier Wahrheiten nebeneinander. Das ist
-- die Tabelle, die man im Gespraech zeigt, nachdem man die drei
-- Fehlerfaelle durchgeklickt hat.
-- ---------------------------------------------------------------------

create or replace view public.klickout_wahrheiten as
with browser as (
    select klick_id,
           min(empfangen_am) filter (where ereignis in ('offer.clickout', 'offer.code.show')) as klick_gesehen,
           max(parameter->>'ergebnis') filter (where ereignis = 'redirect.write')            as schreiben_laut_browser,
           bool_or(ereignis = 'redirect.go')                                                    as weitergeleitet,
           max(parameter->>'bestaetigt') filter (where ereignis = 'redirect.go')              as weiter_mit_bestaetigung,
           bool_or(ereignis = 'redirect.cancel')                                                as abgebrochen
      from public.rohereignisse
     where klick_id is not null
     group by klick_id
),
partner as (
    select klick_id,
           min(empfangen_am) filter (where art = 'landung')                              as gelandet,
           count(distinct coalesce(bestellnummer, id::text)) filter (where art = 'bestellung') as bestellungen,
           max(bestellwert)  filter (where art = 'bestellung')                           as bestellwert,
           bool_or(art = 'storno')                                                       as storniert,
           bool_or(weg = 'pixel')                                                        as per_pixel,
           bool_or(weg = 's2s')                                                          as per_server
      from public.postbacks
     where klick_id is not null
     group by klick_id
),
ids as (
    select klick_id from browser
    union select klick_id from public.klickouts
    union select klick_id from partner
)
select ids.klick_id,
       k.fall,
       k.partner,
       k.angebot,
       b.klick_gesehen                                        as browser_klick,
       b.schreiben_laut_browser,
       b.weitergeleitet,
       b.weiter_mit_bestaetigung,
       b.abgebrochen,
       k.geschrieben_am                                       as tabelle_zeile,
       k.antwort_ms,
       p.gelandet                                             as partner_landung,
       p.bestellungen,
       p.bestellwert,
       p.storniert,
       p.per_pixel,
       p.per_server,
       case
         when k.klick_id is not null and p.gelandet is not null then 'beide Seiten'
         when k.klick_id is not null and p.gelandet is null     then 'nur Tabelle'
         when k.klick_id is null     and p.gelandet is not null then 'nur Partner'
         else 'keine Seite'
       end                                                    as befund
  from ids
  left join browser b          on b.klick_id = ids.klick_id
  left join public.klickouts k on k.klick_id = ids.klick_id
  left join partner p          on p.klick_id = ids.klick_id
 order by coalesce(k.geschrieben_am, b.klick_gesehen, p.gelandet) desc;

comment on view public.klickout_wahrheiten is
    'Je Klick-ID: was der Browser sah, was der Endpunkt schrieb, was der Partner meldete, und der Befund beide Seiten / nur Tabelle / nur Partner / keine Seite.';

revoke all on public.klickout_wahrheiten from anon, authenticated;
grant select on public.klickout_wahrheiten to service_role;
