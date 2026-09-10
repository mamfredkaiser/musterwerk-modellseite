// =====================================================================
// postback: der Rueckkanal-Endpunkt des Portals
// Supabase Edge Function, Deno. Stand 10.09.2026, Arbeitspaket 4; Signatur
// am Server-Eingang ergaenzt am 10.09.2026 abends (Arbeitspaket 5, Nachtrag).
//
// Zwei Rollen in einer Funktion, getrennt ueber den Pfad:
//
//   GET  /postback?art=landung&klick=...&partner=...      der Pixel. Ein Bild,
//        das die Partnerseite im Browser des Nutzers laedt. Antwort: ein
//        1x1-GIF, kein Cookie, kein Speicher. Er ist blockierbar, er braucht
//        die Klick-ID auf der Partnerseite, und er kommt nur, solange der
//        Nutzer die Seite offen hat.
//
//   POST /postback/partnershop  { art, klick, code, bestellnummer, wert, ... }
//        der Server des Partners. Im Modell hat der Partner kein eigenes
//        Backend, deshalb spielt diese Funktion unter diesem Pfad dessen
//        Shopsystem und meldet die Bestellung intern an den Portal-Endpunkt
//        weiter. Die Zeile traegt weg = s2s. Der Unterschied zum Pixel ist
//        nicht die Technik, sondern wer meldet und wann: der Server meldet
//        auch dann, wenn der Browser laengst zu ist, und er meldet Storno
//        und Freigabe Wochen spaeter.
//
// Arten: landung, bestellung, storno, code_einloesung. Die letzte kommt ohne
// Klick-ID und traegt nur den Gutscheincode; die Zuordnung zum Klick ist
// dann eine Zuordnung zur Belegung und zum Monat, nicht zur Person.
//
// Eine Meldung mit unbekannter Klick-ID wird geschrieben und markiert
// (klick_bekannt = false). Verwerfen waere bequemer und wuerde genau den
// Beleg vernichten, dass der Weiterleitungs-Endpunkt eine Zeile nicht hatte.
//
// Seit dem Nachtrag vom 10.09.2026 abends hat der Partner einen eigenen
// Server, die Edge Function partnershop. Sie meldet an denselben Pfad
// /postback/partnershop, von Server zu Server, und signiert jede Meldung mit
// HMAC-SHA256 ueber Zeitstempel und Rumpf (Kopf x-partnershop-signatur,
// t=<Sekunden>,v1=<hex>), wenn das Secret PARTNERSHOP_SCHLUESSEL gesetzt ist.
// Dieser Pfad prueft die Signatur und schreibt das Ergebnis in
// parameter.signatur: geprueft, fehlt, falsch, veraltet, unlesbar, oder
// keine, wenn das Portal selbst kein Secret hat. Eine Meldung ohne gueltige
// Signatur wird trotzdem geschrieben, mit dem Grund in qualitaet; im Betrieb
// gehoerte sie in eine Quarantaene statt in den Bestand. Der alte Weg aus dem
// Browser der Partnerseite bleibt als Schalterstellung erhalten und ist an der
// fehlenden Signatur zu erkennen.
// =====================================================================

const SUPABASE_URL = Deno.env.get("SUPABASE_URL")!;
const DIENSTSCHLUESSEL = Deno.env.get("SUPABASE_SERVICE_ROLE_KEY")!;

const ERLAUBTE_HERKUNFT = [
  "https://mamfredkaiser.github.io",
];

// Das gemeinsame Geheimnis mit dem Server des Partners. Supabase setzt es als
// Secret der Edge Functions; im Vault und im Repo steht es nicht.
const PARTNERSHOP_SCHLUESSEL = Deno.env.get("PARTNERSHOP_SCHLUESSEL") || "";
const SIGNATUR_TOLERANZ_S = 300;   // aeltere Signaturen gelten als wiederholt eingespielt

const ARTEN = new Set(["landung", "bestellung", "storno", "code_einloesung"]);
const PARTNER = new Set(["deeplink", "gutschein", "ohne"]);

// 1x1 transparentes GIF, 43 Byte. Das ist der ganze Pixel.
const GIF = Uint8Array.from(atob("R0lGODlhAQABAIAAAAAAAP///yH5BAEAAAAALAAAAAABAAEAAAIBRAA7"), (c) => c.charCodeAt(0));

function herkunftPruefen(origin: string | null): string | null {
  if (!origin) return null;
  return ERLAUBTE_HERKUNFT.includes(origin) ? origin : null;
}

function kopfzeilen(origin: string | null, art: "json" | "gif" | "leer"): Record<string, string> {
  const h: Record<string, string> = { "Cache-Control": "no-store, private", "Vary": "Origin" };
  if (art === "json") h["Content-Type"] = "application/json; charset=utf-8";
  if (art === "gif") { h["Content-Type"] = "image/gif"; h["Content-Length"] = String(GIF.length); }
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

// Wie parameterLesen, aber aus einem schon gelesenen Rumpf. Der Server-Eingang
// braucht den Rumpf als Text, weil die Signatur ueber genau diese Bytes geht.
function parameterAusRumpf(req: Request, rumpf: string): Record<string, string> {
  const p: Record<string, string> = {};
  for (const [k, v] of new URL(req.url).searchParams) p[k] = v;
  const typ = req.headers.get("content-type") || "";
  try {
    if (typ.includes("application/json")) {
      const o = rumpf ? JSON.parse(rumpf) : {};
      for (const k of Object.keys(o ?? {})) if (o[k] !== null && o[k] !== undefined) p[k] = String(o[k]);
    } else {
      for (const [k, v] of new URLSearchParams(rumpf)) p[k] = v;
    }
  } catch (_) {
    p["__rumpf"] = "nicht lesbar";
  }
  return p;
}

function hexZuBytes(hex: string) {
  const b = new Uint8Array(new ArrayBuffer(hex.length / 2));
  for (let i = 0; i < b.length; i++) b[i] = parseInt(hex.slice(2 * i, 2 * i + 2), 16);
  return b;
}

// crypto.subtle.verify vergleicht in konstanter Zeit; ein Vergleich der
// Zeichenketten mit === wuerde verraten, wie viele Stellen schon stimmen.
async function signaturPruefen(kopf: string | null, rumpf: string): Promise<string> {
  if (!PARTNERSHOP_SCHLUESSEL) return "keine";
  if (!kopf) return "fehlt";
  const teile: Record<string, string> = {};
  for (const stueck of kopf.split(",")) {
    const i = stueck.indexOf("=");
    if (i > 0) teile[stueck.slice(0, i).trim()] = stueck.slice(i + 1).trim();
  }
  const t = parseInt(teile.t || "", 10);
  if (!Number.isFinite(t) || !/^[0-9a-f]{64}$/.test(teile.v1 || "")) return "unlesbar";
  if (Math.abs(Date.now() / 1000 - t) > SIGNATUR_TOLERANZ_S) return "veraltet";
  const k = new TextEncoder();
  const schluessel = await crypto.subtle.importKey("raw", k.encode(PARTNERSHOP_SCHLUESSEL),
    { name: "HMAC", hash: "SHA-256" }, false, ["verify"]);
  const ok = await crypto.subtle.verify("HMAC", schluessel, hexZuBytes(teile.v1), k.encode(t + "." + rumpf));
  return ok ? "geprueft" : "falsch";
}

const SIGNATUR_GRUND: Record<string, string> = {
  fehlt: "Server-Meldung ohne Signatur",
  falsch: "Signatur falsch",
  veraltet: "Signatur aelter als fuenf Minuten",
  unlesbar: "Signatur unlesbar",
};

async function rest(pfad: string, init: RequestInit = {}): Promise<Response> {
  const h: Record<string, string> = {
    apikey: DIENSTSCHLUESSEL,
    Authorization: "Bearer " + DIENSTSCHLUESSEL,
    "Content-Type": "application/json",
    ...(init.headers as Record<string, string> || {}),
  };
  return await fetch(SUPABASE_URL + "/rest/v1" + pfad, { ...init, headers: h });
}

function zeitLesen(wert: string | undefined, gruende: string[], name: string): string | null {
  if (!wert) return null;
  const d = new Date(wert);
  if (isNaN(d.getTime())) { gruende.push(name + " nicht lesbar"); return null; }
  return d.toISOString();
}

// Die eigentliche Verbuchung, fuer beide Wege gleich.
async function verbuchen(p: Record<string, string>, weg: "pixel" | "s2s", req: Request, origin: string | null,
                         signatur?: string) {
  const gruende: string[] = [];
  if (signatur && SIGNATUR_GRUND[signatur]) gruende.push(SIGNATUR_GRUND[signatur]);
  const art = ARTEN.has(p.art) ? p.art : "unbekannt";
  if (art === "unbekannt") gruende.push("Art unbekannt oder fehlt");
  const partner = PARTNER.has(p.partner) ? p.partner : (p.partner ? p.partner : null);
  if (!partner) gruende.push("ohne Partner");
  if (origin && !herkunftPruefen(origin)) gruende.push("fremde Herkunft");

  const klick = p.klick || null;
  const code = p.code || null;
  if (art === "code_einloesung" && !code) gruende.push("Code-Einloesung ohne Code");
  if (art !== "code_einloesung" && !klick) gruende.push("ohne Klick-ID");
  if (art === "code_einloesung" && klick) gruende.push("Code-Einloesung traegt eine Klick-ID, die der Weg nicht hergibt");

  let wert: number | null = null;
  if (p.wert !== undefined && p.wert !== "") {
    const z = parseFloat(String(p.wert).replace(",", "."));
    if (Number.isFinite(z)) wert = Math.round(z * 100) / 100; else gruende.push("Wert keine Zahl");
  }

  // Gab es die Klick-ID? Das ist die Frage, um die es geht.
  let bekannt: boolean | null = null;
  if (klick) {
    const r = await rest("/klickouts?klick_id=eq." + encodeURIComponent(klick) + "&select=klick_id,angekommen_am");
    if (r.ok) {
      const z = await r.json();
      bekannt = z.length > 0;
      if (!bekannt) gruende.push("Klick-ID unbekannt");
      // Erste Landung: angekommen_am nachtragen, nur wenn noch leer.
      if (bekannt && art === "landung" && !z[0].angekommen_am) {
        await rest("/klickouts?klick_id=eq." + encodeURIComponent(klick) + "&angekommen_am=is.null", {
          method: "PATCH",
          headers: { Prefer: "return=minimal" },
          body: JSON.stringify({ angekommen_am: new Date().toISOString() }),
        });
      }
    }
  }

  const statusVorgabe: Record<string, string | null> = {
    landung: null, bestellung: "offen", storno: "storniert", code_einloesung: "offen", unbekannt: null,
  };
  const bekannteFelder = new Set(["art", "klick", "code", "partner", "bestellnummer", "wert", "waehrung", "status",
                                  "bestellt_am", "gemeldet_am", "t", "weg"]);
  const restParameter: Record<string, string> = {};
  for (const k of Object.keys(p)) if (!bekannteFelder.has(k)) restParameter[k] = p[k];
  if (p.t) restParameter.t_client = p.t;
  if (signatur) restParameter.signatur = signatur;

  const zeile = {
    gemeldet_am: zeitLesen(p.gemeldet_am, gruende, "gemeldet_am") || new Date().toISOString(),
    bestellt_am: zeitLesen(p.bestellt_am, gruende, "bestellt_am"),
    quelle: "live",
    art,
    weg,
    partner,
    klick_id: klick,
    code,
    bestellnummer: p.bestellnummer || null,
    bestellwert: wert,
    waehrung: p.waehrung || "EUR",
    status: p.status || statusVorgabe[art],
    klick_bekannt: bekannt,
    // Eine Meldung mit gepruefter Signatur kommt von einem Server und hat keine
    // Geraeteklasse, wie die Server-Zeilen im synthetischen Grundbestand.
    geraeteklasse: signatur === "geprueft" ? null : geraeteklasse(req.headers.get("user-agent")),
    parameter: restParameter,
    qualitaet: gruende.length ? gruende.join("; ") : "ok",
  };

  const r = await rest("/postbacks", { method: "POST", headers: { Prefer: "return=representation" }, body: JSON.stringify(zeile) });
  if (!r.ok) {
    console.error("postbacks schreiben fehlgeschlagen", r.status, await r.text());
    return { ok: false, zeile, id: null };
  }
  const gespeichert = (await r.json())[0] || {};
  return { ok: true, zeile, id: gespeichert.id ?? null };
}

Deno.serve(async (req: Request) => {
  const origin = req.headers.get("origin");
  if (req.method === "OPTIONS") return new Response(null, { status: 204, headers: kopfzeilen(origin, "leer") });

  const teile = new URL(req.url).pathname.split("/").filter(Boolean);
  const pfad = teile[teile.length - 1] === "postback" ? "" : teile[teile.length - 1];

  try {
    // Rolle Partner-Server
    if (pfad === "partnershop" && req.method === "POST") {
      const rumpf = await req.text();
      const p = parameterAusRumpf(req, rumpf);
      const signatur = await signaturPruefen(req.headers.get("x-partnershop-signatur"), rumpf);
      const e = await verbuchen(p, "s2s", req, origin, signatur);
      return new Response(JSON.stringify({
        angenommen: e.ok, id: e.id, art: e.zeile.art, klick_id: e.zeile.klick_id, code: e.zeile.code,
        klick_bekannt: e.zeile.klick_bekannt, status: e.zeile.status, qualitaet: e.zeile.qualitaet,
        weg: "s2s", gemeldet_am: e.zeile.gemeldet_am, signatur,
      }), { status: e.ok ? 200 : 502, headers: kopfzeilen(origin, "json") });
    }

    // Rolle Portal-Endpunkt: der Pixel (GET) oder ein fetch von der Partnerseite (POST)
    if (pfad === "" && (req.method === "GET" || req.method === "POST")) {
      const p = await parameterLesen(req);
      const e = await verbuchen(p, "pixel", req, origin);
      const willJson = (req.headers.get("accept") || "").includes("application/json") || p.antwort === "json";
      if (willJson) {
        return new Response(JSON.stringify({
          angenommen: e.ok, id: e.id, art: e.zeile.art, klick_id: e.zeile.klick_id,
          klick_bekannt: e.zeile.klick_bekannt, qualitaet: e.zeile.qualitaet, weg: "pixel",
        }), { status: e.ok ? 200 : 502, headers: kopfzeilen(origin, "json") });
      }
      // Ein Pixel antwortet immer mit dem Bild, auch wenn das Schreiben scheiterte:
      // die Partnerseite darf von der Messung nichts merken. Der Fehler steht im Protokoll.
      return new Response(GIF, { status: 200, headers: kopfzeilen(origin, "gif") });
    }

    return new Response(JSON.stringify({ fehler: "unbekannter Pfad oder Methode" }), { status: 404, headers: kopfzeilen(origin, "json") });
  } catch (e) {
    console.error("postback: unerwarteter Fehler", e);
    return new Response(GIF, { status: 200, headers: kopfzeilen(origin, "gif") });
  }
});
