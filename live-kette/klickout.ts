// =====================================================================
// klickout: der Weiterleitungs-Endpunkt der Klick-out-Strecke
// Supabase Edge Function, Deno. Stand 10.09.2026, Arbeitspaket 4.
//
// Drei Pfade:
//   POST oder GET  /klickout            schreibt die Klick-ID in public.klickouts
//                                       und antwortet mit dem Ziel beim Partner
//   GET            /klickout/status     sagt, ob eine Klick-ID in der Tabelle steht
//   GET            /klickout/trichter   liefert den Trichter je Partnerart und die
//                                       letzten Klick-IDs mit ihren vier Wahrheiten
//
// Das Ziel kommt aus der Datenbank, nicht aus der Adresse. Wer die Zieladresse
// vom Browser entgegennimmt, baut eine offene Weiterleitung, und die ist die
// Stelle, an der ein Portal fuer Phishing missbraucht wird. Die Seite schickt
// Angebot und Anbieter, der Server schlaegt nach, welche Partnerseite dazu
// gehoert, und sagt es der Seite erst nach dem Schreiben.
//
// Die drei Fehlerfaelle sind Absicht und ueber den Parameter `fall` schaltbar:
//   langsam   der Server wartet sieben Sekunden, bevor er schreibt. Der Browser
//             gibt nach fuenf Sekunden auf und leitet ohne Bestaetigung weiter
//             oder der Nutzer bricht ab. Die Zeile entsteht trotzdem.
//   fehler    der Server antwortet 500 und schreibt nichts. Leitet der Browser
//             trotzdem weiter, kennt der Partner eine Klick-ID, die es in der
//             Tabelle nie gab.
//   abbruch   der Server braucht 600 ms, wie ein Endpunkt unter Last; der
//             Browser bricht den Request nach 250 ms ab. Der Server hat ihn
//             da laengst, die Zeile entsteht trotzdem, und niemand kommt beim
//             Partner an. Ohne die 600 ms waere der Ausgang ein Wettlauf, und
//             eine Vorfuehrung darf nicht vom Zufall abhaengen.
//
// Was die Funktion nicht tut: keine IP speichern, keinen User-Agent im
// Klartext, kein Set-Cookie. Keine Zeile verwerfen: Auffaelliges bekommt einen
// Grund in `qualitaet`. JWT-Pruefung muss aus sein, siehe deploy.md.
// =====================================================================

const SUPABASE_URL = Deno.env.get("SUPABASE_URL")!;
const DIENSTSCHLUESSEL = Deno.env.get("SUPABASE_SERVICE_ROLE_KEY")!;

// Wo die Partnerseiten liegen. Sie gehoeren im Modell einem anderen Haus und
// liegen hier nur deshalb im selben Repo, weil GitHub Pages je Konto eine
// Herkunft hat. Der Unterschied steht auf jeder Partnerseite oben.
const PARTNER_BASIS = "https://mamfredkaiser.github.io/musterwerk-modellseite/partner/";

const ERLAUBTE_HERKUNFT = [
  "https://mamfredkaiser.github.io",
];

const WARTEZEIT_LANGSAM_MS = 7000;
const WARTEZEIT_ABBRUCH_MS = 600;

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

function geraeteklasse(ua: string | null): string {
  if (!ua) return "unbekannt";
  const s = ua.toLowerCase();
  if (/bot|crawl|spider|slurp|headless|curl|wget|python-requests|httpx|playwright/.test(s)) return "Bot";
  if (/mobile|android|iphone|ipad|ipod/.test(s)) return "Mobil";
  return "Desktop";
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
      } else if (typ.includes("application/x-www-form-urlencoded") || typ.includes("text/plain")) {
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

// Angebot und Anbieter nachschlagen. Zwei kleine Abfragen statt einer
// eingebetteten, damit die Funktion nicht an der Fremdschluessel-Erkennung
// von PostgREST haengt.
async function katalogNachschlagen(angebotId: string, anbieterId: string) {
  let angebot: Record<string, unknown> | null = null;
  let anbieter: Record<string, unknown> | null = null;
  const gruende: string[] = [];
  if (angebotId) {
    const r = await rest("/angebote?angebot_id=eq." + encodeURIComponent(angebotId) +
                         "&select=angebot_id,titel,kategorie,unterkategorie,anbieter_id,typ");
    if (r.ok) { const z = await r.json(); angebot = z[0] || null; }
    if (!angebot) gruende.push("Angebot im Katalog unbekannt");
  } else {
    gruende.push("ohne Angebot");
  }
  const anId = (angebot && String(angebot.anbieter_id)) || anbieterId;
  if (angebot && anbieterId && angebot.anbieter_id !== anbieterId) {
    gruende.push("Anbieter der Seite passt nicht zum Katalog");
  }
  if (anId) {
    const r = await rest("/anbieter?anbieter_id=eq." + encodeURIComponent(anId) +
                         "&select=anbieter_id,name,rueckkanal,netzwerk");
    if (r.ok) { const z = await r.json(); anbieter = z[0] || null; }
    if (!anbieter) gruende.push("Anbieter im Katalog unbekannt");
  }
  return { angebot, anbieter, gruende };
}

// Dieselbe Regel wie in public.klickout_trichter: welcher Partnertyp zu einem
// Angebot gehoert. Wer sie aendert, aendert sie an beiden Stellen.
function partnerArt(typ: string, rueckkanal: string): string {
  if (rueckkanal === "keiner") return "ohne";
  if (typ === "Code" || rueckkanal === "Code") return "gutschein";
  return "deeplink";
}

function zielBauen(partner: string, klick: string, angebotId: string, code: string,
                   shop: string, titel: string): string {
  // An den Partner geht die Klick-ID als Referenz und ein Kampagnensatz fuer
  // dessen eigene Messung. Kein Mandant, kein userKey, keine Sitzungskennung:
  // was der Partner nicht braucht, bekommt er nicht. shop und titel sind nur
  // Beschriftung der Attrappe; ein echter Partner kennt seinen Namen selbst.
  const q = new URLSearchParams();
  q.set("cbk", klick);
  q.set("utm_source", "musterwerk-vorteilsportal");
  q.set("utm_medium", "affiliate");
  q.set("utm_campaign", angebotId || "unbekannt");
  if (partner === "gutschein" && code) q.set("code", code);
  if (shop) q.set("shop", shop);
  if (titel) q.set("titel", titel);
  return PARTNER_BASIS + partner + ".html?" + q.toString();
}

const schlafen = (ms: number) => new Promise((r) => setTimeout(r, ms));

// ---------------------------------------------------------------------
// Pfad 1: schreiben
// ---------------------------------------------------------------------
async function schreiben(req: Request, origin: string | null): Promise<Response> {
  const start = Date.now();
  const kopf = kopfzeilen(origin);
  const p = await parameterLesen(req);
  const fall = ["langsam", "fehler", "abbruch"].includes(p.fall) ? p.fall : "keiner";

  if (fall === "fehler") {
    // Vorgefuehrter Serverfehler: nichts wird geschrieben, absichtlich.
    return new Response(JSON.stringify({
      fehler: "vorgefuehrter Serverfehler", geschrieben: false, fall,
      hinweis: "Die Klick-ID steht in keiner Tabelle. Leitet der Browser trotzdem weiter, kennt nur der Partner sie.",
    }), { status: 500, headers: kopf });
  }
  if (fall === "langsam") await schlafen(WARTEZEIT_LANGSAM_MS);
  if (fall === "abbruch") await schlafen(WARTEZEIT_ABBRUCH_MS);

  const gruende: string[] = [];
  const klick = p.klick || crypto.randomUUID();
  if (!p.klick) gruende.push("Klick-ID fehlte, vom Server vergeben");
  if (!p.sid) gruende.push("ohne Sitzungskennung");
  if (!p.mandant) gruende.push("ohne Mandant");
  if (origin && !herkunftPruefen(origin)) gruende.push("fremde Herkunft");

  const { angebot, anbieter, gruende: katalogGruende } = await katalogNachschlagen(p.angebot || "", p.anbieter || "");
  gruende.push(...katalogGruende);

  const typ = angebot ? String(angebot.typ) : (p.typ || "Deeplink");
  const rueckkanal = anbieter ? String(anbieter.rueckkanal) : "unbekannt";
  const partner = partnerArt(typ, rueckkanal);
  const ziel = zielBauen(partner, klick, p.angebot || "", p.code || "",
                         anbieter ? String(anbieter.name) : "", angebot ? String(angebot.titel) : "");

  let erzeugtAm: string | null = null;
  if (p.ts) {
    const d = new Date(p.ts);
    if (isNaN(d.getTime())) gruende.push("Zeitstempel nicht lesbar"); else erzeugtAm = d.toISOString();
  }

  const bekannt = new Set(["klick", "sid", "mandant", "angebot", "anbieter", "belegung", "code", "mediacode",
                           "strecke", "userKey", "ts", "fall", "typ", "plattform", "nc"]);
  const restParameter: Record<string, string> = {};
  for (const k of Object.keys(p)) if (!bekannt.has(k)) restParameter[k] = p[k];
  if (p.plattform) restParameter.plattform = p.plattform;

  const zeile = {
    klick_id: klick,
    erzeugt_am: erzeugtAm,
    antwort_ms: null as number | null,     // wird unten gesetzt
    quelle: "live",
    mandant: p.mandant || null,
    angebot: p.angebot || null,
    anbieter: (anbieter && String(anbieter.anbieter_id)) || p.anbieter || null,
    typ,
    rueckkanal,
    partner,
    ziel,
    belegung: p.belegung || null,
    code: p.code || null,
    mediacode: p.mediacode || null,
    strecke: p.strecke || null,
    sitzung: p.sid || null,
    user_key: p.userKey || null,
    fall,
    geraeteklasse: geraeteklasse(req.headers.get("user-agent")),
    parameter: restParameter,
    qualitaet: "ok",
  };
  zeile.antwort_ms = Date.now() - start;
  zeile.qualitaet = gruende.length ? gruende.join("; ") : "ok";

  const r = await rest("/klickouts", {
    method: "POST",
    headers: { Prefer: "return=representation" },
    body: JSON.stringify(zeile),
  });

  if (!r.ok) {
    const text = await r.text();
    console.error("klickouts schreiben fehlgeschlagen", r.status, text);
    // Doppelte Klick-ID: die Zeile gibt es schon (zweiter Versuch derselben
    // Seite). Das ist kein Fehler der Strecke, die Antwort sagt es.
    if (r.status === 409) {
      return new Response(JSON.stringify({
        klick_id: klick, ziel, partner, rueckkanal, typ, geschrieben: false, doppelt: true, fall,
        antwort_ms: Date.now() - start, qualitaet: "Klick-ID stand schon in der Tabelle",
      }), { status: 200, headers: kopf });
    }
    return new Response(JSON.stringify({ fehler: "Schreiben fehlgeschlagen", status: r.status, geschrieben: false, fall }),
      { status: 502, headers: kopf });
  }

  const gespeichert = (await r.json())[0] || {};
  return new Response(JSON.stringify({
    klick_id: klick,
    ziel,
    partner,
    rueckkanal,
    typ,
    angebot_titel: angebot ? angebot.titel : null,
    anbieter_name: anbieter ? anbieter.name : null,
    geschrieben: true,
    geschrieben_am: gespeichert.geschrieben_am || null,
    fall,
    antwort_ms: Date.now() - start,
    qualitaet: zeile.qualitaet,
  }), { status: 200, headers: kopf });
}

// ---------------------------------------------------------------------
// Pfad 2: status einer Klick-ID
// ---------------------------------------------------------------------
async function status(req: Request, origin: string | null): Promise<Response> {
  const kopf = kopfzeilen(origin);
  const klick = new URL(req.url).searchParams.get("klick") || "";
  if (!klick) return new Response(JSON.stringify({ fehler: "Parameter klick fehlt" }), { status: 400, headers: kopf });

  const [rk, rp] = await Promise.all([
    rest("/klickouts?klick_id=eq." + encodeURIComponent(klick) +
         "&select=klick_id,geschrieben_am,angekommen_am,fall,partner,antwort_ms,qualitaet"),
    rest("/postbacks?klick_id=eq." + encodeURIComponent(klick) +
         "&select=art,weg,empfangen_am,bestellwert,status,klick_bekannt&order=empfangen_am.asc"),
  ]);
  const zeilen = rk.ok ? await rk.json() : [];
  const meldungen = rp.ok ? await rp.json() : [];
  return new Response(JSON.stringify({
    klick_id: klick,
    vorhanden: zeilen.length > 0,
    zeile: zeilen[0] || null,
    postbacks: meldungen,
    abgefragt_am: new Date().toISOString(),
  }), { status: 200, headers: kopf });
}

// ---------------------------------------------------------------------
// Pfad 3: der Trichter
// ---------------------------------------------------------------------
async function trichter(req: Request, origin: string | null): Promise<Response> {
  const kopf = kopfzeilen(origin);
  const q = new URL(req.url).searchParams;
  const quelle = ["live", "synthetisch", "alle"].includes(q.get("quelle") || "") ? q.get("quelle") : "live";
  const stundenRoh = parseInt(q.get("stunden") || "", 10);
  const stunden = Number.isFinite(stundenRoh) && stundenRoh > 0 ? stundenRoh : null;
  const grenze = Math.min(Math.max(parseInt(q.get("grenze") || "25", 10) || 25, 1), 200);

  const [rt, rw] = await Promise.all([
    rest("/rpc/klickout_trichter", { method: "POST", body: JSON.stringify({ p_quelle: quelle, p_stunden: stunden }) }),
    rest("/klickout_wahrheiten?select=*&limit=" + grenze),
  ]);
  if (!rt.ok) {
    console.error("klickout_trichter fehlgeschlagen", rt.status, await rt.text());
    return new Response(JSON.stringify({ fehler: "Trichter nicht lesbar", status: rt.status }), { status: 502, headers: kopf });
  }
  return new Response(JSON.stringify({
    quelle, stunden,
    zeilen: await rt.json(),
    wahrheiten: rw.ok ? await rw.json() : [],
    abgefragt_am: new Date().toISOString(),
  }), { status: 200, headers: kopf });
}

Deno.serve(async (req: Request) => {
  const origin = req.headers.get("origin");
  if (req.method === "OPTIONS") return new Response(null, { status: 204, headers: kopfzeilen(origin, false) });

  const teile = new URL(req.url).pathname.split("/").filter(Boolean);
  const pfad = teile[teile.length - 1] === "klickout" ? "" : teile[teile.length - 1];

  try {
    if (pfad === "status"   && req.method === "GET") return await status(req, origin);
    if (pfad === "trichter" && req.method === "GET") return await trichter(req, origin);
    if (pfad === "" && (req.method === "GET" || req.method === "POST")) return await schreiben(req, origin);
    return new Response(JSON.stringify({ fehler: "unbekannter Pfad oder Methode" }), { status: 404, headers: kopfzeilen(origin) });
  } catch (e) {
    console.error("klickout: unerwarteter Fehler", e);
    return new Response(JSON.stringify({ fehler: "unerwarteter Fehler" }), { status: 500, headers: kopfzeilen(origin) });
  }
});
