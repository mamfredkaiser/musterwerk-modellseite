// =====================================================================
// wtpixel: ein Trackserver im Webtrekk-Format, ohne Webtrekk
// Supabase Edge Function, Deno. Stand 10.09.2026, Arbeitspaket 4.
//
// Nimmt Requests in der Form entgegen, die ein Mapp-Intelligence-Pixel an
// seine Trackdomain schickt:
//
//   GET oder POST  /wtpixel/<track-id>/wt?p=<version>,<pageName>,<js>,<aufloesung>,
//                  <farbtiefe>,<cookies>,<clientzeit>,<referrer>,<fenster>,<java>
//                  &cg1=...&cp1=...&cs1=...&ct=...&ck1=...&mc=...&eid=...
//
// zerlegt `p` an den Kommata, benennt die zehn Positionen und schreibt eine
// Zeile in public.webtrekk_requests. Die zehn Positionen stehen so in
// docs.mapp.com/docs/request-structure (abgerufen 10.09.2026); die
// Nummernkreise cg1 bis cg499, cp1 bis cp499, cs1 bis cs499, ck1 bis ck499
// in docs.mapp.com/docs/query-parameter. Was die Doku nicht hergibt, steht
// im Belegungsplan als Annahme.
//
// Es gibt keinen echten Mapp-Zugang: Track-ID und Trackdomain vergibt nur der
// Vertrieb. Die Track-ID im Pfad ist deshalb erfunden, der Trackserver ist
// diese Funktion. Der Wert der Uebung liegt im Format, nicht im Empfaenger.
//
// Antwort: auf GET ein 1x1-GIF wie ein Bildpixel, auf POST (sendBeacon) 204.
// Kein Set-Cookie, Cache-Control no-store, keine IP, kein User-Agent im
// Klartext. JWT-Pruefung aus, siehe deploy.md.
// =====================================================================

const SUPABASE_URL = Deno.env.get("SUPABASE_URL")!;
const DIENSTSCHLUESSEL = Deno.env.get("SUPABASE_SERVICE_ROLE_KEY")!;

// Die erfundene Track-ID der Modellseite. Eine andere im Pfad ist kein
// Fehler, sie bekommt einen Vermerk.
const EIGENE_TRACK_ID = "100000000000001";

const ERLAUBTE_HERKUNFT = [
  "https://mamfredkaiser.github.io",
];

const GIF = Uint8Array.from(atob("R0lGODlhAQABAIAAAAAAAP///yH5BAEAAAAALAAAAAABAAEAAAIBRAA7"), (c) => c.charCodeAt(0));

// Die zehn Positionen von p, in der Reihenfolge der Doku.
const P_POSITIONEN = ["version", "seitenname", "javascript", "aufloesung", "farbtiefe",
                      "cookies", "clientzeit", "referrer", "fenster", "java"];

// Benannte Parameter mit eigener Spalte.
const BENANNT: Record<string, string> = {
  ct: "aktion", mc: "kampagne", mca: "kampagnenaktion", eid: "ever_id", ceid: "custom_ever_id",
  cd: "kunden_id", nc: "anonym", one: "erster_request", fns: "neue_sitzung", la: "sprache",
  pu: "seiten_url", tz: "zeitzone", eor: "ende",
};

// Nummerierte Familien, die als Abbildung Nummer zu Wert abgelegt werden.
const FAMILIEN: Record<string, string> = { cg: "inhaltsgruppen", cp: "seitenparameter", cs: "sitzungsparameter", ck: "aktionsparameter" };

// E-Commerce-Parameter, mit und ohne Nummer.
const ECOMMERCE = new Set(["ba", "co", "qn", "st", "oi", "ov"]);
const ECOMMERCE_FAMILIEN = new Set(["cb", "ca"]);

function herkunftPruefen(origin: string | null): string | null {
  if (!origin) return null;
  return ERLAUBTE_HERKUNFT.includes(origin) ? origin : null;
}

function kopfzeilen(origin: string | null, art: "gif" | "leer" | "json"): Record<string, string> {
  const h: Record<string, string> = { "Cache-Control": "no-store, private", "Vary": "Origin" };
  if (art === "gif") { h["Content-Type"] = "image/gif"; h["Content-Length"] = String(GIF.length); }
  if (art === "json") h["Content-Type"] = "application/json; charset=utf-8";
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
    // sendBeacon(url) schickt einen leeren Rumpf; ein Rumpf mit Formdaten
    // wird zusaetzlich gelesen, wie es der Trackserver auch taete.
    try {
      const t = await req.text();
      if (t) for (const [k, v] of new URLSearchParams(t)) if (!(k in p)) p[k] = v;
    } catch (_) {
      p["__rumpf"] = "nicht lesbar";
    }
  }
  return p;
}

// Zerlegt einen Parametersatz in die Zeile der Tabelle. Reine Funktion,
// damit sie sich ohne Datenbank pruefen laesst.
export function zerlegen(p: Record<string, string>, trackId: string | null, methode: string, ua: string | null) {
  const gruende: string[] = [];
  const zeile: Record<string, unknown> = {
    track_id: trackId,
    methode,
    inhaltsgruppen: {}, seitenparameter: {}, sitzungsparameter: {}, aktionsparameter: {},
    ecommerce: {}, rest: {},
    geraeteklasse: geraeteklasse(ua),
  };
  if (!trackId) gruende.push("ohne Track-ID im Pfad");
  else if (trackId !== EIGENE_TRACK_ID) gruende.push("fremde Track-ID");

  // Der Parameter p
  if (p.p === undefined || p.p === "") {
    gruende.push("ohne p");
    zeile.p_positionen = 0;
  } else {
    const teile = p.p.split(",");
    zeile.p_positionen = teile.length;
    if (teile.length < P_POSITIONEN.length) gruende.push("p hat nur " + teile.length + " Positionen");
    P_POSITIONEN.forEach((name, i) => {
      const wert = i < teile.length ? teile[i] : null;
      if (name === "clientzeit") {
        const ms = wert === null ? NaN : Number(wert);
        if (Number.isFinite(ms) && ms > 0) {
          zeile.clientzeit = new Date(ms).toISOString();
          zeile.clientzeit_roh = null;
        } else {
          zeile.clientzeit = null;
          zeile.clientzeit_roh = wert;
          if (wert !== null && wert !== "0") gruende.push("Clientzeit nicht lesbar");
        }
      } else if (name === "referrer") {
        let ref = wert;
        try { ref = wert === null ? null : decodeURIComponent(wert); } catch (_) { gruende.push("Referrer nicht dekodierbar"); }
        zeile.referrer = ref === "0" ? null : ref;
      } else {
        zeile[name] = wert;
      }
    });
    if (teile.length > P_POSITIONEN.length) {
      (zeile.rest as Record<string, string>)["p_weitere"] = teile.slice(P_POSITIONEN.length).join(",");
    }
    if (zeile.version !== "600") gruende.push("Version " + zeile.version + " statt 600");
  }

  // Alles andere
  for (const [k, v] of Object.entries(p)) {
    if (k === "p") continue;
    if (BENANNT[k]) { zeile[BENANNT[k]] = v; continue; }
    const m = /^([a-z]{2})(\d{1,3})$/.exec(k);
    if (m && FAMILIEN[m[1]]) { (zeile[FAMILIEN[m[1]]] as Record<string, string>)[m[2]] = v; continue; }
    if (m && ECOMMERCE_FAMILIEN.has(m[1])) { (zeile.ecommerce as Record<string, string>)[k] = v; continue; }
    if (ECOMMERCE.has(k)) { (zeile.ecommerce as Record<string, string>)[k] = v; continue; }
    (zeile.rest as Record<string, string>)[k] = v;
  }

  // Plausibilitaeten, die eine Auswertung spaeter braucht
  if (zeile.anonym !== "1") gruende.push("Markierung nc fehlt");
  if (zeile.ever_id && zeile.anonym === "1") gruende.push("eid trotz anonymem Modus");
  if (zeile.ever_id && !/^\d{19}$/.test(String(zeile.ever_id))) gruende.push("eid nicht 19-stellig");
  if (zeile.kampagne && !/^wt_mc%3D|^wt_mc=/.test(String(zeile.kampagne))) gruende.push("mc ohne Praefix wt_mc=");
  if (!zeile.aktion && !zeile.seitenname) gruende.push("weder Seitenname noch Aktion");

  zeile.qualitaet = gruende.length ? gruende.join("; ") : "ok";
  return zeile;
}

function trackIdAusPfad(pathname: string): string | null {
  // .../wtpixel/<track-id>/wt  oder  .../wtpixel/<track-id>  oder nur .../wtpixel
  const teile = pathname.split("/").filter(Boolean);
  const i = teile.lastIndexOf("wtpixel");
  if (i === -1) return null;
  const danach = teile.slice(i + 1);
  if (!danach.length) return null;
  return danach[0] === "wt" ? null : danach[0];
}

Deno.serve(async (req: Request) => {
  const origin = req.headers.get("origin");
  if (req.method === "OPTIONS") return new Response(null, { status: 204, headers: kopfzeilen(origin, "leer") });
  if (req.method !== "GET" && req.method !== "POST") return new Response(null, { status: 405, headers: kopfzeilen(origin, "leer") });

  const url = new URL(req.url);
  const p = await parameterLesen(req);
  const zeile = zerlegen(p, trackIdAusPfad(url.pathname), req.method, req.headers.get("user-agent"));

  // Wer die Antwort lesen will (Konsole der Modellseite), bekommt sie als JSON.
  const willJson = (req.headers.get("accept") || "").includes("application/json") || p.__antwort === "json";
  delete (zeile.rest as Record<string, string>)["__antwort"];

  try {
    const r = await fetch(SUPABASE_URL + "/rest/v1/webtrekk_requests", {
      method: "POST",
      headers: {
        apikey: DIENSTSCHLUESSEL,
        Authorization: "Bearer " + DIENSTSCHLUESSEL,
        "Content-Type": "application/json",
        Prefer: "return=minimal",
      },
      body: JSON.stringify(zeile),
    });
    if (!r.ok) console.error("webtrekk_requests schreiben fehlgeschlagen", r.status, await r.text());
    if (willJson) {
      return new Response(JSON.stringify({ geschrieben: r.ok, zeile }), { status: r.ok ? 200 : 502, headers: kopfzeilen(origin, "json") });
    }
  } catch (e) {
    console.error("wtpixel: unerwarteter Fehler", e);
    if (willJson) return new Response(JSON.stringify({ geschrieben: false, fehler: "unerwarteter Fehler" }), { status: 500, headers: kopfzeilen(origin, "json") });
  }

  // Ein Trackserver antwortet dem Browser immer freundlich, was auch immer
  // hinter ihm passiert ist. Die Seite darf von der Messung nichts merken.
  if (req.method === "GET") return new Response(GIF, { status: 200, headers: kopfzeilen(origin, "gif") });
  return new Response(null, { status: 204, headers: kopfzeilen(origin, "leer") });
});
