// Parcours Absences et notes de frais EN PRODUCTION (après le temps 2), avec des comptes et des fiches JETABLES uniquement.
// - Fiches jetables (@exemple.invalid : congés et notes marqués « essai » par la base) : manager, collaboratrice de son
//   équipe, manager hors équipe, administrateur (avec sa propre fiche jetable). Aucune fiche réelle utilisée.
// - Fichiers d'essai déposés uniquement dans les dossiers de ces fiches jetables. Aucun email, aucun virement.
// - Alerte « temps déjà saisis » : temps saisis sur un projet d'ESSAI (issu d'un devis d'essai accepté), supprimés ensuite.
// - Requêtes falsifiées (dossier d'un autre, fichier rattaché, lien de dépôt rejoué) : tout doit être refusé.
// - Nettoyage intégré : essais Absences → fichiers rendus → essais RH → comptes → fiches → essais Commercial → PDF de devis.
//   SEULE EXCEPTION volontaire : les dépôts abandonnés du parcours (fichiers sans note, dossier jetable) restent dans le
//   stockage pour la 2e phase ; leur liste est écrite dans un fichier d'état.
// Usage : NODE_USE_ENV_PROXY=1 NODE_EXTRA_CA_CERTS=/root/.ccr/ca-bundle.crt node parcours_absences_en_ligne.mjs <url>
//         puis, AU MOINS 1 HEURE PLUS TARD : node parcours_absences_en_ligne.mjs <url> orphelins <fichier d'état>
//         (dépôts abandonnés listés par la base, supprimés par le bouton de l'administrateur, rien d'autre supprimé).
import { chromium } from "playwright";
import { createHash } from "node:crypto";
import { mkdirSync, readFileSync, writeFileSync } from "node:fs";

const B = process.argv[2] ?? "https://sgi-mini-erp.vercel.app";
const U = process.env.NEXT_PUBLIC_SUPABASE_URL, S = process.env.SUPABASE_SERVICE_ROLE_KEY;
const T = Date.now(), DOM = "@exemple.invalid", MDP = "Abs-Jetable-2026!";
let ok = 0, ko = 0;
const verifier = (l, c, d = "") => { c ? ok++ : ko++; console.log(`  [${c ? "OK " : "ÉCHEC"}] ${l}${d ? `  (${d})` : ""}`); };
async function api(m, p, c, h = {}) {
  const r = await fetch(U + p, { method: m, headers: { apikey: S, Authorization: `Bearer ${S}`, "Content-Type": "application/json", Prefer: "return=representation", ...h },
    body: c === undefined ? undefined : (c instanceof Uint8Array ? c : JSON.stringify(c)) });
  const t = await r.text(); let d = null; try { d = t ? JSON.parse(t) : null; } catch { d = t; }
  return { s: r.status, d };
}
const un = async (p) => (await api("GET", p)).d?.[0];
const rpc = (f, a) => api("POST", `/rest/v1/rpc/${f}`, a);
const ANON = process.env.NEXT_PUBLIC_SUPABASE_ANON_KEY;
const attendre = async (fn, essais = 60) => { for (let i = 0; i < essais; i++) { if (await fn()) return true; await new Promise((r) => setTimeout(r, 1000)); } return false; };
const EMETTEUR_DEMO = { raison_sociale: "[DÉMO] SG Ingénierie", forme_juridique: "SAS", capital_social: "[DÉMO]", adresse: "[DÉMO] adresse",
  code_postal: "97200", ville: "Fort-de-France", siret: "00000000000000", immatriculation: "[DÉMO] immatriculation", tva_intracom: "[DÉMO]",
  validite_jours: "30", telephone: "", email: "", conditions_paiement: "", obligation_assurance: "non_requise" };
const AUJ = new Intl.DateTimeFormat("en-CA", { timeZone: "America/Martinique" }).format(new Date());
const J = (n) => { const d = new Date(`${AUJ}T12:00:00Z`); d.setUTCDate(d.getUTCDate() + n); return d.toISOString().slice(0, 10); };
const sha = (b) => createHash("sha256").update(b).digest("hex");
const DOSSIER = `/tmp/fichiers-parcours-absences-${T}`;
mkdirSync(DOSSIER, { recursive: true });
const PDF = Buffer.from("%PDF-1.4\n1 0 obj<</Type/Catalog/Pages 2 0 R>>endobj 2 0 obj<</Type/Pages/Kids[]/Count 0>>endobj\ntrailer<</Root 1 0 R>>\n%%EOF\n");
const PNG = Buffer.from("89504e470d0a1a0a0000000d4948445200000001000000010806000000" + "1f15c4890000000d49444154789c6360000002000154a24f5d0000000049454e44ae426082", "hex");
const F = { vrai: [`${DOSSIER}/ticket-essai.pdf`, PDF], png: [`${DOSSIER}/peage-essai.png`, PNG], faux: [`${DOSSIER}/faux-essai.pdf`, Buffer.from("texte, pas un PDF\n")],
  autre: [`${DOSSIER}/autre-essai.pdf`, Buffer.concat([PDF, Buffer.from("% autre\n")])] };
for (const [c, b] of Object.values(F)) writeFileSync(c, b);

const nav = await chromium.launch({ executablePath: "/opt/pw-browsers/chromium-1194/chrome-linux/chrome",
  ...(process.env.HTTPS_PROXY && !B.startsWith("http://127.0.0.1") ? { proxy: { server: process.env.HTTPS_PROXY } } : {}) });
async function connexion(email) {
  const page = await (await nav.newContext({ ignoreHTTPSErrors: true })).newPage();
  page.on("dialog", (d) => d.accept());
  await page.goto(B + "/connexion"); await page.fill("#email", email); await page.fill("#mot_de_passe", MDP);
  await page.click("button[type=submit]"); await page.waitForURL((u) => !u.pathname.startsWith("/connexion"), { timeout: 30000 });
  return page;
}
const vu = async (zone, texte, selecteur = "[role=status]") => {
  try { await zone.locator(selecteur, { hasText: texte }).first().waitFor({ timeout: 40000 }); return true; } catch { return false; }
};
const formConge = (p) => p.locator("form", { has: p.locator("input[name=nb_jours]") }).first();
async function demande(p, { type = "conges_payes", debut, fin, apresMidi = false, finMidi = false, jours, pour }) {
  const f = formConge(p);
  if (pour) await f.locator("select[name=collaborateur_id]").selectOption(pour);
  await f.locator("select[name=type]").selectOption(type);
  await f.locator("input[name=date_debut]").fill(debut); await f.locator("input[name=date_fin]").fill(fin);
  await f.locator("input[name=debut_apres_midi]").setChecked(apresMidi); await f.locator("input[name=fin_midi]").setChecked(finMidi);
  await f.locator("input[name=nb_jours]").fill(jours);
  return f;
}
const formNote = (p) => p.locator("form[data-formulaire-note=nouvelle]");
async function note(p, { date, montant, objet, fichier }) {
  const f = formNote(p);
  await f.locator("input[name=date_depense]").fill(date); await f.locator("input[name=montant]").fill(montant);
  await f.locator("select[name=categorie]").selectOption("repas"); await f.locator("input[name=objet]").fill(objet);
  if (fichier) await f.locator("input[name=fichier]").setInputFiles(fichier);
  await f.locator("button[type=submit]").click();
  return f;
}
const fichiersDe = async (fiche) => ((await api("POST", "/storage/v1/object/list/justificatifs", { prefix: fiche, limit: 1000 })).d ?? []).filter((o) => o.id);
const lireFichier = async (chemin) => Buffer.from(await (await fetch(`${U}/storage/v1/object/justificatifs/${chemin}`, { headers: { apikey: S, Authorization: `Bearer ${S}` } })).arrayBuffer());
// Falsification des requêtes d'actions serveur envoyées par la page (outils du navigateur d'un utilisateur malveillant).
async function falsifier(page, motif, vers) {
  const h = async (route) => {
    const r = route.request(); const corps = r.postData();
    if (r.method() === "POST" && r.headers()["next-action"] && corps && motif.test(corps)) return route.continue({ postData: corps.replace(motif, vers) });
    return route.continue();
  };
  await page.route("**/rh/notes-de-frais**", h);
  return () => page.unroute("**/rh/notes-de-frais**", h);
}

// ---------- 2e phase (au moins 1 heure après) : dépôts abandonnés ----------
if (process.argv[3] === "orphelins") {
  const etat = JSON.parse(readFileSync(process.argv[4], "utf8"));
  const age = (Date.now() - etat.depose_le) / 60000;
  console.log(`== Dépôts abandonnés du parcours (${etat.chemins.length}), déposés il y a ${Math.round(age)} min`);
  if (age < 61) { console.log("  Trop tôt : relancer au moins 61 minutes après le premier passage."); process.exit(1); }
  const compte = { email: `jetable-abs-orphelins-${T}${DOM}` };
  const rc = await api("POST", "/auth/v1/admin/users", { email: compte.email, password: MDP, email_confirm: true });
  await api("PATCH", `/rest/v1/profiles?id=eq.${rc.d.id}`, { role: "admin", nom: "Jetable orphelins" });
  try {
    const liste = (await rpc("abs_fichiers_orphelins", {})).d ?? [];
    verifier("la base liste chaque dépôt abandonné du parcours", etat.chemins.every((c) => liste.includes(c)), `${liste.length} listé(s)`);
    verifier("aucun fichier hors des dossiers jetables n'est listé", liste.every((c) => etat.dossiers.some((d) => c.startsWith(`${d}/`))), JSON.stringify(liste));
    const a = await connexion(compte.email);
    await a.goto(B + "/rh/notes-de-frais");
    await a.locator("button", { hasText: "Supprimer les dépôts abandonnés" }).click();
    verifier("bouton de l'administrateur : dépôts abandonnés supprimés", await vu(a, `${liste.length} dépôt(s) abandonné(s) supprimé(s)`));
    const restants = (await Promise.all(etat.dossiers.map(fichiersDe))).flat();
    verifier("plus aucun fichier dans les dossiers jetables", restants.length === 0, JSON.stringify(restants.map((o) => o.name)));
  } finally {
    await api("DELETE", `/auth/v1/admin/users/${rc.d.id}`);
    verifier("compte jetable supprimé", !(await api("GET", "/auth/v1/admin/users?per_page=1000")).d.users.some((u) => u.email === compte.email));
    await nav.close();
    console.log(`\nBILAN : ${ok}/${ok + ko} contrôles réussis`);
  }
  process.exit(ko ? 1 : 0);
}

const ids = { fiches: [], comptes: [], dv: null };
const etatOrphelins = { chemins: [], dossiers: [], depose_le: null };
// Lignes réelles au départ : le parcours ne doit rien y ajouter ni en retirer.
const reels = async () => ({
  conges: (await api("GET", "/rest/v1/conges?select=id&essai=is.false")).d.length,
  notes: (await api("GET", "/rest/v1/notes_de_frais?select=id&essai=is.false")).d.length,
});
const reelsAvant = await reels();
try {
  console.log("== 0. Préparation (clé secrète) : fiches et comptes jetables");
  const fiche = async (nom, extra = {}) => {
    const r = await api("POST", "/rest/v1/collaborateurs?select=id", { nom, prenom: "Essai", email: `${nom.toLowerCase()}-${T}${DOM}`, poste: "Test", taux_horaire: 0, ...extra });
    ids.fiches.unshift(r.d[0].id); return r.d[0].id;
  };
  const FM = await fiche("Jetable-Abs-Manager"), FK = await fiche("Jetable-Abs-Hors"), FA = await fiche("Jetable-Abs-Admin");
  const FL = await fiche("Jetable-Abs-Collab", { manager_id: FM, date_entree: J(-5) });
  const compte = async (nom, role, ficheId) => {
    const email = `jetable-abs-${nom}-${T}${DOM}`;
    const r = await api("POST", "/auth/v1/admin/users", { email, password: MDP, email_confirm: true });
    await api("PATCH", `/rest/v1/profiles?id=eq.${r.d.id}`, { role, collaborateur_id: ficheId, nom: `Jetable ${nom}` });
    ids.comptes.push(r.d.id); return { id: r.d.id, email };
  };
  const A = await compte("admin", "admin", FA), M = await compte("manager", "manager", FM), K = await compte("hors", "manager", FK);
  const L = await compte("collab", "collaborateur", FL);
  const fl0 = await un(`/rest/v1/collaborateurs?id=eq.${FL}&select=solde_conges,solde_rtt,historique_soldes`);
  verifier("nouvelle fiche : 0 jour, congés payés et RTT « à renseigner » (aucune attribution automatique)",
    Number(fl0.solde_conges) === 0 && Number(fl0.solde_rtt) === 0 && fl0.historique_soldes.map((e) => e.action).join(",") === "a_renseigner,a_renseigner");
  // Projet d'ESSAI (devis d'essai accepté) et temps saisis pour la collaboratrice : pour l'alerte « temps déjà saisis ».
  const pr = await rpc("creer_prospect_essai", { p_nom: "Parcours Absences", p_societe: "Parcours Absences SARL", p_adresse: "1 rue de l'Essai",
    p_code_postal: "97200", p_ville: "Fort-de-France", p_pays: "MQ" });
  const dv = (await api("POST", "/rest/v1/devis?select=id", { prospect_id: pr.d, type_mission: "conseil", regime_tva: "taxable", territoire_tva: "MQ",
    taux_tva: 8.5, criteres_tva: { nature_mission: "prestation_intellectuelle", statut_client: "assujetti_france" } })).d[0].id;
  ids.dv = dv;
  await api("POST", "/rest/v1/devis_lignes", { devis_id: dv, designation: "Mission (essai)", quantite: 1, prix_unitaire: 100 });
  await rpc("emettre_devis", { p_devis_id: dv, p_auteur: A.id, p_emetteur: EMETTEUR_DEMO, p_gabarit: "devis-v1" });
  const a0 = await connexion(A.email);
  await a0.goto(`${B}/commercial/devis/${dv}`); await a0.click("button:has-text('Régénérer le PDF')");
  await attendre(async () => (await un(`/rest/v1/devis?id=eq.${dv}&select=pdf_statut`))?.pdf_statut === "disponible");
  await rpc("declarer_envoi_devis", { p_devis_id: dv, p_auteur: A.id, p_date_envoi: new Date().toISOString(), p_canal: "autre", p_destinataire: null });
  await rpc("decider_devis", { p_devis_id: dv, p_auteur: A.id, p_decision: "accepte" });
  const PE = await un(`/rest/v1/projets?devis_id=eq.${dv}&select=id,nom`);
  for (const [n, h] of [[-3, 2], [-2, 3.5]]) {
    await rpc("rh_enregistrer_temps", { p_auteur: A.id, p_temps_id: null, p_collaborateur_id: FL, p_projet_id: PE.id, p_date: J(n), p_heures: h,
      p_commentaire: "Essai Absences", p_motif_derogation: "Essai Absences (régularisation)" });
  }
  verifier("projet d'ESSAI et 2 temps de la collaboratrice (J-3 : 2 h, J-2 : 3,5 h)", !!PE && PE.nom.startsWith("[ESSAI]")
    && (await api("GET", `/rest/v1/temps?collaborateur_id=eq.${FL}&select=id`)).d.length === 2);

  console.log("\n== 1. Collaboratrice : soldes et demandes");
  const l = await connexion(L.email);
  await l.goto(B + "/absences");
  const soldes = await l.locator("[data-mes-soldes]").textContent();
  verifier("ses soldes : « Solde à renseigner » et RTT « droits non renseignés » (pas « 0 »), explications affichées",
    soldes.includes("Solde à renseigner") && soldes.includes("droits non renseignés") && soldes.includes("Cela ne signifie pas que vous n'avez aucun droit"));
  // L'administrateur confirme le solde de congés payés (25 jours transmis), avec un motif.
  await rpc("abs_ajuster_solde", { p_auteur: A.id, p_collaborateur: FL, p_type: "conges_payes", p_ancien: 0, p_nouveau: 25, p_motif: "Solde transmis (essai)" });
  const cp0 = Number((await un(`/rest/v1/collaborateurs?id=eq.${FL}&select=solde_conges`)).solde_conges);
  verifier("solde confirmé par l'administrateur (0 → 25), tracé", cp0 === 25);
  let f = await demande(l, { debut: J(10), fin: J(10), apresMidi: true, finMidi: true, jours: "0.5" });
  verifier("après-midi → midi le même jour : refusé avant l'envoi", await f.locator("button[type=submit]").isDisabled());
  f = await demande(l, { debut: J(10), fin: J(11), finMidi: true, jours: "1.5" });
  await f.locator("button[type=submit]").click();
  verifier("demande de 1,5 jour enregistrée", await vu(l, "Demande enregistrée"));
  const cL = (await un(`/rest/v1/conges?collaborateur_id=eq.${FL}&date_debut=eq.${J(10)}&select=id,essai,statut`));
  verifier("demande « demandée », marquée essai (fiche jetable)", cL?.statut === "demandee" && cL?.essai === true);
  await l.goto(B + "/absences");
  f = await demande(l, { debut: J(11), fin: J(11), finMidi: true, jours: "0.5" });
  await f.locator("button[type=submit]").click();
  verifier("chevauchement refusé par la base, saisie conservée", (await vu(l, "Chevauchement")) && (await formConge(l).locator("input[name=date_debut]").inputValue()) === J(11));
  await l.goto(B + "/absences");
  f = await demande(l, { type: "rtt", debut: J(20), fin: J(20), jours: "1" });
  await f.locator("button[type=submit]").click();
  verifier("demande de RTT enregistrée", await vu(l, "Demande enregistrée"));
  const cR = (await un(`/rest/v1/conges?collaborateur_id=eq.${FL}&type=eq.rtt&select=id`)).id;

  console.log("\n== 2. Collaboratrice : notes de frais et justificatifs");
  const liensDepot = [];
  l.on("request", (q) => { if (q.method() === "PUT" && q.url().includes("/object/upload/sign/")) liensDepot.push(q.url()); });
  await l.goto(B + "/rh/notes-de-frais");
  await note(l, { date: J(-1), montant: "18.4", objet: "Faux justificatif (essai)", fichier: F.faux[0] });
  verifier("faux PDF refusé par le serveur (signature)", await vu(l, "n'est pas un PDF, un JPEG ou un PNG valide"));
  verifier("fichier refusé supprimé du stockage", (await fichiersDe(FL)).length === 0);
  await l.goto(B + "/rh/notes-de-frais");
  f = await note(l, { date: J(-10), montant: "42.5", objet: "Déjeuner (essai)", fichier: F.vrai[0] });
  verifier("dépôt puis refus de la base (dépense avant l'entrée)", await vu(l, "antérieure à l'entrée du collaborateur"));
  verifier("fichier déposé conservé pour la nouvelle tentative", (await fichiersDe(FL)).length === 1);
  await f.locator("input[name=date_depense]").fill(J(-1)); await f.locator("button[type=submit]").click();
  verifier("nouvelle tentative : note créée avec le même fichier", (await vu(l, "Note de frais déposée")) && (await fichiersDe(FL)).length === 1);
  const n1 = await un(`/rest/v1/notes_de_frais?collaborateur_id=eq.${FL}&select=id,justificatif_url,justificatif_empreinte,essai`);
  verifier("empreinte = SHA-256 du fichier envoyé ; note marquée essai", n1.justificatif_empreinte === sha(PDF) && n1.essai === true);
  let r = await l.request.get(`${B}/rh/notes-de-frais/${n1.id}/justificatif`);
  verifier("consultation par lien temporaire : fichier identique", r.ok() && sha(await r.body()) === sha(PDF), `HTTP ${r.status()}`);
  await l.goto(B + "/rh/notes-de-frais");
  const ligne = l.locator(`tr[data-note="${n1.id}"]`);
  await ligne.locator("summary", { hasText: "Modifier" }).click();
  await ligne.locator("input[name=montant]").fill("40"); await ligne.locator("input[name=fichier]").setInputFiles(F.png[0]);
  await ligne.locator("button[type=submit]").click();
  verifier("note soumise modifiée, justificatif remplacé", await vu(ligne, "l'ancien justificatif reste conservé"));
  r = await l.request.get(`${B}/rh/notes-de-frais/${n1.id}/justificatif?ancien=0`);
  verifier("ancien justificatif conservé et consultable", r.ok() && sha(await r.body()) === sha(PDF) && (await fichiersDe(FL)).length === 2);

  console.log("\n== 2b. Dépôt direct : tentatives de contournement (stockage réel)");
  const lien1 = liensDepot.find((u) => u.includes(n1.justificatif_url));
  for (const upsert of ["false", "true"]) {
    const rr = await fetch(lien1, { method: "PUT", body: F.autre[1], headers: { "content-type": "application/pdf", "x-upsert": upsert, apikey: ANON } });
    verifier(`fichier rattaché : lien de dépôt rejoué (x-upsert ${upsert}) refusé`, !rr.ok, `HTTP ${rr.status}`);
  }
  verifier("fichier rattaché inchangé (empreinte enregistrée)", sha(await lireFichier(n1.justificatif_url)) === sha(PDF));
  // Fichier d'un autre collaborateur (manager hors équipe), rattaché à SA note.
  const cheminK = `${FK}/${crypto.randomUUID()}.pdf`;
  const lk = await api("POST", `/storage/v1/object/upload/sign/justificatifs/${cheminK}`, {});
  await fetch(`${U}/storage/v1${lk.d.url}`, { method: "PUT", body: F.autre[1], headers: { "content-type": "application/pdf", apikey: ANON } });
  await rpc("abs_creer_note", { p_auteur: K.id, p_collaborateur: FK, p_date: J(-1), p_montant: 30, p_categorie: "hebergement", p_precision: null,
    p_objet: "Hôtel (autre collaborateur, essai)", p_chemin: cheminK, p_type: "application/pdf", p_taille: F.autre[1].length, p_empreinte: sha(F.autre[1]) });
  const avantFK = (await fichiersDe(FK)).length;
  let stop = await falsifier(l, new RegExp(`"${FL}"`), `"${FK}"`);
  await l.goto(B + "/rh/notes-de-frais");
  await note(l, { date: J(-1), montant: "9", objet: "Falsifié dossier (essai)", fichier: F.autre[0] });
  verifier("lien de dépôt pour le dossier d'un autre : refusé par le serveur", await vu(l, "Vous ne pouvez déposer des justificatifs que pour vous-même."));
  await stop();
  verifier("rien déposé dans le dossier de l'autre collaborateur", (await fichiersDe(FK)).length === avantFK);
  stop = await falsifier(l, new RegExp(`${FL}/[0-9a-f-]{36}\\.pdf`), cheminK);
  await l.goto(B + "/rh/notes-de-frais");
  await note(l, { date: J(-1), montant: "9", objet: "Falsifié chemin (essai)", fichier: F.autre[0] });
  verifier("note désignant le fichier d'un autre : refusée (emplacement non conforme)", await vu(l, "emplacement non conforme"));
  await stop();
  const actuel = (await un(`/rest/v1/notes_de_frais?id=eq.${n1.id}&select=justificatif_url`)).justificatif_url;
  stop = await falsifier(l, new RegExp(`${FL}/[0-9a-f-]{36}\\.pdf`), actuel);
  await l.goto(B + "/rh/notes-de-frais");
  await note(l, { date: J(-1), montant: "9", objet: "Falsifié rattaché (essai)", fichier: F.autre[0] });
  verifier("note désignant un fichier déjà rattaché : refusée", (await vu(l, "déjà rattaché")) || (await vu(l, "emplacement non conforme")));
  await stop();
  verifier("fichiers d'autrui et rattachés intacts ; aucune note falsifiée créée",
    sha(await lireFichier(cheminK)) === sha(F.autre[1]) && sha(await lireFichier(actuel)) === sha(PNG)
    && (await api("GET", "/rest/v1/notes_de_frais?select=id&objet=like.Falsifi*")).d.length === 0);
  // Les dépôts faits pendant ces tentatives ne sont rattachés à rien : ce sont des « dépôts abandonnés » (2e phase).
  for (const o of await fichiersDe(FL)) {
    const c = `${FL}/${o.name}`;
    if ((await rpc("abs_justificatif_rattache", { p_chemin: c })).d === false) etatOrphelins.chemins.push(c);
  }
  etatOrphelins.dossiers = [FL]; etatOrphelins.depose_le = Date.now();
  verifier("dépôts abandonnés du parcours repérés (non rattachés)", etatOrphelins.chemins.length === 2, JSON.stringify(etatOrphelins.chemins));

  console.log("\n== 3. Manager de l'équipe");
  const m = await connexion(M.email);
  await m.goto(B + "/absences");
  await m.locator(`tr[data-conge="${cL.id}"] button`, { hasText: "Valider" }).click();
  verifier("validation : confirmation visible", await vu(m, "Demande validée", "[data-confirmation]"));
  verifier("solde prélevé une fois (− 1,5)", Number((await un(`/rest/v1/collaborateurs?id=eq.${FL}&select=solde_conges`)).solde_conges) === cp0 - 1.5);
  await m.goto(B + "/absences");
  await m.locator(`tr[data-conge="${cR}"] button`, { hasText: "Valider" }).click();
  verifier("RTT sans droits : validation refusée, message explicite", await vu(m.locator(`tr[data-conge="${cR}"]`), "(droits RTT non renseignés)"));
  r = await m.request.get(`${B}/rh/notes-de-frais/${n1.id}/justificatif`);
  verifier("manager de l'équipe : justificatif consultable", r.ok() && sha(await r.body()) === sha(PNG));
  await m.goto(B + "/rh/notes-de-frais");
  await m.locator(`tr[data-note="${n1.id}"] button`, { hasText: "Valider" }).click();
  verifier("note validée par le manager", await vu(m, "Note validée", "[data-confirmation]"));

  console.log("\n== 4. Accès croisés");
  const k = await connexion(K.email);
  await k.goto(B + "/absences");
  verifier("manager hors équipe : aucune demande de la collaboratrice", !(await k.content()).includes("Jetable-Abs-Collab"));
  r = await k.request.get(`${B}/rh/notes-de-frais/${n1.id}/justificatif`, { maxRedirects: 0 });
  verifier("manager hors équipe : justificatif refusé", r.status() === 404, `HTTP ${r.status()}`);
  await k.goto(B + "/rh/notes-de-frais");
  const notesL = (await api("GET", `/rest/v1/notes_de_frais?collaborateur_id=eq.${FL}&select=id`)).d.map((x) => x.id);
  let vuesK = 0; for (const id of notesL) vuesK += await k.locator(`tr[data-note="${id}"]`).count();
  verifier("manager hors équipe : aucune note de la collaboratrice listée (seulement la sienne)", vuesK === 0 && (await k.locator("tr[data-note]").count()) === 1);

  console.log("\n== 5. Administrateur");
  const a = await connexion(A.email);
  await a.goto(B + "/absences/soldes");
  const lf = a.locator(`tr[data-fiche="${FL}"]`);
  await lf.locator("select[name=type]").selectOption("rtt"); await lf.locator("input[name=nouveau]").fill("3");
  await lf.locator("input[name=motif]").fill("Droits RTT (essai)"); await lf.locator("button", { hasText: "Ajuster" }).click();
  verifier("droits RTT renseignés, motivés (confirmation)", await vu(a, "Solde enregistré", "[data-confirmation]"));
  await a.goto(B + "/absences/soldes");
  const lk2 = a.locator(`tr[data-fiche="${FK}"]`);
  verifier("autre nouvelle fiche : « Solde à renseigner »", (await lk2.textContent()).includes("Solde à renseigner"));
  await lk2.locator("select[name=type]").selectOption("conges_payes"); await lk2.locator("input[name=nouveau]").fill("0");
  await lk2.locator("input[name=motif]").fill("Aucun droit acquis (essai)"); await lk2.locator("button", { hasText: "Ajuster" }).click();
  verifier("confirmation explicite d'un solde à 0", await vu(a, "Solde enregistré", "[data-confirmation]"));
  const hk = (await un(`/rest/v1/collaborateurs?id=eq.${FK}&select=historique_soldes`)).historique_soldes.at(-1);
  verifier("confirmation à 0 tracée (action, valeurs, motif, auteur)", hk.action === "confirmation" && Number(hk.avant) === 0 && Number(hk.apres) === 0
    && hk.motif === "Aucun droit acquis (essai)" && hk.auteur === A.id);
  verifier("sa propre fiche : aucun formulaire d'ajustement", (await a.locator(`tr[data-fiche="${FA}"]`).textContent()).includes("ajustement par un autre administrateur"));
  await a.goto(B + "/absences");
  await a.locator(`tr[data-conge="${cR}"] button`, { hasText: "Valider" }).click();
  verifier("RTT validée après renseignement (3 → 2)", (await vu(a, "Demande validée", "[data-confirmation]"))
    && Number((await un(`/rest/v1/collaborateurs?id=eq.${FL}&select=solde_rtt`)).solde_rtt) === 2);
  await a.goto(B + "/absences");
  f = await demande(a, { pour: FA, debut: J(30), fin: J(30), jours: "1" });
  await f.locator("button[type=submit]").click();
  verifier("admin : sa propre demande enregistrée", await vu(a, "Demande enregistrée"));
  const cA = (await un(`/rest/v1/conges?collaborateur_id=eq.${FA}&select=id`)).id;
  await a.goto(B + "/absences");
  verifier("sa propre demande : jamais à décider par lui-même", (await a.locator(`tr[data-conge="${cA}"] button`, { hasText: "Valider" }).count()) === 0);
  // Alerte « temps déjà saisis » : demande rétroactive (administrateur, motif) sur les jours où des temps existent.
  f = await demande(a, { pour: FL, type: "sans_solde", debut: J(-3), fin: J(-2), jours: "2" });
  await formConge(a).locator("input[name=motif_retroactif]").fill("Régularisation (essai)");
  const fr = (iso) => iso.split("-").reverse().join("/");
  verifier("alerte AVANT l'envoi : temps déjà saisis (dates et heures)", (await f.textContent()).includes(`des temps sont déjà saisis sur cette période (${fr(J(-3))} : 2 h ; ${fr(J(-2))} : 3,5 h)`));
  await f.locator("button[type=submit]").click();
  verifier("demande rétroactive motivée enregistrée", await vu(a, "Demande enregistrée"));
  const cRetro = (await un(`/rest/v1/conges?collaborateur_id=eq.${FL}&date_debut=eq.${J(-3)}&select=id`)).id;
  await a.goto(B + "/absences");
  const lr0 = a.locator(`tr[data-conge="${cRetro}"]`);
  verifier("à décider : alerte précise, aucune modification automatique des temps",
    (await lr0.textContent()).includes(`Temps saisis sur cette période : ${fr(J(-3))} (2 h), ${fr(J(-2))} (3,5 h)`)
    && (await api("GET", `/rest/v1/temps?collaborateur_id=eq.${FL}&select=heures&order=date_saisie`)).d.map((x) => Number(x.heures)).join(",") === "2,3.5");
  await lr0.locator("input[name=motif]").fill("Temps déjà saisis (essai)"); await lr0.locator("button", { hasText: "Refuser" }).click();
  verifier("demande refusée avec motif", await vu(a, "Demande refusée", "[data-confirmation]"));
  await a.goto(B + "/rh/notes-de-frais");
  const lr = a.locator(`tr[data-note="${n1.id}"]`);
  await lr.locator("input[name=rembourse_le]").fill(J(0)); await lr.locator("input[name=reference]").fill("VIR-ESSAI");
  await lr.locator("button", { hasText: "Déclarer le remboursement" }).click();
  verifier("remboursement déclaré (aucun virement)", await vu(a, "Remboursement déclaré", "[data-confirmation]"));
  await a.goto(B + "/rh/notes-de-frais");
  await a.locator(`tr[data-note="${n1.id}"] input[aria-label="Motif de l'annulation"]`).fill("Erreur (essai)");
  await a.locator(`tr[data-note="${n1.id}"] button`, { hasText: "Annuler la déclaration" }).click();
  verifier("déclaration annulée, historique complet", (await vu(a, "Déclaration annulée", "[data-confirmation]"))
    && (await un(`/rest/v1/notes_de_frais?id=eq.${n1.id}&select=historique`)).historique.map((e) => e.action).join(",")
       === "soumission,modification,validation,remboursement_declare,remboursement_annule");

  // Dépôts abandonnés : le bouton ne supprime ni un dépôt récent (< 1 h) ni un justificatif rattaché.
  await a.goto(B + "/rh/notes-de-frais");
  await a.locator("button", { hasText: "Supprimer les dépôts abandonnés" }).click();
  verifier("bouton « dépôts abandonnés » : rien de récent supprimé", (await vu(a, "dépôt(s) abandonné(s) supprimé(s)")) || (await vu(a, "Aucun dépôt abandonné")));
  const presents = new Set((await fichiersDe(FL)).map((o) => `${FL}/${o.name}`));
  verifier("dépôts récents et justificatifs rattachés toujours présents", etatOrphelins.chemins.every((c) => presents.has(c))
    && presents.has(n1.justificatif_url) && (await fichiersDe(FK)).length === 1);

  console.log("\n== 6. Fichier altéré dans le stockage, session révoquée");
  const courant = (await un(`/rest/v1/notes_de_frais?id=eq.${n1.id}&select=justificatif_url`)).justificatif_url;
  const altere = Buffer.from(PNG); altere[altere.length - 1] ^= 1;
  await api("PUT", `/storage/v1/object/justificatifs/${courant}`, new Uint8Array(altere), { "Content-Type": "image/png", "x-upsert": "true" });
  r = await a.request.get(`${B}/rh/notes-de-frais/${n1.id}/justificatif`, { maxRedirects: 0 });
  verifier("fichier altéré (même taille) : consultation bloquée", r.status() === 409, `HTTP ${r.status()}`);
  await l.goto(B + "/rh/notes-de-frais");
  await api("PUT", `/auth/v1/admin/users/${L.id}`, { ban_duration: "24h" });
  r = await l.request.get(`${B}/rh/notes-de-frais/${n1.id}/justificatif`, { maxRedirects: 0 });
  verifier("compte bloqué : justificatif refusé (aucun lien émis)", [403, 404].includes(r.status()) || ((r.headers().location ?? "").includes("/connexion")), `HTTP ${r.status()}`);
  const avant = (await fichiersDe(FL)).length;
  await note(l, { date: J(-1), montant: "5", objet: "Après blocage (essai)", fichier: F.vrai[0] });
  await l.waitForTimeout(4000);
  verifier("compte bloqué : rien déposé ni enregistré depuis une page déjà ouverte", (await fichiersDe(FL)).length === avant
    && (await api("GET", `/rest/v1/notes_de_frais?objet=eq.Après blocage (essai)&select=id`)).d.length === 0);
} catch (e) {
  verifier("parcours interrompu", false, e.message.split("\n")[0]);
} finally {
  console.log("\n== 7. Nettoyage (uniquement ce que ce parcours a créé)");
  const na = await api("POST", "/rest/v1/rpc/supprimer_essais_absences", {});
  verifier("essais Absences supprimés (congés, notes)", na.s === 200, JSON.stringify(na.d));
  const restants = [];
  for (const f of ids.fiches) for (const o of await fichiersDe(f)) restants.push(`${f}/${o.name}`);
  // Les dépôts abandonnés sont gardés pour la 2e phase (aucune note, dossier jetable) ; tout le reste est supprimé.
  const chemins = [...new Set([...(na.d?.chemins ?? []), ...restants])].filter((c) => !etatOrphelins.chemins.includes(c));
  if (chemins.length) await api("DELETE", "/storage/v1/object/justificatifs", { prefixes: chemins });
  const nt = await rpc("supprimer_essais_rh", {});
  verifier("temps d'essai supprimés", nt.s === 200, `${nt.d} temps`);
  for (const id of ids.comptes) await api("DELETE", `/auth/v1/admin/users/${id}`);
  for (const id of ids.fiches) { const r = await api("DELETE", `/rest/v1/collaborateurs?id=eq.${id}`); if (r.s >= 400) console.log("    fiche non supprimée :", r.d?.message); }
  const nc = await rpc("supprimer_essais_commercial", {});
  if (nc.d?.pdf_chemins?.length) await api("DELETE", "/storage/v1/object/devis", { prefixes: nc.d.pdf_chemins });
  verifier("essais commerciaux supprimés (devis, client, projet d'essai)", nc.s === 200, JSON.stringify(nc.d));
  if (etatOrphelins.chemins.length) {
    const fichierEtat = `/tmp/etat-orphelins-absences-${T}.json`;
    writeFileSync(fichierEtat, JSON.stringify(etatOrphelins));
    console.log(`  Dépôts abandonnés gardés pour la 2e phase (${etatOrphelins.chemins.length}) : ${fichierEtat}`);
  }
  const restes = {
    comptes: (await api("GET", "/auth/v1/admin/users?per_page=1000")).d.users.filter((u) => u.email.endsWith(DOM)).length,
    fiches: (await api("GET", "/rest/v1/collaborateurs?select=id&email=like.*exemple.invalid")).d.length,
    conges_essai: (await api("GET", "/rest/v1/conges?select=id&essai=is.true")).d.length,
    notes_essai: (await api("GET", "/rest/v1/notes_de_frais?select=id&essai=is.true")).d.length,
    fichiers_jetables_hors_2e_phase: (await Promise.all(ids.fiches.map(fichiersDe))).flat()
      .filter((o) => !etatOrphelins.chemins.some((c) => c.endsWith(`/${o.name}`))).length,
    temps_essai: (await api("GET", "/rest/v1/temps?select=id&commentaire=eq.Essai Absences")).d.length,
    projets_essai: (await api("GET", "/rest/v1/projets?select=id&nom=like.*Parcours Absences*")).d.length,
    devis_essai: ids.dv ? (await api("GET", `/rest/v1/devis?select=id&id=eq.${ids.dv}`)).d.length : 0,
  };
  verifier("aucun reste : comptes, fiches, congés et notes d'essai, fichiers", Object.values(restes).every((v) => v === 0), JSON.stringify(restes));
  const reelsApres = await reels();
  verifier("congés et notes réels : aucun ajouté ni retiré", JSON.stringify(reelsApres) === JSON.stringify(reelsAvant), JSON.stringify(reelsApres));
  await nav.close();
  console.log(`\nBILAN : ${ok}/${ok + ko} contrôles réussis`);
}
