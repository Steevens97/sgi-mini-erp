// Parcours complet du module Commercial EN PRODUCTION avec des données d'ESSAI uniquement.
// - Prospect créé par creer_prospect_essai (clé secrète) : « [ESSAI] », devis numérotés ESSAI-DEV,
//   jamais le compteur réel ; aucun email envoyé (l'envoi n'est qu'une déclaration).
// - Étapes réservées aux essais (émission, envoi, décision, avenant) : fonctions de service, comme
//   le font les actions serveur ; affichage, archivage du PDF et téléchargement : par le site en ligne.
// - Comptes jetables @exemple.invalid ; tout est supprimé à la fin (supprimer_essais_commercial).
// Usage : NODE_USE_ENV_PROXY=1 NODE_EXTRA_CA_CERTS=/root/.ccr/ca-bundle.crt node parcours_essai_commercial.mjs <url>
import { chromium } from "playwright";
import { createHash } from "node:crypto";

const B = process.argv[2] ?? "https://sgi-mini-erp.vercel.app";
const U = process.env.NEXT_PUBLIC_SUPABASE_URL;
const S = process.env.SUPABASE_SERVICE_ROLE_KEY;
const T = Date.now();
const DOM = "@exemple.invalid";
const MDP = "Parcours-Jetable-2026!";
const BRUNO = "22222222-2222-2222-2222-222222222222";
const LEA = "22222222-2222-2222-2222-222222222221";
const ASSURANCE = "Assurance : couverture à vérifier selon la mission et le contrat.";
// Mêmes coordonnées que l'action serveur pour un devis d'essai (COORDONNEES_DEMO de src/lib/entreprise.ts).
const EMETTEUR_DEMO = {
  raison_sociale: "[DÉMO] SG Ingénierie", forme_juridique: "SAS", capital_social: "[DÉMO]", adresse: "[DÉMO] adresse",
  code_postal: "97200", ville: "Fort-de-France", siret: "00000000000000", immatriculation: "[DÉMO] immatriculation",
  tva_intracom: "[DÉMO]", validite_jours: "30", telephone: "", email: "", conditions_paiement: "",
  obligation_assurance: "non_requise",
};

let ok = 0, ko = 0;
const verifier = (libelle, cond, detail = "") => {
  cond ? ok++ : ko++;
  console.log(`  [${cond ? "OK " : "ÉCHEC"}] ${libelle}${detail ? `  (${detail})` : ""}`);
};
async function api(methode, chemin, corps, entetes = {}) {
  const r = await fetch(U + chemin, {
    method: methode,
    headers: { apikey: S, Authorization: `Bearer ${S}`, "Content-Type": "application/json", Prefer: "return=representation", ...entetes },
    body: corps === undefined ? undefined : JSON.stringify(corps),
  });
  const txt = await r.text();
  let donnees = null;
  try { donnees = txt ? JSON.parse(txt) : null; } catch { donnees = txt; }
  return { s: r.status, d: donnees };
}
const rpc = (f, args) => api("POST", `/rest/v1/rpc/${f}`, args);
const message = (r) => (r.d && (r.d.message || r.d.msg)) || JSON.stringify(r.d);
const compteursReels = async () => (await api("GET", "/rest/v1/compteurs?select=cle,valeur&cle=not.like.essai_*")).d;
const compteurEssai = async () => (await api("GET", "/rest/v1/compteurs?select=valeur&cle=like.essai_devis_*")).d?.[0]?.valeur ?? null;
const devis = async (id) => (await api("GET", `/rest/v1/devis?id=eq.${id}&select=numero,statut,essai,pdf_statut,pdf_chemin,pdf_empreinte,total_ht,tva,total_ttc,taux_tva,territoire_tva`)).d[0];

async function creerCompte(nom, role, fiche) {
  const email = `jetable-parcours-${nom}-${T}${DOM}`;
  const r = await api("POST", "/auth/v1/admin/users", { email, password: MDP, email_confirm: true });
  if (r.s !== 200) throw new Error(`création du compte ${nom} : ${r.s}`);
  await api("PATCH", `/rest/v1/profiles?id=eq.${r.d.id}`, { role, collaborateur_id: fiche });
  return { id: r.d.id, email };
}

const nav = await chromium.launch({
  executablePath: "/opt/pw-browsers/chromium-1194/chrome-linux/chrome",
  ...(B.startsWith("https") ? { proxy: { server: process.env.HTTPS_PROXY } } : {}),
});
async function connexion(compte) {
  const ctx = await nav.newContext({ ignoreHTTPSErrors: true });
  const page = await ctx.newPage();
  page.on("dialog", (d) => d.accept());
  await page.goto(B + "/connexion");
  await page.fill("#email", compte.email);
  await page.fill("#mot_de_passe", MDP);
  await page.click("button[type=submit]");
  await page.waitForURL((u) => !u.pathname.startsWith("/connexion"), { timeout: 30000 });
  return page;
}

const reelsAvant = await compteursReels();
let nettoye = false;
try {
  console.log("== 0. Point de départ");
  verifier("compteur des devis réels : absent ou inchangé (relevé)", Array.isArray(reelsAvant), JSON.stringify(reelsAvant));
  verifier("aucun prospect d'essai préexistant", (await api("GET", "/rest/v1/prospects?essai=is.true&select=id")).d.length === 0);
  const manager = await creerCompte("manager", "manager", BRUNO);
  const collab = await creerCompte("collab", "collaborateur", LEA);

  console.log("\n== 1. Prospect et devis d'essai (clé secrète)");
  const p = await rpc("creer_prospect_essai", { p_nom: "Parcours", p_societe: "Parcours SARL", p_adresse: "1 rue de l'Essai",
    p_code_postal: "97200", p_ville: "Fort-de-France", p_pays: "MQ" });
  verifier("prospect d'essai créé", p.s === 200, message(p));
  const prospect = p.d;
  const dv = await api("POST", "/rest/v1/devis?select=id", { prospect_id: prospect, type_mission: "conseil", regime_tva: "taxable",
    territoire_tva: "MQ", taux_tva: 8.5, criteres_tva: { nature_mission: "prestation_intellectuelle", statut_client: "assujetti_france" } });
  const id = dv.d?.[0]?.id;
  verifier("devis d'essai créé, marqué essai", !!id && (await devis(id)).essai === true, message(dv));
  const lg = await api("POST", "/rest/v1/devis_lignes?select=id", [
    { devis_id: id, designation: "Étude de faisabilité (essai)", quantite: 2, prix_unitaire: 150 },
    { devis_id: id, designation: "Visite de site (essai)", quantite: 1, prix_unitaire: 100 }]);
  verifier("lignes ajoutées, total HT calculé par la base", lg.s === 201 && Number((await devis(id)).total_ht) === 400);
  const tv = await devis(id);
  verifier("TVA Martinique 8,5 % calculée par la base : 34,00 € ; TTC 434,00 €",
    tv.territoire_tva === "MQ" && Number(tv.taux_tva) === 8.5 && Number(tv.tva) === 34 && Number(tv.total_ttc) === 434,
    `${tv.territoire_tva} ${tv.taux_tva} % → ${tv.tva} / ${tv.total_ttc}`);

  console.log("\n== 2. Écran du brouillon (manager, site en ligne)");
  const m = await connexion(manager);
  await m.goto(`${B}/commercial`);
  verifier("liste : prospect [ESSAI] visible", (await m.textContent("main")).includes("[ESSAI] Parcours"));
  await m.goto(`${B}/commercial/devis/${id}`);
  let texte = await m.textContent("main");
  verifier("brouillon : bandeau ESSAI — SANS VALEUR", texte.includes("ESSAI — SANS VALEUR"));
  verifier(`affiche « ${ASSURANCE} »`, texte.includes(ASSURANCE));
  verifier("écran : TVA 8,5 % (Martinique) et total TTC 434,00 €", /8,5\s*%/.test(texte) && texte.includes("Total TTC : 434,00"));
  verifier("devis d'essai : aucun bouton « Émettre » à l'écran", (await m.locator("button:has-text('Émettre')").count()) === 0);
  const apercu = await m.request.get(`${B}/commercial/devis/${id}/pdf`);
  const apercuOctets = await apercu.body();
  verifier("aperçu PDF du brouillon (généré, non stocké)", apercu.status() === 200 && apercuOctets.subarray(0, 5).toString() === "%PDF-");
  verifier("brouillon : rien dans le bucket devis", (await api("POST", "/storage/v1/object/list/devis", { prefix: id })).d.length === 0);

  console.log("\n== 3. Émission (numéro d'ESSAI, jamais le compteur réel)");
  const e = await rpc("emettre_devis", { p_devis_id: id, p_auteur: manager.id, p_emetteur: EMETTEUR_DEMO, p_gabarit: "devis-v1" });
  verifier("numéro ESSAI-DEV attribué", e.s === 200 && /^ESSAI-DEV-\d{4}-\d{4}$/.test(e.d), message(e));
  verifier("compteur réel inchangé après l'émission", JSON.stringify(await compteursReels()) === JSON.stringify(reelsAvant));

  console.log("\n== 4. Archivage du PDF par le site en ligne (action « Régénérer »)");
  await m.goto(`${B}/commercial/devis/${id}`);
  await m.click("button:has-text('Régénérer le PDF')");
  // Une fois le PDF archivé, le bouton (et son message) laisse la place au lien « Télécharger » :
  // on attend donc l'état réel en base, puis le lien à l'écran, et non le message.
  let archive = await devis(id);
  for (let i = 0; i < 60 && archive.pdf_statut !== "disponible" && archive.pdf_statut !== "echec"; i++) {
    await new Promise((r) => setTimeout(r, 1000));
    archive = await devis(id);
  }
  verifier("PDF archivé : statut « disponible »", archive.pdf_statut === "disponible", archive.pdf_chemin);
  await m.goto(`${B}/commercial/devis/${id}`);
  verifier("écran : lien « Télécharger le PDF archivé » affiché", (await m.locator("a:has-text('Télécharger le PDF archivé')").count()) === 1);
  const pdf = await m.request.get(`${B}/commercial/devis/${id}/pdf`);
  const octets = await pdf.body();
  const empreinte = createHash("sha256").update(octets).digest("hex");
  verifier("téléchargement : PDF identique à l'archive (SHA-256)", pdf.status() === 200 && empreinte === archive.pdf_empreinte);
  texte = await m.textContent("main");
  verifier(`émis : affiche toujours « ${ASSURANCE} »`, texte.includes(ASSURANCE));

  console.log("\n== 5. Envoi déclaré (aucun email envoyé), acceptation");
  const env = await rpc("declarer_envoi_devis", { p_devis_id: id, p_auteur: manager.id, p_date_envoi: new Date().toISOString(),
    p_canal: "email", p_destinataire: `essai-parcours${DOM}` });
  verifier("envoi déclaré (simple déclaration)", env.s === 204 || env.s === 200, message(env));
  const acc = await rpc("decider_devis", { p_devis_id: id, p_auteur: manager.id, p_decision: "accepte" });
  verifier("devis accepté", acc.s === 204 || acc.s === 200, message(acc));
  const pr = (await api("GET", `/rest/v1/prospects?id=eq.${prospect}&select=statut,client_id`)).d[0];
  const cl = (await api("GET", `/rest/v1/clients?id=eq.${pr.client_id}&select=nom`)).d[0];
  const pj = (await api("GET", `/rest/v1/projets?devis_id=eq.${id}&select=nom`)).d;
  verifier("prospect « gagné », client et projet créés, préfixés [ESSAI]",
    pr.statut === "gagne" && cl?.nom.startsWith("[ESSAI]") && pj.length === 1 && pj[0].nom.startsWith("[ESSAI]"), `${cl?.nom} / ${pj[0]?.nom}`);
  const reacc = await rpc("decider_devis", { p_devis_id: id, p_auteur: manager.id, p_decision: "accepte" });
  const nbClients = (await api("GET", "/rest/v1/clients?nom=like.*ESSAI*&select=id")).d.length;
  const nbProjets = (await api("GET", `/rest/v1/projets?devis_id=eq.${id}&select=id`)).d.length;
  verifier("seconde acceptation refusée : toujours UN client et UN projet", reacc.s >= 400 && nbClients === 1 && nbProjets === 1,
    `${message(reacc)} — ${nbClients} client(s), ${nbProjets} projet(s)`);
  const ref = await rpc("decider_devis", { p_devis_id: id, p_auteur: manager.id, p_decision: "refuse" });
  verifier("devis accepté : passage à « refusé » refusé", ref.s >= 400, message(ref));

  console.log("\n== 6. Avenants (moins-value permise, total de mission jamais négatif)");
  const av = await rpc("creer_avenant_devis", { p_devis_id: id, p_auteur: manager.id });
  verifier("avenant créé", av.s === 200, message(av));
  await api("POST", "/rest/v1/devis_lignes", { devis_id: av.d, designation: "Visite supprimée (essai)", quantite: -1, prix_unitaire: 100 });
  const eav = await rpc("emettre_devis", { p_devis_id: av.d, p_auteur: manager.id, p_emetteur: EMETTEUR_DEMO, p_gabarit: "devis-v1" });
  verifier("avenant de -100 € émis avec un numéro d'essai", eav.s === 200 && eav.d.startsWith("ESSAI-DEV-"), message(eav));
  const av2 = await rpc("creer_avenant_devis", { p_devis_id: id, p_auteur: manager.id });
  await api("POST", "/rest/v1/devis_lignes", { devis_id: av2.d, designation: "Retrait excessif (essai)", quantite: -1, prix_unitaire: 1000 });
  const eav2 = await rpc("emettre_devis", { p_devis_id: av2.d, p_auteur: manager.id, p_emetteur: EMETTEUR_DEMO, p_gabarit: "devis-v1" });
  verifier("avenant qui rendrait la mission négative : émission refusée", eav2.s >= 400, message(eav2));
  verifier("compteur réel inchangé après tout le parcours", JSON.stringify(await compteursReels()) === JSON.stringify(reelsAvant));
  verifier("compteur d'essai : 2 numéros (devis + 1 avenant)", (await compteurEssai()) === 2, String(await compteurEssai()));
  verifier("après les avenants : toujours UN client et UN projet pour la mission",
    (await api("GET", "/rest/v1/clients?nom=like.*ESSAI*&select=id")).d.length === 1
    && (await api("GET", `/rest/v1/projets?devis_id=eq.${id}&select=id`)).d.length === 1);

  console.log("\n== 7. Collaborateur (site en ligne) : consultation sans PDF");
  const c = await connexion(collab);
  await c.goto(`${B}/commercial/devis/${id}`);
  texte = await c.textContent("main");
  verifier("collaborateur : devis d'essai consultable", texte.includes(e.d) && texte.includes("ESSAI — SANS VALEUR"));
  verifier("collaborateur : aucune action commerciale", (await c.locator("button:has-text('Régénérer'), button:has-text('Émettre')").count()) === 0);
  const pdfCollab = await c.request.get(`${B}/commercial/devis/${id}/pdf`);
  verifier("collaborateur : PDF refusé (403)", pdfCollab.status() === 403, String(pdfCollab.status()));
  await c.goto(`${B}/commercial/prospects/${prospect}`);
  texte = await c.textContent("main");
  verifier("collaborateur : ni adresse ni email du prospect affichés", !texte.includes("1 rue de l'Essai") && !texte.includes("@"));
  await c.goto(`${B}/utilisateurs`);
  verifier("collaborateur : écran Utilisateurs inaccessible", !(await c.textContent("body")).includes("Créer l'accès"));

  console.log("\n== 8. Émission réelle toujours bloquée (manager)");
  await m.goto(`${B}/commercial`);
  verifier("bandeau « Émission des devis bloquée » affiché", (await m.locator("[role=alert]", { hasText: "Émission des devis bloquée" }).count()) === 1);
} catch (err) {
  verifier("parcours interrompu", false, err.message);
} finally {
  console.log("\n== 9. Nettoyage des essais");
  const n = await rpc("supprimer_essais_commercial", {});
  verifier("essais supprimés par la base", n.s === 200, JSON.stringify(n.d));
  const chemins = n.d?.pdf_chemins ?? [];
  if (chemins.length) await api("DELETE", "/storage/v1/object/devis", { prefixes: chemins });
  nettoye = n.s === 200;
  const restants = (await api("POST", "/storage/v1/object/list/devis", { prefix: "" })).d;
  verifier("bucket devis vide", Array.isArray(restants) && restants.length === 0, JSON.stringify(restants));
  verifier("plus aucun prospect, devis, client ni projet d'essai",
    (await api("GET", "/rest/v1/prospects?essai=is.true&select=id")).d.length === 0
    && (await api("GET", "/rest/v1/devis?essai=is.true&select=id")).d.length === 0
    && (await api("GET", "/rest/v1/clients?nom=like.*ESSAI*&select=id")).d.length === 0
    && (await api("GET", "/rest/v1/projets?nom=like.*ESSAI*&select=id")).d.length === 0
    && (await compteurEssai()) === null);
  verifier("compteur réel inchangé", JSON.stringify(await compteursReels()) === JSON.stringify(reelsAvant), JSON.stringify(await compteursReels()));
  const comptes = (await api("GET", "/auth/v1/admin/users?per_page=1000")).d.users;
  for (const u of comptes) if (u.email.endsWith(DOM)) await api("DELETE", `/auth/v1/admin/users/${u.id}`);
  const apres = (await api("GET", "/auth/v1/admin/users?per_page=1000")).d.users.map((u) => u.email);
  verifier("comptes jetables supprimés, le vôtre conservé", apres.length === 1 && apres[0] === "sgi@gmx.fr", apres.join(", "));
  await nav.close();
  console.log(`\nBILAN : ${ok}/${ok + ko} contrôles réussis${nettoye ? "" : " — NETTOYAGE À REPRENDRE"}`);
}
