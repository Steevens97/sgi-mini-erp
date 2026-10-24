// Essais du STOCKAGE des justificatifs, à lancer APRÈS l'application de la migration 20261028100000 (temps 1) et AVANT le
// temps 2 : tous doivent réussir. La migration vérifie toutes les règles de la BASE (son autotest ne touche jamais le
// stockage) ; ce script vérifie le comportement du STOCKAGE de Supabase lui-même, avec les mêmes appels que le site :
//   - aucun accès direct avec un jeton (même pour son propre dossier), aucun lien signé émis pour un jeton ;
//   - dépôt par lien signé (émis par le serveur avec la clé secrète, envoyé comme le fait le navigateur) ;
//   - un fichier déposé, et a fortiori rattaché à une note, ne peut être ni remplacé ni écrasé (même avec x-upsert) ;
//   - limites du bucket (10 Mo, PDF/JPEG/PNG) ; la base refuse taille, type ou dossier différents de ceux stockés ;
//   - lien de consultation temporaire (expiré = refusé) ; dépôts récents jamais listés comme abandonnés.
// Fiches et comptes JETABLES (@exemple.invalid) ; nettoyage intégré (notes d'essai, fichiers, comptes, fiches).
// Usage : NODE_USE_ENV_PROXY=1 NODE_EXTRA_CA_CERTS=/root/.ccr/ca-bundle.crt node essais_stockage_absences.mjs
import { createHash, randomUUID } from "node:crypto";

const U = process.env.NEXT_PUBLIC_SUPABASE_URL, S = process.env.SUPABASE_SERVICE_ROLE_KEY, ANON = process.env.NEXT_PUBLIC_SUPABASE_ANON_KEY;
const T = Date.now(), DOM = "@exemple.invalid", MDP = "Stock-Jetable-2026!", B = "justificatifs";
let ok = 0, ko = 0;
const verifier = (l, c, d = "") => { c ? ok++ : ko++; console.log(`  [${c ? "OK " : "ÉCHEC"}] ${l}${d ? `  (${d})` : ""}`); };
const sha = (b) => createHash("sha256").update(b).digest("hex");
async function appel(m, p, { corps, jeton, cle = ANON, entetes = {}, brut } = {}) {
  const h = { ...(cle ? { apikey: cle } : {}), ...(jeton ? { Authorization: `Bearer ${jeton}` } : {}), ...entetes };
  if (corps !== undefined) h["Content-Type"] = "application/json";
  const r = await fetch(p.startsWith("http") ? p : U + p, { method: m, headers: h, body: brut ?? (corps === undefined ? undefined : JSON.stringify(corps)) });
  const buf = Buffer.from(await r.arrayBuffer());
  let d = null; try { d = JSON.parse(buf.toString()); } catch { d = buf; }
  return { s: r.status, d, buf };
}
const secret = (m, p, o = {}) => appel(m, p, { ...o, cle: S, jeton: S });
const rpc = (f, a) => secret("POST", `/rest/v1/rpc/${f}`, { corps: a });
const AUJ = new Intl.DateTimeFormat("en-CA", { timeZone: "America/Martinique" }).format(new Date());
const PDF = Buffer.from("%PDF-1.4\n%essai stockage\n%%EOF\n");
const PDF2 = Buffer.from("%PDF-1.4\n%AUTRE CONTENU (substitution)\n%%EOF\n");
// Comme le serveur : lien signé pour un chemin neuf, sans écrasement.
async function lienDepot(chemin) {
  const r = await secret("POST", `/storage/v1/object/upload/sign/${B}/${chemin}`, { corps: {} });
  return r.d?.url ? `${U}/storage/v1${r.d.url}` : null;
}
// Comme le navigateur : PUT direct avec la seule clé publique.
const deposer = (url, contenu, type, upsert = "false") =>
  appel("PUT", url, { brut: contenu, entetes: { "content-type": type, "x-upsert": upsert } });
const lire = async (chemin) => (await secret("GET", `/storage/v1/object/${B}/${chemin}`)).buf;
const objets = async (dossier) => ((await secret("POST", `/storage/v1/object/list/${B}`, { corps: { prefix: dossier, limit: 1000 } })).d ?? []).filter((o) => o.id);

const ids = { fiches: [], comptes: [], chemins: [] };
try {
  console.log("== 0. Préparation : fiches et comptes jetables");
  const fiche = async (nom) => {
    const r = await secret("POST", "/rest/v1/collaborateurs?select=id", { corps: { nom, prenom: "Essai", email: `${nom.toLowerCase()}-${T}${DOM}`,
      poste: "Test", taux_horaire: 0, date_entree: AUJ }, entetes: { Prefer: "return=representation" } });
    ids.fiches.push(r.d[0].id); return r.d[0].id;
  };
  const FL = await fiche("Jetable-Stock-L"), FX = await fiche("Jetable-Stock-X");
  const compte = async (nom, ficheId) => {
    const email = `jetable-stock-${nom}-${T}${DOM}`;
    const r = await secret("POST", "/auth/v1/admin/users", { corps: { email, password: MDP, email_confirm: true } });
    await secret("PATCH", `/rest/v1/profiles?id=eq.${r.d.id}`, { corps: { role: "collaborateur", collaborateur_id: ficheId } });
    ids.comptes.push(r.d.id);
    const t = await appel("POST", "/auth/v1/token?grant_type=password", { corps: { email, password: MDP } });
    return { id: r.d.id, jeton: t.d.access_token };
  };
  const L = await compte("l", FL), X = await compte("x", FX);

  console.log("\n== 1. Réglages du bucket");
  const b = await secret("GET", `/storage/v1/bucket/${B}`);
  verifier("bucket privé, 10 Mo, PDF/JPEG/PNG uniquement", b.d?.public === false && Number(b.d?.file_size_limit) === 10485760
    && JSON.stringify([...(b.d?.allowed_mime_types ?? [])].sort()) === JSON.stringify(["application/pdf", "image/jpeg", "image/png"]), JSON.stringify(b.d));

  console.log("\n== 2. Aucun accès direct avec un jeton (même son propre dossier)");
  for (const [qui, j] of [["collaborateur", L.jeton], ["visiteur", null]]) {
    let r = await appel("POST", `/storage/v1/object/${B}/${FL}/${randomUUID()}.pdf`, { jeton: j, brut: PDF, entetes: { "content-type": "application/pdf" } });
    verifier(`${qui} : dépôt direct dans le dossier de la fiche refusé`, r.s >= 400, `HTTP ${r.s}`);
    r = await appel("POST", `/storage/v1/object/${B}/${FX}/${randomUUID()}.pdf`, { jeton: j, brut: PDF, entetes: { "content-type": "application/pdf" } });
    verifier(`${qui} : dépôt direct dans le dossier d'un autre collaborateur refusé`, r.s >= 400, `HTTP ${r.s}`);
    r = await appel("POST", `/storage/v1/object/upload/sign/${B}/${FX}/${randomUUID()}.pdf`, { jeton: j, corps: {} });
    verifier(`${qui} : création d'un lien de dépôt refusée (serveur seulement)`, r.s >= 400 && !r.d?.url, `HTTP ${r.s}`);
    r = await appel("POST", `/storage/v1/object/list/${B}`, { jeton: j, corps: { prefix: FL } });
    verifier(`${qui} : rien de listable`, Array.isArray(r.d) ? r.d.length === 0 : r.s >= 400, `HTTP ${r.s}`);
  }

  console.log("\n== 3. Dépôt par lien signé, comme le site");
  const P = `${FL}/${randomUUID()}.pdf`; ids.chemins.push(P);
  const u1 = await lienDepot(P);
  verifier("lien de dépôt émis par la clé secrète", !!u1);
  let r = await deposer(u1, PDF, "application/pdf");
  verifier("dépôt par le navigateur (clé publique seule) accepté", r.s === 200, `HTTP ${r.s}`);
  const meta = (await objets(FL)).find((o) => `${FL}/${o.name}` === P)?.metadata;
  verifier("taille et type enregistrés par le stockage", Number(meta?.size) === PDF.length && meta?.mimetype === "application/pdf", JSON.stringify(meta));
  r = await deposer(u1, PDF2, "application/pdf");
  verifier("même lien rejoué avec un autre contenu : refusé (aucun écrasement)", r.s >= 400, `HTTP ${r.s}`);
  r = await deposer(u1, PDF2, "application/pdf", "true");
  verifier("même lien rejoué avec x-upsert: true : refusé", r.s >= 400, `HTTP ${r.s}`);
  verifier("fichier stocké inchangé (empreinte)", sha(await lire(P)) === sha(PDF));
  r = await appel("PUT", `/storage/v1/object/${B}/${P}`, { jeton: L.jeton, brut: PDF2, entetes: { "content-type": "application/pdf", "x-upsert": "true" } });
  verifier("remplacement direct par le collaborateur (son propre fichier) : refusé", r.s >= 400, `HTTP ${r.s}`);

  console.log("\n== 4. Rattachement par la base : seulement le fichier tel que stocké");
  const note = (chemin, taille, type, empreinte, collab = FL, auteur = L.id) => rpc("abs_creer_note", { p_auteur: auteur, p_collaborateur: collab,
    p_date: AUJ, p_montant: 12.5, p_categorie: "repas", p_precision: null, p_objet: "Essai stockage", p_chemin: chemin, p_type: type,
    p_taille: taille, p_empreinte: empreinte });
  r = await note(P, PDF2.length, "application/pdf", sha(PDF2));
  verifier("taille déclarée différente du fichier stocké : refusée", r.s >= 400 && /taille stockée diffère/.test(r.d?.message ?? ""), r.d?.message);
  r = await note(P, PDF.length, "application/pdf", sha(PDF), FX, X.id);
  verifier("fichier du dossier d'un autre collaborateur : refusé", r.s >= 400 && /emplacement non conforme/.test(r.d?.message ?? ""), r.d?.message);
  r = await note(P, PDF.length, "application/pdf", sha(PDF));
  verifier("fichier conforme rattaché à la note", r.s === 200 && r.d?.id, JSON.stringify(r.d));
  const noteId = r.d?.id;
  const u2 = await lienDepot(P);
  r = u2 ? await deposer(u2, PDF2, "application/pdf", "true") : { s: 400 };
  verifier("fichier RATTACHÉ : nouveau lien de dépôt sur le même chemin, écrasement refusé", r.s >= 400, `HTTP ${r.s}`);
  verifier("fichier rattaché toujours identique (empreinte enregistrée)", sha(await lire(P)) === sha(PDF)
    && (await secret("GET", `/rest/v1/notes_de_frais?id=eq.${noteId}&select=justificatif_empreinte`)).d?.[0]?.justificatif_empreinte === sha(PDF));
  const P2 = `${FL}/${randomUUID()}.pdf`; ids.chemins.push(P2);
  await deposer(await lienDepot(P2), PDF2, "image/png");
  r = await note(P2, PDF2.length, "application/pdf", sha(PDF2));
  verifier("type stocké différent du type contrôlé : refusé par la base", r.s >= 400 && /type stocké diffère/.test(r.d?.message ?? ""), r.d?.message);

  console.log("\n== 5. Limites du bucket");
  const P3 = `${FL}/${randomUUID()}.pdf`; ids.chemins.push(P3);
  r = await deposer(await lienDepot(P3), Buffer.concat([PDF, Buffer.alloc(10 * 1024 * 1024)]), "application/pdf");
  verifier("plus de 10 Mo : refusé par le stockage", r.s >= 400, `HTTP ${r.s}`);
  const P4 = `${FL}/${randomUUID()}.pdf`; ids.chemins.push(P4);
  r = await deposer(await lienDepot(P4), Buffer.from("texte"), "text/plain");
  verifier("type déclaré texte : refusé par le stockage", r.s >= 400, `HTTP ${r.s}`);

  console.log("\n== 6. Consultation par lien temporaire, dépôts abandonnés");
  r = await secret("POST", `/storage/v1/object/sign/${B}/${P}`, { corps: { expiresIn: 60 } });
  let g = await appel("GET", `${U}/storage/v1${r.d?.signedURL}`, { cle: undefined });
  verifier("lien temporaire : fichier identique", g.s === 200 && sha(g.buf) === sha(PDF), `HTTP ${g.s}`);
  r = await secret("POST", `/storage/v1/object/sign/${B}/${P}`, { corps: { expiresIn: 1 } });
  await new Promise((x) => setTimeout(x, 3000));
  g = await appel("GET", `${U}/storage/v1${r.d?.signedURL}`, { cle: undefined });
  verifier("lien expiré : refusé", g.s >= 400, `HTTP ${g.s}`);
  const orph = (await rpc("abs_fichiers_orphelins", {})).d ?? [];
  verifier("ni le fichier rattaché ni un dépôt récent (< 1 h) listés comme abandonnés", !orph.includes(P) && !orph.includes(P2), JSON.stringify(orph));
} catch (e) {
  verifier("essais interrompus", false, e.message.split("\n")[0]);
} finally {
  console.log("\n== 7. Nettoyage (uniquement ce que ces essais ont créé)");
  const n = await rpc("supprimer_essais_absences", {});
  verifier("notes d'essai supprimées", n.s === 200, JSON.stringify(n.d));
  const restants = (await Promise.all(ids.fiches.map(async (f) => (await objets(f)).map((o) => `${f}/${o.name}`)))).flat();
  const chemins = [...new Set([...(n.d?.chemins ?? []), ...restants])];
  if (chemins.length) await secret("DELETE", `/storage/v1/object/${B}`, { corps: { prefixes: chemins } });
  for (const id of ids.comptes) await secret("DELETE", `/auth/v1/admin/users/${id}`);
  for (const id of ids.fiches) await secret("DELETE", `/rest/v1/collaborateurs?id=eq.${id}`);
  const restes = {
    fichiers: (await Promise.all(ids.fiches.map(objets))).flat().length,
    fiches: ((await secret("GET", `/rest/v1/collaborateurs?select=id&id=in.(${ids.fiches.join(",")})`)).d ?? []).length,
    notes_essai: ((await secret("GET", "/rest/v1/notes_de_frais?select=id&essai=is.true")).d ?? []).length,
  };
  verifier("aucun reste (fichiers, fiches, notes d'essai)", Object.values(restes).every((v) => v === 0), JSON.stringify(restes));
  console.log(`\nBILAN : ${ok}/${ok + ko} contrôles réussis`);
}
