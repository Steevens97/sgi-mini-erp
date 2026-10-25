// IMITATION LOCALE du fournisseur d'emails (Resend) pour les essais : aucun email n'est jamais envoyé.
// Reproduit ce que la documentation officielle décrit pour POST /emails (consultée le 25/10/2026) :
//   - clé anti-doublon (Idempotency-Key) conservée 24 h : même clé + même contenu → même identifiant, aucun nouvel email ;
//     même clé + contenu différent → 409 invalid_idempotent_request ; même clé encore en cours → 409
//     concurrent_idempotent_requests ;
//   - réponse 200 { id } ; erreurs { statusCode, name, message }.
// Modes pilotés par POST /__mode { mode } : normal | coupure_apres_acceptation (email « accepté » puis connexion
// coupée sans réponse) | erreur_503 | refus_422 | lent (réponse après 3 s). GET /__etat : emails « acceptés » et
// demandes reçues (en-têtes Authorization masqués, seulement comparés). Usage : node imitation_resend.mjs <port> <clé attendue>
import http from "node:http";
import { createHash, randomUUID } from "node:crypto";

const PORT = Number(process.argv[2] ?? 3300);
const CLE = process.argv[3] ?? "";
let mode = "normal";
const cles = new Map();      // Idempotency-Key → { empreinte, id, le, enCours }
const emails = [];           // emails « acceptés » (un par identifiant)
const demandes = [];         // toutes les demandes reçues

function repondre(res, code, corps) {
  res.writeHead(code, { "Content-Type": "application/json" });
  res.end(JSON.stringify(corps));
}

http.createServer((req, res) => {
  let brut = "";
  req.on("data", (c) => { brut += c; });
  req.on("end", async () => {
    if (req.url === "/__mode" && req.method === "POST") { mode = JSON.parse(brut).mode; return repondre(res, 200, { mode }); }
    if (req.url === "/__etat") return repondre(res, 200, { mode, emails, demandes });
    if (req.url === "/__reinitialiser") { cles.clear(); emails.length = 0; demandes.length = 0; mode = "normal"; return repondre(res, 200, {}); }
    if (req.url !== "/emails" || req.method !== "POST") return repondre(res, 404, { statusCode: 404, name: "not_found", message: "Not found" });
    const cle = req.headers["idempotency-key"] ?? null;
    demandes.push({ le: new Date().toISOString(), cle, auth_ok: req.headers.authorization === `Bearer ${CLE}`,
                    corps: brut, mode });
    if (req.headers.authorization !== `Bearer ${CLE}`) return repondre(res, 401, { statusCode: 401, name: "missing_api_key", message: "Missing API key" });
    if (mode === "erreur_503") return repondre(res, 503, { statusCode: 503, name: "application_error", message: "Service unavailable" });
    if (mode === "refus_422") return repondre(res, 422, { statusCode: 422, name: "validation_error", message: "Invalid `to` field" });
    const empreinte = createHash("sha256").update(brut).digest("hex");
    const connue = cle ? cles.get(cle) : null;
    if (connue && Date.now() - connue.le < 24 * 3600 * 1000) {
      if (connue.enCours) return repondre(res, 409, { statusCode: 409, name: "concurrent_idempotent_requests", message: "Request in progress" });
      if (connue.empreinte !== empreinte) return repondre(res, 409, { statusCode: 409, name: "invalid_idempotent_request", message: "Body modified" });
      return repondre(res, 200, { id: connue.id });   // même demande : même identifiant, AUCUN nouvel email
    }
    const id = randomUUID();
    if (cle) cles.set(cle, { empreinte, id, le: Date.now(), enCours: true });
    if (mode === "lent") await new Promise((r) => setTimeout(r, 3000));
    const corps = JSON.parse(brut);
    emails.push({ id, cle, to: corps.to, from: corps.from, subject: corps.subject, text: corps.text, reply_to: corps.reply_to ?? null,
                  pieces: (corps.attachments ?? []).map((a) => ({ filename: a.filename, sha256: createHash("sha256").update(Buffer.from(a.content, "base64")).digest("hex") })),
                  tags: corps.tags });
    if (cle) cles.get(cle).enCours = false;
    if (mode === "coupure_apres_acceptation") { req.socket.destroy(); return; }
    repondre(res, 200, { id });
  });
}).listen(PORT, "127.0.0.1", () => console.log(`imitation du fournisseur sur 127.0.0.1:${PORT}`));
