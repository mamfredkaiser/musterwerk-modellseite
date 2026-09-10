-- =====================================================================
-- Modellschicht der Live-Kette: Kennzahltabelle und Arbeitgeber-Report
-- Stand 10.09.2026, Arbeitspaket 5; Kennzahl 13 (Uebergaben ohne Zusammenhang)
-- ergaenzt am 10.09.2026 abends (Nachtrag, Ergebnis 6 aus dem Folgeprompt)
--
-- modell.kennzahl traegt die zwoelf Kennzahlen aus Teil C Abschnitt 7 und
-- seit dem Nachtrag als dreizehnte den Anteil der Uebergaben aus der App,
-- die den Zusammenhang verlieren (Entitaet Uebergabe), je
-- Zeitraum (jeder Kalendermonat mit Daten und die letzten 30 Tage), je
-- Mandant (alle, musterwerk, nordkontor) und je Quelle (live und
-- synthetisch, getrennt gerechnet, nie gemischt). Vier Kennzahlen brauchen
-- Portalsystem oder Salesforce; sie stehen mit wert null und dem Grund im
-- hinweis da, damit die Tabelle zeigt, was fehlt, statt es wegzulassen.
--
-- Die Mindestfallzahl aus Teil G Abschnitt 6.2 gilt fuer jede Zeile:
-- beruht ein Wert auf weniger als 20 Besuchen (bei Code-Einloesungen ohne
-- Klick-ID: Einloesungen), werden wert, zaehler, nenner und
-- grundgesamtheit null, und der hinweis sagt es. Ein kleiner Wert waere
-- sonst eine Auswertung ueber wenige Personen.
--
-- modell.kennzahlen_rechnen() fuellt die Tabelle neu. Aufruf von Hand im
-- SQL-Editor, siehe deploy.md Abschnitt 7; einen Zeitplan-Dienst hat der
-- Gratis-Tarif nicht.
--
-- modell.arbeitgeber_report(mandant, monat, quelle) rechnet die drei
-- Stufen des Reports aus Teil G Abschnitt 6 gegen die echten Tabellen. Die
-- Edge Function klickout reicht ihn ueber die Route /klickout/report an die
-- Seite weiter; dafuer gibt es die Huelle public.arbeitgeber_report, die
-- nur der Dienstschluessel ausfuehren darf.
--
-- Ausfuehren nach sichten.sql. Mehrfach ausfuehrbar.
-- =====================================================================


-- ---------------------------------------------------------------------
-- 1. Mindestfallzahl
-- 20 Konten je Zelle in Stufe eins und zwei, 50 in Stufe drei (Teil G
-- 6.2). Die Rohzeilen kennen keine Konten; gezaehlt werden Besuche, bei
-- angemeldeten Klick-outs der userKey. Ein Mensch kann mehrere Besuche
-- haben, die Schwelle ist damit schwaecher als 20 Konten. Das steht im
-- README und ist die ehrliche Grenze einer Seite ohne Wiedererkennung.
-- ---------------------------------------------------------------------

create or replace function modell.mindestfallzahl(p_stufe integer default 2)
returns integer
language sql
immutable
as $$
    select case when p_stufe >= 3 then 50 else 20 end;
$$;

comment on function modell.mindestfallzahl(integer) is
    'Mindestfallzahl je Zelle nach Teil G 6.2: 20 in Stufe eins und zwei, 50 in Stufe drei.';


-- ---------------------------------------------------------------------
-- 2. Die Tabelle
-- ---------------------------------------------------------------------

create table if not exists modell.kennzahl (
    nr               smallint    not null,           -- Reihenfolge wie in Teil C Abschnitt 7
    name             text        not null,
    zeitraum         text        not null,           -- JJJJ-MM oder 'letzte 30 Tage'
    von              date        not null,
    bis              date        not null,           -- ausschliesslich
    mandant          text        not null,           -- alle oder der Mandant
    quelle           text        not null,           -- live oder synthetisch
    wert             numeric,
    zaehler          numeric,
    nenner           numeric,
    grundgesamtheit  integer,                        -- Besuche in der Zelle, auf die sich der Wert bezieht
    einheit          text,
    hinweis          text,
    berechnet_am     timestamptz not null default now(),
    primary key (name, zeitraum, mandant, quelle)
);

comment on table modell.kennzahl is
    'Die zwoelf Kennzahlen aus Teil C Abschnitt 7 und als dreizehnte der Anteil der Uebergaben, die den Zusammenhang verlieren, je Zeitraum, Mandant und Quelle. Werte unter der Mindestfallzahl sind null mit Hinweis. Neu rechnen mit select modell.kennzahlen_rechnen().';

alter table modell.kennzahl enable row level security;


-- ---------------------------------------------------------------------
-- 3. Eine Zeile eintragen, mit der Schutzregel
-- p_hinweis ist die Definition und ihre bekannte Ungenauigkeit und bleibt
-- immer stehen. p_detail traegt Zahlen und faellt weg, wenn die Zeile
-- unterdrueckt wird; sonst kaeme die kleine Zahl ueber den Hinweis heraus.
-- ---------------------------------------------------------------------

create or replace function modell.kennzahl_eintragen(
    p_nr integer, p_name text, p_zeitraum text, p_von date, p_bis date, p_mandant text, p_quelle text,
    p_wert numeric, p_zaehler numeric, p_nenner numeric, p_n integer, p_einheit text,
    p_hinweis text, p_detail text default null
) returns void
language plpgsql
as $$
declare
    mf integer := modell.mindestfallzahl(2);
begin
    if p_n is not null and p_n < mf then
        insert into modell.kennzahl (nr, name, zeitraum, von, bis, mandant, quelle, wert, zaehler, nenner,
                                     grundgesamtheit, einheit, hinweis)
        values (p_nr, p_name, p_zeitraum, p_von, p_bis, p_mandant, p_quelle, null, null, null, null, p_einheit,
                case when p_n = 0 then 'keine Grundgesamtheit im Zeitraum. '
                     else 'unterdrückt: weniger als ' || mf || ' Besuche in der Grundgesamtheit (Mindestfallzahl, Teil G 6.2). ' end
                || coalesce(p_hinweis, ''));
    else
        insert into modell.kennzahl (nr, name, zeitraum, von, bis, mandant, quelle, wert, zaehler, nenner,
                                     grundgesamtheit, einheit, hinweis)
        values (p_nr, p_name, p_zeitraum, p_von, p_bis, p_mandant, p_quelle, p_wert, p_zaehler, p_nenner, p_n,
                p_einheit, coalesce(p_detail || ' ', '') || coalesce(p_hinweis, ''));
    end if;
end;
$$;


-- ---------------------------------------------------------------------
-- 4. Einloesungsquote je Kategorie
-- Fuer die Hochrechnung der Ersparnis bei Partnern ohne Rueckkanal: der
-- Anteil der Deeplink-Klick-outs im synthetischen Grundbestand, zu denen
-- eine nicht stornierte Bestellung gemeldet wurde. Echte Zeilen sind dafuer
-- zu wenige; faellt eine Kategorie aus, gilt die Quote ueber alle.
-- ---------------------------------------------------------------------

create or replace view modell.einloesungsquote as
with basis as (
    select k.kategorie, k.klick_id,
           exists (select 1 from modell.transaktion t
                    where t.klick_id = k.klick_id and t.status <> 'storniert') as eingeloest
      from modell.klick_out k
     where k.quelle = 'synthetisch' and k.partnerart = 'deeplink'
),
je_kategorie as (
    select kategorie, count(*) as klick_outs, count(*) filter (where eingeloest) as einloesungen
      from basis group by kategorie
),
gesamt as (
    select count(*) as klick_outs, count(*) filter (where eingeloest) as einloesungen from basis
)
select a.kategorie,
       coalesce(j.klick_outs, 0)                                              as klick_outs,
       coalesce(j.einloesungen, 0)                                            as einloesungen,
       case when coalesce(j.klick_outs, 0) >= 10 then round(j.einloesungen::numeric / j.klick_outs, 4)
            else round(g.einloesungen::numeric / nullif(g.klick_outs, 0), 4) end as quote,
       coalesce(j.klick_outs, 0) < 10                                         as quote_ueber_alle
  from (select distinct kategorie from public.angebote) a
  left join je_kategorie j on j.kategorie = a.kategorie
  cross join gesamt g;

comment on view modell.einloesungsquote is
    'Einloesungsquote je Kategorie aus dem synthetischen Grundbestand (Deeplink-Klick-outs mit nicht stornierter Bestellung); unter zehn Klick-outs gilt die Quote ueber alle Kategorien.';


-- ---------------------------------------------------------------------
-- 5. Kennzahlen rechnen
-- ---------------------------------------------------------------------

create or replace function modell.kennzahlen_rechnen()
returns integer
language plpgsql
set search_path = modell, public
as $$
declare
    z        record;
    q        text;
    m        text;
    ab       timestamptz;
    bis      timestamptz;
    heute    date := (now() at time zone 'Europe/Berlin')::date;
    n        integer;
    n2       integer;
    n_zelle  integer;
    zl       numeric;
    nn       numeric;
    x1       numeric;
    x2       numeric;
    x3       numeric;
    a_mit    integer;
    a_alle   integer;
    ergebnis integer;
begin
    delete from modell.kennzahl;
    select count(*) filter (where rueckkanal <> 'keiner'), count(*) into a_mit, a_alle from public.anbieter;

    for z in
        select to_char(monat, 'YYYY-MM') as zeitraum, monat::date as von, (monat + interval '1 month')::date as bis
          from generate_series(
                   date_trunc('month', (least(
                       coalesce((select min(empfangen_am) from public.rohereignisse), now()),
                       coalesce((select min(coalesce(erzeugt_am, geschrieben_am)) from public.klickouts), now()),
                       coalesce((select min(coalesce(bestellt_am, empfangen_am)) from public.postbacks), now())
                   ) at time zone 'Europe/Berlin')),
                   date_trunc('month', now() at time zone 'Europe/Berlin'),
                   interval '1 month') as monat
        union all
        select 'letzte 30 Tage', heute - 29, heute + 1
    loop
        ab  := z.von::timestamp at time zone 'Europe/Berlin';
        bis := z.bis::timestamp at time zone 'Europe/Berlin';

        foreach q in array array['live', 'synthetisch'] loop
            for m in select 'alle' union all select mandant from modell.mandant loop

                -- 1 bis 3 und 12: nicht aus den Rohzeilen berechenbar
                perform modell.kennzahl_eintragen(1, 'Registrierte Nutzer, bereinigt', z.zeitraum, z.von, z.bis, m, q,
                    null, null, null, null, 'Konten',
                    'nicht berechenbar: braucht das Nutzerkonto aus dem Portalsystem (Konten mit Angebotsansicht in zwölf Monaten). Die Rohzeilen tragen kein Konto, nur den userKey angemeldeter Besuche.');
                perform modell.kennzahl_eintragen(2, 'Monatlich aktive Nutzer', z.zeitraum, z.von, z.bis, m, q,
                    null, null, null, null, 'Konten',
                    'nicht berechenbar: braucht das Nutzerkonto aus dem Portalsystem. Ein Zähler über den userKey der Rohzeilen wäre eine Untergrenze, weil nicht angemeldete Besuche fehlen.');
                perform modell.kennzahl_eintragen(3, 'Aktivierungsquote je Mandant', z.zeitraum, z.von, z.bis, m, q,
                    null, null, null, null, 'Anteil',
                    'nicht berechenbar: Zähler sind die monatlich aktiven Nutzer aus dem Portalsystem, Nenner die Belegschaft laut Kunde; die Belegschaft steht in modell.mandant, ohne Zähler hilft sie nicht.');
                perform modell.kennzahl_eintragen(12, 'Lead-zu-Aktivierung', z.zeitraum, z.von, z.bis, m, q,
                    null, null, null, null, 'Anteil',
                    'nicht berechenbar: braucht Lead und Akquisekanal aus Salesforce und die Aktivierungsquote aus dem Portalsystem.');

                -- 4 Angebotsansichten und Klick-out-Rate
                select count(*) filter (where e.ereignisart = 'offer.detail.open'),
                       count(distinct e.klick_id) filter (where e.ereignisart in ('offer.clickout', 'offer.code.show')),
                       count(distinct e.besuch_id) filter (where e.ereignisart = 'offer.detail.open')
                  into nn, zl, n
                  from modell.ereignis e
                 where e.quelle = q and e.zeit >= ab and e.zeit < bis and (m = 'alle' or e.mandant = m);
                perform modell.kennzahl_eintragen(4, 'Angebotsansichten und Klick-out-Rate', z.zeitraum, z.von, z.bis, m, q,
                    case when nn > 0 then round(zl / nn, 4) end, zl, nn, n, 'Anteil',
                    'Klick-outs aus den Browserzeilen (offer.clickout und offer.code.show, je Klick-ID) geteilt durch Angebotsansichten (offer.detail.open); die Code-Anzeige zählt als Klick-out.'
                    || case when q = 'synthetisch' then ' Der synthetische Grundbestand schreibt keine Angebotsansichten.' else '' end);

                -- 5 Sichtbare Auslieferung
                select count(*) filter (where a.sichtbar), count(*), count(distinct a.besuch_id)
                  into zl, nn, n
                  from modell.auslieferung a
                 where a.quelle = q and a.erste_zeit >= ab and a.erste_zeit < bis and (m = 'alle' or a.mandant = m);
                perform modell.kennzahl_eintragen(5, 'Sichtbare Auslieferung', z.zeitraum, z.von, z.bis, m, q,
                    zl, zl, nn, n, 'Auslieferungen',
                    'Auslieferungen je Besuch, Belegung und Position, bei denen der Teaser zu mindestens 50 Prozent im Fenster war (teaser.visible); Zähler durch Nenner ist die Sichtbarkeitsquote.'
                    || case when q = 'synthetisch' then ' Der synthetische Grundbestand schreibt keine Teaser-Ereignisse.' else '' end);

                -- 6 Slot-Klickrate, positionsbereinigt
                with a as (
                    select * from modell.auslieferung
                     where quelle = q and erste_zeit >= ab and erste_zeit < bis
                ),
                pos as (
                    select position,
                           count(*) filter (where geklickt)::numeric / nullif(count(*) filter (where sichtbar), 0) as klickrate
                      from a group by position
                )
                select count(*) filter (where a.geklickt),
                       sum(p.klickrate) filter (where a.sichtbar),
                       count(distinct a.besuch_id) filter (where a.sichtbar)
                  into zl, nn, n
                  from a join pos p on p.position is not distinct from a.position
                 where (m = 'alle' or a.mandant = m);
                perform modell.kennzahl_eintragen(6, 'Slot-Klickrate, positionsbereinigt', z.zeitraum, z.von, z.bis, m, q,
                    case when nn > 0 then round(zl / nn, 4) end, zl, round(nn, 4), n, 'Verhältnis',
                    'Teaser-Klicks geteilt durch die erwarteten Klicks, also je sichtbarer Auslieferung die Klickrate ihrer Position über alle Mandanten. 1 heißt so gut wie der Durchschnitt der Position; für alle Mandanten zusammen ist der Wert 1 durch Konstruktion.');

                -- 7 Belegte Einloesungen
                -- Grundgesamtheit fuer 7 und 9: die Besuche mit Klick-out in der Zelle
                -- und die Personen hinter den Transaktionen. Die Zelle ist Mandant und
                -- Zeitraum, wie im Arbeitgeber-Report, nicht die Menge der Kaeufer.
                select count(distinct person) into n_zelle
                  from (select coalesce(k.user_key, k.besuch_id, k.klick_id) as person
                          from modell.klick_out k
                         where k.quelle = q and k.zeit >= ab and k.zeit < bis and (m = 'alle' or k.mandant = m)
                        union
                        select coalesce(t.user_key, t.besuch_id, t.transaktion_id)
                          from modell.transaktion t
                         where t.quelle = q and t.bestellt_am >= ab and t.bestellt_am < bis
                           and (m = 'alle' or t.mandant = m)) personen;
                select count(*) filter (where t.status = 'bestaetigt'), count(*),
                       count(*) filter (where t.status = 'offen'), count(*) filter (where t.status = 'storniert')
                  into zl, nn, x1, x2
                  from modell.transaktion t
                 where t.quelle = q and t.bestellt_am >= ab and t.bestellt_am < bis and (m = 'alle' or t.mandant = m);
                perform modell.kennzahl_eintragen(7, 'Belegte Einlösungen', z.zeitraum, z.von, z.bis, m, q,
                    zl, zl, nn, n_zelle, 'Transaktionen',
                    'Transaktionen mit Status bestätigt nach Bestelldatum; Freigabe nach 14 Tagen, beim Code mit der Monatsabrechnung, deshalb sind der laufende Monat und der Vormonat vorläufig.',
                    'bestätigt ' || zl || ', offen ' || x1 || ', storniert ' || x2 || '.');

                -- 8 Belegstatus-Abdeckung
                select count(*) filter (where k.partnerart in ('deeplink', 'gutschein')), count(*),
                       count(distinct coalesce(k.user_key, k.besuch_id, k.klick_id))
                  into zl, nn, n
                  from modell.klick_out k
                 where k.quelle = q and k.zeit >= ab and k.zeit < bis and (m = 'alle' or k.mandant = m);
                perform modell.kennzahl_eintragen(8, 'Belegstatus-Abdeckung', z.zeitraum, z.von, z.bis, m, q,
                    case when nn > 0 then round(zl / nn, 4) end, zl, nn, n, 'Anteil',
                    'Anteil der Klick-outs zu Anbietern mit Rückkanal. Anteil der Anbieter mit Rückkanal im Katalog: ' || a_mit || ' von ' || a_alle
                    || '. Der dritte Anteil aus Teil C, Anbieterumsatz mit belegter Einlösung, fehlt, weil der Umsatz eine Größe des Vertriebs ist.');

                -- 9 Ersparnis der Belegschaft
                select coalesce(sum(t.ersparnis_euro), 0)
                  into zl
                  from modell.transaktion t
                 where t.quelle = q and t.status = 'bestaetigt'
                   and t.bestellt_am >= ab and t.bestellt_am < bis and (m = 'alle' or t.mandant = m);
                select coalesce(sum(eq.quote * kat.ersparnis_euro) filter (where k.partnerart = 'ohne'), 0),
                       count(*) filter (where k.partnerart = 'ohne'),
                       count(*),
                       count(distinct coalesce(k.user_key, k.besuch_id, k.klick_id)) filter (where k.partnerart = 'ohne')
                  into x1, x2, x3, n2
                  from modell.klick_out k
                  left join modell.angebot_katalog kat on kat.angebot_id = k.angebot
                  left join modell.einloesungsquote eq on eq.kategorie = k.kategorie
                 where k.quelle = q and k.zeit >= ab and k.zeit < bis and (m = 'alle' or k.mandant = m);
                perform modell.kennzahl_eintragen(9, 'Ersparnis der Belegschaft', z.zeitraum, z.von, z.bis, m, q,
                    round(zl, 2), round(zl, 2), null, n_zelle, 'Euro',
                    'wert ist die belegte Ersparnis aus bestätigten Transaktionen (Bestellwert mal Rabatt, bei Festbeträgen der Betrag). Die Hochrechnung für Partner ohne Rückkanal nutzt die Einlösungsquote der Kategorie aus dem synthetischen Grundbestand; Storno ändert die Zahl rückwirkend.',
                    case when n2 >= modell.mindestfallzahl(2)
                         then 'geschätzt zusätzlich ' || round(x1, 2) || ' Euro aus ' || x2 || ' Klick-outs ohne Rückkanal; nicht erfasst '
                              || round(100 * x2 / nullif(x3, 0), 1) || ' Prozent der Klick-outs.'
                         else 'Hochrechnung und Anteil nicht erfasst unterdrückt: weniger als ' || modell.mindestfallzahl(2) || ' Besuche mit Klick-out ohne Rückkanal.' end);

                -- 10 Auffangkanal-Anteil
                select count(*) filter (where b.einstiegs_bereich in ('Auffang', 'ungueltig')),
                       count(*) filter (where b.einstiegs_mediacode is not null),
                       count(*) filter (where b.einstiegs_mediacode is not null)
                  into zl, nn, n
                  from modell.besuch b
                 where b.quelle = q and not b.technisch and b.erste_zeit >= ab and b.erste_zeit < bis
                   and (m = 'alle' or b.mandant = m);
                perform modell.kennzahl_eintragen(10, 'Auffangkanal-Anteil', z.zeitraum, z.von, z.bis, m, q,
                    case when nn > 0 then round(zl / nn, 4) end, zl, nn, n, 'Anteil',
                    'Besuche mit Einstiegs-Mediacode auffang.unbekannt oder ungültigem Medium geteilt durch Besuche mit Mediacode. Die Seite setzt auffang.unbekannt auch ohne Kampagnenparameter; Direktbesuche stehen deshalb im Zähler, der Wert ist eine Obergrenze.'
                    || case when q = 'synthetisch' then ' Im Grundbestand ist jeder Besuch ein Besuch mit Klick-out.' else '' end);

                -- 11 Einstiege ueber Arbeitgeberkanal
                select count(*) filter (where b.einstiegs_bereich = 'B'), count(*)
                  into zl, nn
                  from modell.besuch b
                 where b.quelle = q and not b.technisch and b.erste_zeit >= ab and b.erste_zeit < bis
                   and (m = 'alle' or b.mandant = m);
                perform modell.kennzahl_eintragen(11, 'Einstiege über Arbeitgeberkanal', z.zeitraum, z.von, z.bis, m, q,
                    zl, zl, nn, zl::integer, 'Besuche',
                    'Besuche mit Einstiegs-Mediacode aus Bereich B (Kanäle des Arbeitgebers). Einstiegsmessung: was nach dem ersten Besuch geschieht, zählt nicht mehr zur Kampagne. Unter der Mindestfallzahl nicht ausgewiesen.');

                -- 13 Anteil der Uebergaben, die den Zusammenhang verlieren
                -- Grundgesamtheit sind die Uebergaben selbst; jede ist eine
                -- Seitenladung und damit ein Besuch im Sinne der Mindestfallzahl.
                select count(*) filter (where u.zusammenhang_verloren), count(*),
                       count(*) filter (where u.spaeter_angemeldet)
                  into zl, nn, x1
                  from modell.uebergabe u
                 where u.quelle = q and u.zeit >= ab and u.zeit < bis and (m = 'alle' or u.mandant = m);
                perform modell.kennzahl_eintragen(13, 'Anteil der Übergaben, die den Zusammenhang verlieren', z.zeitraum, z.von, z.bis, m, q,
                    case when nn > 0 then round(zl / nn, 4) end, zl, nn, nn::integer, 'Anteil',
                    'Übergaben aus der App (Ereignis app.uebergabe), bei denen die Webansicht ohne Anmeldung ankam, geteilt durch alle Übergaben. Ohne Anmeldung ist der Web-Besuch ein neuer anonymer Besuch, und die monatlich aktiven Nutzer zählen ihn nicht; im großen synthetischen Datensatz trifft das 30 Prozent der Übergaben. Gezählt wird nur die Web-Hälfte: eine Übergabe, deren Adresse die Kennung verlor, steht ohne Kennung da, eine, die nie ankam, fehlt.'
                    || case when q = 'synthetisch' then ' Der synthetische Grundbestand schreibt keine Übergaben.' else '' end,
                    case when nn > 0 then 'davon später in derselben Seitenladung selbst angemeldet: ' || x1 || '.' end);
            end loop;
        end loop;
    end loop;

    select count(*) into ergebnis from modell.kennzahl;
    return ergebnis;
end;
$$;

comment on function modell.kennzahlen_rechnen() is
    'Leert modell.kennzahl und rechnet die zwoelf Kennzahlen aus Teil C und die Uebergabe-Kennzahl je Zeitraum, Mandant und Quelle neu. Gibt die Zahl der Zeilen zurueck.';


-- ---------------------------------------------------------------------
-- 6. Arbeitgeber-Report
-- Die drei Stufen aus Teil G Abschnitt 6 und index.html (reportGrunddaten,
-- reportZeichnen), gerechnet gegen die echten Tabellen:
--   Stufe eins  der Mandant gesamt
--   Stufe zwei  je Kategorie und je Angebot, nur wenn der Stammdatensatz
--               Stufe zwei oder drei traegt
--   Stufe drei  je Standort, nur mit Betriebsvereinbarung; der Standort
--               steht in keiner Rohzeile, deshalb gibt es hier keine Zelle
-- Jede Zelle unter der Mindestfallzahl kommt mit unterdrueckt = wahr und
-- ohne Zahlen zurueck, auch die Grundgesamtheit. Die Zelle verschwindet
-- nicht, damit im Report zu sehen ist, dass an der Stelle etwas steht.
--
-- Ersparnis:
--   belegt      bestaetigte Transaktionen dieses Mandanten im Monat (nach
--               Bestelldatum); beim Deeplink ueber die Klick-ID, beim Code
--               ueber die Kandidaten-Klicks, deren Mandant eindeutig ist
--   geschaetzt  Klick-outs zu Partnern ohne Rueckkanal mal Einloesungsquote
--               der Kategorie (modell.einloesungsquote) mal Ersparnis laut
--               Katalog
--   nicht erfasst  Anteil der Klick-outs ohne Rueckkanal
-- ---------------------------------------------------------------------

create or replace function modell.arbeitgeber_report(
    p_mandant text,
    p_monat   date,
    p_quelle  text default 'live'
) returns table (
    stufe                      integer,
    ebene                      text,
    schluessel                 text,
    grundgesamtheit            integer,
    angebotsansichten          bigint,
    klickouts                  bigint,
    ersparnis_belegt           numeric,
    ersparnis_geschaetzt       numeric,
    klickouts_ohne_rueckkanal  bigint,
    anteil_nicht_erfasst       numeric,
    unterdrueckt               boolean,
    hinweis                    text,
    juengste_zeile             timestamptz
)
language plpgsql
stable
set search_path = modell, public
as $$
#variable_conflict use_column
declare
    st   modell.mandant%rowtype;
    ab   timestamptz;
    bis  timestamptz;
    mf2  integer := modell.mindestfallzahl(2);
    mf3  integer := modell.mindestfallzahl(3);
    jz   timestamptz;
begin
    if p_quelle is null or p_quelle not in ('live', 'synthetisch') then
        raise exception 'p_quelle muss live oder synthetisch sein, nicht %', p_quelle;
    end if;
    select * into st from modell.mandant where mandant = p_mandant;
    if not found then
        raise exception 'Mandant % steht nicht in modell.mandant', p_mandant;
    end if;
    ab  := date_trunc('month', coalesce(p_monat, (now() at time zone 'Europe/Berlin')::date))::timestamp at time zone 'Europe/Berlin';
    bis := (date_trunc('month', coalesce(p_monat, (now() at time zone 'Europe/Berlin')::date)) + interval '1 month')::timestamp at time zone 'Europe/Berlin';
    select greatest((select max(r.empfangen_am)   from public.rohereignisse r where r.quelle = p_quelle),
                    (select max(k.geschrieben_am) from public.klickouts k     where k.quelle = p_quelle),
                    (select max(p.empfangen_am)   from public.postbacks p     where p.quelle = p_quelle))
      into jz;

    return query
    with fakten as (
        -- Angebotsansichten
        select e.kategorie, e.angebot, e.besuch_id as person,
               1 as ansicht, 0 as klick, 0 as ohne, 0::numeric as belegt, 0::numeric as geschaetzt
          from modell.ereignis e
         where e.quelle = p_quelle and e.mandant = p_mandant and e.ereignisart = 'offer.detail.open'
           and e.zeit >= ab and e.zeit < bis
        union all
        -- Klick-outs, mit der Hochrechnung fuer Partner ohne Rueckkanal
        select k.kategorie, k.angebot, coalesce(k.user_key, k.besuch_id, k.klick_id),
               0, 1, case when k.partnerart = 'ohne' then 1 else 0 end, 0,
               case when k.partnerart = 'ohne' then coalesce(eq.quote * kat.ersparnis_euro, 0) else 0 end
          from modell.klick_out k
          left join modell.angebot_katalog kat on kat.angebot_id = k.angebot
          left join modell.einloesungsquote eq on eq.kategorie = k.kategorie
         where k.quelle = p_quelle and k.mandant = p_mandant and k.zeit >= ab and k.zeit < bis
        union all
        -- bestaetigte Transaktionen
        select t.kategorie, t.angebot, coalesce(t.user_key, t.besuch_id, t.transaktion_id),
               0, 0, 0, coalesce(t.ersparnis_euro, 0), 0
          from modell.transaktion t
         where t.quelle = p_quelle and t.mandant = p_mandant and t.status = 'bestaetigt'
           and t.bestellt_am >= ab and t.bestellt_am < bis
    ),
    zellen as (
        select case when grouping(f.kategorie) = 0 then 'kategorie'
                    when grouping(f.angebot) = 0   then 'angebot'
                    else 'mandant' end                              as ebene,
               case when grouping(f.kategorie) = 0 then f.kategorie
                    when grouping(f.angebot) = 0   then f.angebot
                    else p_mandant end                              as schluessel,
               count(distinct f.person)::integer                    as n,
               sum(f.ansicht)::bigint                               as ansichten,
               sum(f.klick)::bigint                                 as klicks,
               sum(f.belegt)                                        as belegt,
               sum(f.geschaetzt)                                    as geschaetzt,
               sum(f.ohne)::bigint                                  as ohne
          from fakten f
         group by grouping sets ((), (f.kategorie), (f.angebot))
    )
    -- Stufe eins: auch der Mandant gesamt steht unter der Schwelle
    select 1, 'mandant', p_mandant,
           case when coalesce(z.n, 0) >= mf2 then z.n end,
           case when coalesce(z.n, 0) >= mf2 then z.ansichten end,
           case when coalesce(z.n, 0) >= mf2 then z.klicks end,
           case when coalesce(z.n, 0) >= mf2 then round(z.belegt, 2) end,
           case when coalesce(z.n, 0) >= mf2 then round(z.geschaetzt, 2) end,
           case when coalesce(z.n, 0) >= mf2 then z.ohne end,
           case when coalesce(z.n, 0) >= mf2 then round(z.ohne::numeric / nullif(z.klicks, 0), 4) end,
           coalesce(z.n, 0) < mf2,
           case when coalesce(z.n, 0) >= mf2
                then 'Mandant gesamt. Quellen: rohereignisse (offer.detail.open), klickouts und rohereignisse (modell.klick_out), postbacks (modell.transaktion), angebote und anbieter. Registrierte und aktive Nutzer und die Aktivierungsquote brauchen das Portalsystem und fehlen hier.'
                else 'unterdrückt: weniger als ' || mf2 || ' Besuche im Monat (Mindestfallzahl, Teil G 6.2).' end,
           jz
      from (select 1) eins
      left join zellen z on z.ebene = 'mandant'
    union all
    -- Stufe zwei: Kategorien und Angebote, wenn der Stammdatensatz es erlaubt
    select 2, z.ebene, z.schluessel,
           case when z.n >= mf2 then z.n end,
           case when z.n >= mf2 then z.ansichten end,
           case when z.n >= mf2 then z.klicks end,
           case when z.n >= mf2 then round(z.belegt, 2) end,
           case when z.n >= mf2 then round(z.geschaetzt, 2) end,
           case when z.n >= mf2 then z.ohne end,
           case when z.n >= mf2 then round(z.ohne::numeric / nullif(z.klicks, 0), 4) end,
           z.n < mf2,
           case when z.n >= mf2 then null
                else 'unterdrückt: weniger als ' || mf2 || ' Besuche in der Zelle.' end,
           jz
      from zellen z
     where z.ebene in ('kategorie', 'angebot') and st.reporting_stufe >= 2
    union all
    select 2, 'kategorie', null, null, null, null, null, null, null, null, true,
           'Stufe zwei ist für diesen Mandanten nicht freigegeben (Reporting-Stufe im Stammdatensatz).', jz
     where st.reporting_stufe < 2
    union all
    -- Stufe drei: Standorte
    select 3, 'standort', null, null, null, null, null, null, null, null, true,
           case when st.reporting_stufe >= 3 and st.betriebsvereinbarung
                then 'Stufe drei ist freigegeben (Betriebsvereinbarung im Stammdatensatz, Schwelle ' || mf3
                     || '). Der Standort steht aber in keiner Rohzeile, er käme aus dem Konto im Portalsystem; ohne das Merkmal gibt es keine Zelle und keine Zahl.'
                else 'Stufe drei ist gesperrt: keine Betriebsvereinbarung im Stammdatensatz. Die Sperre hängt am Stammdatensatz, nicht an der Bedienung.' end,
           jz;
end;
$$;

comment on function modell.arbeitgeber_report(text, date, text) is
    'Arbeitgeber-Report nach Teil G 6 fuer einen Mandanten und Monat aus den echten Tabellen, getrennt nach Quelle. Zellen unter der Mindestfallzahl kommen ohne Zahlen und mit unterdrueckt = wahr.';


-- ---------------------------------------------------------------------
-- 7. Die Huelle fuer die Edge Function
-- Das Schema modell ist nicht ueber die Schnittstelle freigegeben. Die
-- Edge Function klickout ruft deshalb diese Funktion in public, und nur mit
-- dem Dienstschluessel. Sie reicht nichts durch, was die innere Funktion
-- nicht schon gefiltert hat.
-- ---------------------------------------------------------------------

create or replace function public.arbeitgeber_report(
    p_mandant text,
    p_monat   date,
    p_quelle  text default 'live'
) returns table (
    stufe                      integer,
    ebene                      text,
    schluessel                 text,
    grundgesamtheit            integer,
    angebotsansichten          bigint,
    klickouts                  bigint,
    ersparnis_belegt           numeric,
    ersparnis_geschaetzt       numeric,
    klickouts_ohne_rueckkanal  bigint,
    anteil_nicht_erfasst       numeric,
    unterdrueckt               boolean,
    hinweis                    text,
    juengste_zeile             timestamptz
)
language sql
stable
security definer
set search_path = ''
as $$
    select * from modell.arbeitgeber_report(p_mandant, p_monat, p_quelle);
$$;

comment on function public.arbeitgeber_report(text, date, text) is
    'Huelle um modell.arbeitgeber_report fuer die Route /klickout/report. Nur service_role darf sie ausfuehren.';


-- ---------------------------------------------------------------------
-- 8. Rechte
-- ---------------------------------------------------------------------

revoke all on all tables in schema modell from public, anon, authenticated;
grant select on all tables in schema modell to service_role;

revoke all on function modell.mindestfallzahl(integer) from public, anon, authenticated;
revoke all on function modell.kennzahl_eintragen(integer, text, text, date, date, text, text, numeric, numeric, numeric, integer, text, text, text) from public, anon, authenticated;
revoke all on function modell.kennzahlen_rechnen() from public, anon, authenticated;
revoke all on function modell.arbeitgeber_report(text, date, text) from public, anon, authenticated;
revoke all on function public.arbeitgeber_report(text, date, text) from public, anon, authenticated;

grant execute on function modell.mindestfallzahl(integer) to service_role;
grant execute on function public.arbeitgeber_report(text, date, text) to service_role;
