// =====================================================================
// partnershop: der Server des Deeplink-Partners
// Supabase Edge Function, Deno. Stand 10.09.2026 abends, Arbeitspaket 5,
// Nachtrag (Ergebnis 5 aus dem Folgeprompt, Luecke 9 im Standsbericht).
//
// Bis hierher kam der Server-Postback aus dem Browser der Partnerseite:
// ein fetch auf /postback/partnershop, der so tat, als sei er das
// Shopsystem. Diese Funktion ist das Shopsystem. Sie gehoert im Modell dem
// Partner und nicht dem Portal; sie liegt nur deshalb im selben Projekt,
// weil ein zweites fuer eine Attrappe zu viel waere. Vom Portal kennt sie
// die Klick-ID aus der Adresse und die Adresse des Portal-Endpunkts, sonst
// nichts. Ihre Bestellungen stehen in public.partnershop_bestellungen.
//
// Drei Pfade:
//   POST /partnershop           nimmt eine Bestellung an, vergibt die
//                               Bestellnummer, speichert sie und meldet sie
//                               sofort als offen an postback, von Server zu
//                               Server. Der Browser ist an der Meldung nicht
//                               beteiligt.
//   GET  /partnershop/status    was der Shop ueber eine Bestellung weiss
//   POST /partnershop/lauf      der Nachtlauf: meldet Freigabe (14 Tage nach
//                               der Bestellung) oder Storno (acht Prozent,
//                               2 bis 13 Tage danach), sobald sie faellig
//                               sind, und holt Meldungen nach, die beim ersten
//                               Versuch nicht durchgingen. Im Betrieb liefe er
//                               per Cron; fuer die Vorfuehrung genuegt der
//                               Aufruf, zum Beispiel vom Knopf auf der
//                               Partnerseite.
//
// Der Lauf hat einen Hebel fuer die Vorfuehrung: vorspulen_tage stellt die
// Uhr des Shops vor, weil vierzehn Tage Warten in kein Gespraech passen.
// Jede Meldung, die dabei entsteht, traegt die vorgestellte Uhr in
// gemeldet_am und die Zahl der Tage im Parameter vorgespult_tage. Das
// Portal glaubt fuer seine eigenen Zeiten weiter der eigenen Uhr
// (empfangen_am), so wie es bei klickouts geschrieben_am vor erzeugt_am
// stellt.
//
// Die Meldungen sind signiert, wenn das Secret PARTNERSHOP_SCHLUESSEL fuer
// die Edge Functions des Projekts gesetzt ist: HMAC-SHA256 ueber Zeitstempel
// und Rumpf, im Kopf x-partnershop-signatur als t=<Sekunden>,v1=<hex>. Das
// kann ein Pixel nie: ein Browser haelt kein Geheimnis, ein Server schon.
// Fehlt das Secret, geht die Meldung unsigniert hinaus, und postback
// vermerkt das an der Zeile.
//
// Was die Funktion nicht tut: keine IP speichern, keinen User-Agent, kein
// Set-Cookie. CORS nur fuer die eigenen Hosts. JWT-Pruefung muss aus sein,
// weil die Partnerseite keinen Schluessel hat, siehe deploy.md Abschnitt 8.
// =====================================================================

const SUPABASE_URL = Deno.env.get("SUPABASE_URL")!;
const DIENSTSCHLUESSEL = Deno.env.get("SUPABASE_SERVICE_ROLE_KEY")!;
const SCHLUESSEL = Deno.env.get("PARTNERSHOP_SCHLUESSEL") || "";

// Wohin der Shop meldet: der Server-Eingang des Portals. Ein echter Partner
// bekaeme diese Adresse vom Netzwerk oder vom Portal mitgeteilt.
const POSTBACK_URL = SUPABASE_URL + "/functions/v1/postback/partnershop";

const ERLAUBTE_HERKUNFT = [
  "https://mamfredkaiser.github.io",
];

const PARTNER = "deeplink";
const FREIGABE_TAGE = 14;        // wie freigabe_tage in klickout_seed.py
const STORNO_ANTEIL = 0.08;      // wie storno in klickout_seed.py
const STORNO_TAGE_VON = 2;       // Storno innerhalb der Rueckgabefrist, vor der Freigabe
const STORNO_TAGE_BIS = 13;
const VORSPULEN_MAX_TAGE = 30;
const LAUF_GRENZE = 50;          // Zeilen je Lauf
const SPERRE_S = 120;            // so lange gehoert eine Zeile einem Lauf
const MELDEN_FRIST_MS = 8000;
const TAG_MS = 24 * 60 * 60 * 1000;

type Zeile = Record<string, unknown> & {
  id: number;
  bestellnummer: string;
  bestellt_am: string;
  klick_id: string | null;
  shop: string | null;
  bestellwert: number | string;
  waehrung: string;
  ausgang: "freigabe" | "storno";
  abschluss_faellig_am: string;
  status: string;
  bestellung_gemeldet_am: string | null;
  abschluss_gemeldet_am: string | null;
  versuche: number;
};

function herkunftPruefen(origin: string | null): string | null {
  if (!origin) return null;
  return ERLAUBTE_HERKUNFT.includes(origin) ? origin : null;
}

function kopfzeilen(origin: string | null, json = true): Record<string, string> {
  const h: Record<string, string> = { "Cache-Control": "no-store", "Vary": "Origin" };
  if (json) h["Content-Type"] = "application/json; charset=utf-8";
  const erlaubt = herkunftPruefen(origin);
  if (erlaubt) {
    h["Access-Control-Allow-Origin"] = erlaubt;
    h["Access-Control-Allow-Methods"] = "GET, POST, OPTIONS";
    h["Access-Control-Allow-Headers"] = "content-type";
    h["Access-Control-Max-Age"] = "86400";
  }
  return h;
}

function antwort(daten: unknown, status: number, origin: string | null): Response {
  return new Response(JSON.stringify(daten), { status, headers: kopfzeilen(origin) });
}

async function parameterLesen(req: Request): Promise<Record<string, string>> {
  const p: Record<string, string> = {};
  for (const [k, v] of new URL(req.url).searchParams) p[k] = v;
  if (req.method === "POST") {
    const typ = req.headers.get("content-type") || "";
    try {
      if (typ.includes("application/json")) {
        const o = await req.json();
        for (const k of Object.keys(o ?? {})) if (o[k] !== null && o[k] !== undefined) p[k] = String(o[k]);
      } else {
        const t = await req.text();
        for (const [k, v] of new URLSearchParams(t)) p[k] = v;
      }
    } catch (_) {
      p["__rumpf"] = "nicht lesbar";
    }
  }
  return p;
}

async function rest(pfad: string, init: RequestInit = {}): Promise<Response> {
  const h: Record<string, string> = {
    apikey: DIENSTSCHLUESSEL,
    Authorization: "Bearer " + DIENSTSCHLUESSEL,
    "Content-Type": "application/json",
    ...(init.headers as Record<string, string> || {}),
  };
  return await fetch(SUPABASE_URL + "/rest/v1" + pfad, { ...init, headers: h });
}

// Zufall aus crypto, nicht aus Math.random: die Bestellnummer ist das
// Einzige, woran der Shop eine Bestellung wiedererkennt.
function zufall(): number {
  return crypto.getRandomValues(new Uint32Array(1))[0] / 4294967296;
}

function bestellnummerVergeben(): string {
  const b = crypto.getRandomValues(new Uint8Array(3));
  return "B-" + Array.from(b).map((x) => x.toString(16).padStart(2, "0")).join("").toUpperCase();
}

function kappen(s: string | undefined, n: number): string | null {
  if (!s) return null;
  const t = s.trim();
  return t ? t.slice(0, n) : null;
}

// ---------------------------------------------------------------------
// Signieren und melden
// ---------------------------------------------------------------------

const kodierer = new TextEncoder();

async function signieren(rumpf: string): Promise<string | null> {
  if (!SCHLUESSEL) return null;
  const t = Math.floor(Date.now() / 1000);
  const schluessel = await crypto.subtle.importKey("raw", kodierer.encode(SCHLUESSEL),
    { name: "HMAC", hash: "SHA-256" }, false, ["sign"]);
  const sig = new Uint8Array(await crypto.subtle.sign("HMAC", schluessel, kodierer.encode(t + "." + rumpf)));
  return "t=" + t + ",v1=" + Array.from(sig).map((x) => x.toString(16).padStart(2, "0")).join("");
}

// Was an postback geht. Dieselben Felder wie die Server-Zeilen im
// synthetischen Grundbestand: die Freigabe ist eine Bestellung mit Status
// bestaetigt, das Storno eine eigene Art mit Status storniert.
function meldungBauen(b: Zeile, was: "bestellung" | "freigabe" | "storno", uhrShop: Date,
                      vorgespult: number, lauf: string | null): Record<string, unknown> {
  const m: Record<string, unknown> = {
    art: was === "storno" ? "storno" : "bestellung",
    status: was === "bestellung" ? "offen" : (was === "storno" ? "storniert" : "bestaetigt"),
    partner: PARTNER,
    klick: b.klick_id || undefined,
    bestellnummer: b.bestellnummer,
    wert: Number(b.bestellwert),
    waehrung: b.waehrung,
    bestellt_am: b.bestellt_am,
    gemeldet_am: uhrShop.toISOString(),
    shop: b.shop || undefined,
    absender: "partnershop-server",
  };
  if (was === "freigabe") m.freigabe = "ja";
  if (was === "storno") m.grund = "Retoure";
  if (was !== "bestellung") m.faellig_am = b.abschluss_faellig_am;
  if (vorgespult > 0) m.vorgespult_tage = vorgespult;
  if (lauf) m.lauf = lauf;
  return m;
}

type Ergebnis = { ok: boolean; http: number; signiert: boolean; portal: unknown; fehler?: string };

async function melden(felder: Record<string, unknown>): Promise<Ergebnis> {
  const rumpf = JSON.stringify(felder);
  const h: Record<string, string> = { "Content-Type": "application/json" };
  const sig = await signieren(rumpf);
  if (sig) h["x-partnershop-signatur"] = sig;
  const abbruch = new AbortController();
  const uhr = setTimeout(() => abbruch.abort(), MELDEN_FRIST_MS);
  try {
    const r = await fetch(POSTBACK_URL, { method: "POST", headers: h, body: rumpf, signal: abbruch.signal });
    const text = await r.text();
    let portal: unknown = text.slice(0, 500);
    try { portal = JSON.parse(text); } catch (_) { /* dann bleibt es Text */ }
    return { ok: r.ok, http: r.status, signiert: !!sig, portal };
  } catch (e) {
    return { ok: false, http: 0, signiert: !!sig, portal: null, fehler: (e as Error).name + ": " + (e as Error).message };
  } finally {
    clearTimeout(uhr);
  }
}

// Was von der Antwort des Portals in der Zeile des Shops stehen bleibt.
function beleg(e: Ergebnis): Record<string, unknown> {
  const p = (e.portal && typeof e.portal === "object") ? e.portal as Record<string, unknown> : {};
  return {
    http: e.http, signiert: e.signiert, angenommen: p.angenommen ?? null, id: p.id ?? null,
    klick_bekannt: p.klick_bekannt ?? null, signatur: p.signatur ?? null, qualitaet: p.qualitaet ?? null,
    fehler: e.fehler ?? null,
  };
}

async function zeileAendern(id: number, felder: Record<string, unknown>): Promise<Zeile | null> {
  const r = await rest("/partnershop_bestellungen?id=eq." + id, {
    method: "PATCH",
    headers: { Prefer: "return=representation" },
    body: JSON.stringify(felder),
  });
  if (!r.ok) {
    console.error("partnershop_bestellungen aendern fehlgeschlagen", r.status, await r.text());
    return null;
  }
  return ((await r.json()) as Zeile[])[0] || null;
}

// Eine Zeile fuer einen Lauf sperren, in einem Schritt je Bedingung: frei,
// oder die Sperre eines anderen Laufs ist aelter als SPERRE_S. Jede Bedingung
// ist ein eigenes PATCH mit einfachem Filter und damit ein einzelnes UPDATE in
// Postgres. Ein or-Filter ginge in einem Aufruf, aber PostgREST wendet ihn bei
// return=representation auf die schon geaenderte Zeile noch einmal an und
// liefert dann eine leere Liste, obwohl die Sperre gesetzt ist.
async function sperren(id: number, jetzt: Date): Promise<Zeile | null> {
  const frei = new Date(jetzt.getTime() - SPERRE_S * 1000).toISOString();
  for (const bedingung of ["in_arbeit_seit=is.null", "in_arbeit_seit=lt." + encodeURIComponent(frei)]) {
    const r = await rest("/partnershop_bestellungen?id=eq." + id + "&" + bedingung, {
      method: "PATCH",
      headers: { Prefer: "return=representation" },
      body: JSON.stringify({ in_arbeit_seit: new Date().toISOString() }),
    });
    if (r.ok) {
      const z = (await r.json()) as Zeile[];
      if (z[0]) return z[0];
    } else {
      console.error("Sperre nicht gesetzt", r.status, await r.text());
    }
  }
  return null;
}

// ---------------------------------------------------------------------
// Pfad 1: bestellen
// ---------------------------------------------------------------------
async function bestellen(req: Request, origin: string | null): Promise<Response> {
  const p = await parameterLesen(req);
  const gruende: string[] = [];
  if (origin && !herkunftPruefen(origin)) gruende.push("fremde Herkunft");

  const klickRoh = (p.klick || p.cbk || "").trim();
  let klick: string | null = null;
  if (!klickRoh) gruende.push("ohne Klick-ID");
  else if (!/^[A-Za-z0-9-]{8,64}$/.test(klickRoh)) gruende.push("Klick-ID in unerwarteter Form, nicht uebernommen");
  else klick = klickRoh;

  let wert = parseFloat(String(p.wert ?? "").replace(",", "."));
  if (!Number.isFinite(wert) || wert <= 0) { gruende.push("Bestellwert fehlt oder keine Zahl, 149 angenommen"); wert = 149; }
  if (wert > 100000) { gruende.push("Bestellwert ueber 100000 gekappt"); wert = 100000; }
  wert = Math.round(wert * 100) / 100;

  const vorgabe = p.ausgang === "storno" || p.ausgang === "freigabe" ? p.ausgang : "";
  const ausgang = (vorgabe || (zufall() < STORNO_ANTEIL ? "storno" : "freigabe")) as "freigabe" | "storno";
  const tage = ausgang === "storno"
    ? STORNO_TAGE_VON + Math.floor(zufall() * (STORNO_TAGE_BIS - STORNO_TAGE_VON + 1))
    : FREIGABE_TAGE;
  const jetzt = new Date();

  const neu = {
    bestellnummer: "",
    bestellt_am: jetzt.toISOString(),
    klick_id: klick,
    kampagne: kappen(p.kampagne, 40),
    shop: kappen(p.shop, 80),
    bestellwert: wert,
    waehrung: "EUR",
    ausgang,
    ausgang_grund: vorgabe ? "vorgegeben" : "gewuerfelt",
    abschluss_faellig_am: new Date(jetzt.getTime() + tage * TAG_MS).toISOString(),
    qualitaet: gruende.length ? gruende.join("; ") : "ok",
  };

  // Eine Bestellnummer, die es schon gibt, ist bei 16 Millionen Moeglichkeiten
  // selten; ein zweiter Versuch mit neuer Nummer genuegt.
  let zeile: Zeile | null = null;
  for (let versuch = 0; versuch < 3 && !zeile; versuch++) {
    neu.bestellnummer = bestellnummerVergeben();
    const r = await rest("/partnershop_bestellungen", {
      method: "POST", headers: { Prefer: "return=representation" }, body: JSON.stringify(neu),
    });
    if (r.ok) { zeile = ((await r.json()) as Zeile[])[0]; break; }
    const text = await r.text();
    if (r.status !== 409) {
      console.error("partnershop_bestellungen schreiben fehlgeschlagen", r.status, text);
      return antwort({ fehler: "Bestellung nicht gespeichert", status: r.status }, 502, origin);
    }
  }
  if (!zeile) return antwort({ fehler: "keine freie Bestellnummer gefunden" }, 502, origin);

  // Die Meldung geht sofort hinaus, aus eigenem Antrieb, von diesem Server.
  // Scheitert sie, bleibt bestellung_gemeldet_am leer, und der Lauf holt sie nach.
  const e = await melden(meldungBauen(zeile, "bestellung", jetzt, 0, null));
  const nachher = await zeileAendern(zeile.id, {
    bestellung_gemeldet_am: e.ok ? new Date().toISOString() : null,
    bestellung_antwort: beleg(e),
    versuche: 1,
    letzter_fehler: e.ok ? null : ("Meldung bestellung: " + (e.fehler || "HTTP " + e.http)),
  });

  return antwort({
    bestellnummer: zeile.bestellnummer,
    bestellt_am: zeile.bestellt_am,
    bestellwert: Number(zeile.bestellwert),
    klick_id: zeile.klick_id,
    status: "offen",
    ausgang: zeile.ausgang,
    ausgang_grund: neu.ausgang_grund,
    abschluss_faellig_am: zeile.abschluss_faellig_am,
    qualitaet: zeile.qualitaet,
    meldung: {
      an: POSTBACK_URL,
      art: "bestellung",
      status: "offen",
      gesendet_vom: "Server des Shops",
      signiert: e.signiert,
      angenommen: e.ok,
      http: e.http,
      portal: e.portal,
    },
    gespeichert: !!nachher,
  }, 200, origin);
}

// ---------------------------------------------------------------------
// Pfad 2: status einer Bestellung
// ---------------------------------------------------------------------
async function status(req: Request, origin: string | null): Promise<Response> {
  const nummer = new URL(req.url).searchParams.get("bestellnummer") || "";
  if (!/^B-[0-9A-F]{6}$/.test(nummer)) return antwort({ fehler: "Parameter bestellnummer fehlt oder ist ungueltig" }, 400, origin);
  const r = await rest("/partnershop_bestellungen?bestellnummer=eq." + encodeURIComponent(nummer) +
    "&select=bestellnummer,bestellt_am,klick_id,bestellwert,status,ausgang,ausgang_grund,abschluss_faellig_am," +
    "bestellung_gemeldet_am,abschluss_gemeldet_am,abschluss_uhr_shop,vorgespult_tage,versuche,letzter_fehler,qualitaet");
  if (!r.ok) return antwort({ fehler: "Tabelle nicht lesbar", status: r.status }, 502, origin);
  const z = await r.json();
  return antwort({ bestellnummer: nummer, vorhanden: z.length > 0, bestellung: z[0] || null,
                   abgefragt_am: new Date().toISOString() }, 200, origin);
}

// ---------------------------------------------------------------------
// Pfad 3: der Lauf
// ---------------------------------------------------------------------
async function lauf(req: Request, origin: string | null): Promise<Response> {
  const p = await parameterLesen(req);
  const roh = parseInt(p.vorspulen_tage || "0", 10);
  const vorgespult = Number.isFinite(roh) ? Math.min(Math.max(roh, 0), VORSPULEN_MAX_TAGE) : 0;
  const nummer = p.bestellnummer || "";
  if (nummer && !/^B-[0-9A-F]{6}$/.test(nummer)) {
    return antwort({ fehler: "Parameter bestellnummer ist ungueltig" }, 400, origin);
  }
  const jetzt = new Date();
  const uhrShop = new Date(jetzt.getTime() + vorgespult * TAG_MS);
  const laufId = crypto.randomUUID().slice(0, 8);

  // Faellig ist, was noch nicht als Bestellung gemeldet wurde, und jeder
  // Abschluss, dessen Zeitpunkt die Uhr des Shops erreicht hat.
  let q = "/partnershop_bestellungen?select=*" +
    "&or=" + encodeURIComponent("(bestellung_gemeldet_am.is.null,and(abschluss_gemeldet_am.is.null,abschluss_faellig_am.lte.\"" +
                                uhrShop.toISOString() + "\"))") +
    "&order=bestellt_am.asc&limit=" + LAUF_GRENZE;
  if (nummer) q += "&bestellnummer=eq." + encodeURIComponent(nummer);
  const r = await rest(q);
  if (!r.ok) {
    console.error("Lauf: Tabelle nicht lesbar", r.status, await r.text());
    return antwort({ fehler: "Tabelle nicht lesbar", status: r.status }, 502, origin);
  }
  const kandidaten = (await r.json()) as Zeile[];

  const gemeldet: Record<string, unknown>[] = [];
  const fehler: Record<string, unknown>[] = [];
  const uebersprungen: string[] = [];

  for (const k of kandidaten) {
    // Die Zeile fuer diesen Lauf sperren. Hat ein anderer Lauf sie in den
    // letzten zwei Minuten genommen, kommt nichts zurueck, und sie bleibt ihm.
    const gesperrt = await sperren(k.id, jetzt);
    if (!gesperrt) { uebersprungen.push(k.bestellnummer); continue; }
    let b: Zeile = gesperrt;
    let versuche = b.versuche || 0;

    if (!b.bestellung_gemeldet_am) {
      const e = await melden(meldungBauen(b, "bestellung", uhrShop, vorgespult, laufId));
      versuche++;
      const z = await zeileAendern(b.id, {
        bestellung_gemeldet_am: e.ok ? new Date().toISOString() : null,
        bestellung_antwort: beleg(e),
        versuche,
        letzter_fehler: e.ok ? null : ("Meldung bestellung: " + (e.fehler || "HTTP " + e.http)),
        ...(e.ok ? {} : { in_arbeit_seit: null }),
      });
      if (!e.ok) { fehler.push({ bestellnummer: b.bestellnummer, was: "bestellung", ...beleg(e) }); continue; }
      gemeldet.push({ bestellnummer: b.bestellnummer, was: "bestellung", status: "offen", nachgeholt: true, ...beleg(e) });
      if (z) b = z;
    }

    if (!b.abschluss_gemeldet_am && new Date(b.abschluss_faellig_am).getTime() <= uhrShop.getTime()) {
      const was = b.ausgang === "storno" ? "storno" : "freigabe";
      const e = await melden(meldungBauen(b, was, uhrShop, vorgespult, laufId));
      versuche++;
      await zeileAendern(b.id, e.ok ? {
        status: was === "storno" ? "storniert" : "bestaetigt",
        abschluss_gemeldet_am: new Date().toISOString(),
        abschluss_uhr_shop: uhrShop.toISOString(),
        vorgespult_tage: vorgespult > 0 ? vorgespult : null,
        abschluss_antwort: beleg(e),
        versuche,
        letzter_fehler: null,
        in_arbeit_seit: null,
      } : {
        abschluss_antwort: beleg(e),
        versuche,
        letzter_fehler: "Meldung " + was + ": " + (e.fehler || "HTTP " + e.http),
        in_arbeit_seit: null,
      });
      if (e.ok) {
        gemeldet.push({ bestellnummer: b.bestellnummer, was, status: was === "storno" ? "storniert" : "bestaetigt",
                        faellig_am: b.abschluss_faellig_am, ...beleg(e) });
      } else {
        fehler.push({ bestellnummer: b.bestellnummer, was, ...beleg(e) });
      }
    } else {
      await zeileAendern(b.id, { in_arbeit_seit: null });
    }
  }

  // Wer nach einer bestimmten Bestellung fragt, bekommt auch dann eine
  // Antwort, wenn nichts faellig war: wann sie es sein wird.
  let bestellung: unknown = null;
  if (nummer) {
    const rb = await rest("/partnershop_bestellungen?bestellnummer=eq." + encodeURIComponent(nummer) +
      "&select=bestellnummer,status,ausgang,abschluss_faellig_am,bestellung_gemeldet_am,abschluss_gemeldet_am,abschluss_uhr_shop,vorgespult_tage");
    if (rb.ok) bestellung = ((await rb.json()) as unknown[])[0] || null;
  }

  return antwort({
    lauf: laufId,
    jetzt_server: jetzt.toISOString(),
    uhr_shop: uhrShop.toISOString(),
    vorgespult_tage: vorgespult,
    bestellnummer: nummer || null,
    geprueft: kandidaten.length,
    gemeldet,
    fehler,
    uebersprungen,
    bestellung,
    signiert: !!SCHLUESSEL,
  }, 200, origin);
}

Deno.serve(async (req: Request) => {
  const origin = req.headers.get("origin");
  if (req.method === "OPTIONS") return new Response(null, { status: 204, headers: kopfzeilen(origin, false) });

  const teile = new URL(req.url).pathname.split("/").filter(Boolean);
  const pfad = teile[teile.length - 1] === "partnershop" ? "" : teile[teile.length - 1];

  try {
    if (pfad === "" && req.method === "POST") return await bestellen(req, origin);
    if (pfad === "status" && req.method === "GET") return await status(req, origin);
    if (pfad === "lauf" && req.method === "POST") return await lauf(req, origin);
    return antwort({ fehler: "unbekannter Pfad oder Methode" }, 404, origin);
  } catch (e) {
    console.error("partnershop: unerwarteter Fehler", e);
    return antwort({ fehler: "unerwarteter Fehler" }, 500, origin);
  }
});
