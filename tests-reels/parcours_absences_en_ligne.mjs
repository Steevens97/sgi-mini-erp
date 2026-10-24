// Parcours Absences et notes de frais EN PRODUCTION (après le temps 2), avec des comptes et des fiches JETABLES uniquement.
// - Fiches jetables (@exemple.invalid : congés et notes marqués « essai » par la base) : manager, collaboratrice de son
//   équipe, manager hors équipe, administrateur (avec sa propre fiche jetable). Aucune fiche réelle utilisée.
// - Fichiers d'essai déposés uniquement dans les dossiers de ces fiches jetables. Aucun email, aucun virement.
// - Nettoyage intégré : supprimer_essais_absences → fichiers rendus → comptes → fiches ; vérification « aucun reste ».
// Usage : NODE_USE_ENV_PROXY=1 NODE_EXTRA_CA_CERTS=/root/.ccr/ca-bundle.crt node parcours_absences_en_ligne.mjs <url>
import { chromium } from "playwright";
import { createHash } from "node:crypto";
import { mkdirSync, writeFileSync } from "node:fs";

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
const AUJ = new Intl.DateTimeFormat("en-CA", { timeZone: "America/Martinique" }).format(new Date());
const J = (n) => { const d = new Date(`${AUJ}T12:00:00Z`); d.setUTCDate(d.getUTCDate() + n); return d.toISOString().slice(0, 10); };
const sha = (b) => createHash("sha256").update(b).digest("hex");
const DOSSIER = `/tmp/fichiers-parcours-absences-${T}`;
mkdirSync(DOSSIER, { recursive: true });
const PDF = Buffer.from("%PDF-1.4\n1 0 obj<</Type/Catalog/Pages 2 0 R>>endobj 2 0 obj<</Type/Pages/Kids[]/Count 0>>endobj\ntrailer<</Root 1 0 R>>\n%%EOF\n");
const PNG = Buffer.from("89504e470d0a1a0a0000000d4948445200000001000000010806000000" + "1f15c4890000000d49444154789c6360000002000154a24f5d0000000049454e44ae426082", "hex");
const F = { vrai: [`${DOSSIER}/ticket-essai.pdf`, PDF], png: [`${DOSSIER}/peage-essai.png`, PNG], faux: [`${DOSSIER}/faux-essai.pdf`, Buffer.from("texte, pas un PDF\n")] };
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

const ids = { fiches: [], comptes: [] };
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
  verifier("fiches jetables : congés payés à la valeur de création, RTT 0 « non renseignés »",
    (await un(`/rest/v1/collaborateurs?id=eq.${FL}&select=solde_rtt,historique_soldes`)).historique_soldes.length === 2);

  console.log("\n== 1. Collaboratrice : soldes et demandes");
  const l = await connexion(L.email);
  await l.goto(B + "/absences");
  const soldes = await l.locator("[data-mes-soldes]").textContent();
  verifier("ses soldes : RTT « droits non renseignés » (pas « 0 »), explication affichée",
    soldes.includes("droits non renseignés") && soldes.includes("Cela ne signifie pas que vous n'avez aucun droit"));
  const cp0 = Number((await un(`/rest/v1/collaborateurs?id=eq.${FL}&select=solde_conges`)).solde_conges);
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
  verifier("manager hors équipe : aucune note listée", (await k.locator("tr[data-note]").count()) === 0);

  console.log("\n== 5. Administrateur");
  const a = await connexion(A.email);
  await a.goto(B + "/absences/soldes");
  const lf = a.locator(`tr[data-fiche="${FL}"]`);
  await lf.locator("select[name=type]").selectOption("rtt"); await lf.locator("input[name=nouveau]").fill("3");
  await lf.locator("input[name=motif]").fill("Droits RTT (essai)"); await lf.locator("button", { hasText: "Ajuster" }).click();
  verifier("droits RTT renseignés, motivés (confirmation)", await vu(a, "Solde ajusté", "[data-confirmation]"));
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
  const chemins = [...new Set([...(na.d?.chemins ?? []), ...restants])];
  if (chemins.length) await api("DELETE", "/storage/v1/object/justificatifs", { prefixes: chemins });
  for (const id of ids.comptes) await api("DELETE", `/auth/v1/admin/users/${id}`);
  for (const id of ids.fiches) { const r = await api("DELETE", `/rest/v1/collaborateurs?id=eq.${id}`); if (r.s >= 400) console.log("    fiche non supprimée :", r.d?.message); }
  const restes = {
    comptes: (await api("GET", "/auth/v1/admin/users?per_page=1000")).d.users.filter((u) => u.email.endsWith(DOM)).length,
    fiches: (await api("GET", "/rest/v1/collaborateurs?select=id&email=like.*exemple.invalid")).d.length,
    conges_essai: (await api("GET", "/rest/v1/conges?select=id&essai=is.true")).d.length,
    notes_essai: (await api("GET", "/rest/v1/notes_de_frais?select=id&essai=is.true")).d.length,
    fichiers_jetables: (await Promise.all(ids.fiches.map(fichiersDe))).flat().length,
  };
  verifier("aucun reste : comptes, fiches, congés et notes d'essai, fichiers", Object.values(restes).every((v) => v === 0), JSON.stringify(restes));
  const reelsApres = await reels();
  verifier("congés et notes réels : aucun ajouté ni retiré", JSON.stringify(reelsApres) === JSON.stringify(reelsAvant), JSON.stringify(reelsApres));
  await nav.close();
  console.log(`\nBILAN : ${ok}/${ok + ko} contrôles réussis`);
}
