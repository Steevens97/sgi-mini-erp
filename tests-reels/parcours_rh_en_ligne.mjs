// Parcours RH complet EN PRODUCTION, avec des comptes et des fiches JETABLES uniquement.
// - Fiches jetables (@exemple.invalid) et comptes jetables : admin sans fiche, manager, collaboratrice (son
//   équipe), manager hors équipe. Aucune fiche réelle utilisée, aucune fiche réelle créée.
// - Tous les temps sont saisis sur un projet d'ESSAI (issu d'un devis d'essai accepté) : le nettoyage peut
//   les effacer (supprimer_essais_rh), même validés. Aucun numéro réel, aucun email.
// - Nettoyage intégré, dans l'ordre imposé par les protections : temps d'essai, comptes, fiches, projet
//   manuel, essais commerciaux et PDF.
// Usage : NODE_USE_ENV_PROXY=1 NODE_EXTRA_CA_CERTS=/root/.ccr/ca-bundle.crt node parcours_rh_en_ligne.mjs <url>
import { chromium } from "playwright";

const B = process.argv[2] ?? "https://sgi-mini-erp.vercel.app";
const U = process.env.NEXT_PUBLIC_SUPABASE_URL, S = process.env.SUPABASE_SERVICE_ROLE_KEY;
const T = Date.now(), DOM = "@exemple.invalid";
let ok = 0, ko = 0;
const verifier = (l, c, d = "") => { c ? ok++ : ko++; console.log(`  [${c ? "OK " : "ÉCHEC"}] ${l}${d ? `  (${d})` : ""}`); };
async function api(m, p, c, h = {}) {
  const r = await fetch(U + p, { method: m, headers: { apikey: S, Authorization: `Bearer ${S}`, "Content-Type": "application/json", Prefer: "return=representation", ...h }, body: c === undefined ? undefined : JSON.stringify(c) });
  const t = await r.text(); let d = null; try { d = t ? JSON.parse(t) : null; } catch { d = t; }
  return { s: r.status, d };
}
const rpc = (f, a) => api("POST", `/rest/v1/rpc/${f}`, a);
const un = async (p) => (await api("GET", p)).d?.[0];
const attendre = async (fn, essais = 60) => { for (let i = 0; i < essais; i++) { if (await fn()) return true; await new Promise((r) => setTimeout(r, 1000)); } return false; };
const AUJ = new Intl.DateTimeFormat("en-CA", { timeZone: "America/Martinique" }).format(new Date());
const jour = (n) => { const d = new Date(`${AUJ}T12:00:00Z`); d.setUTCDate(d.getUTCDate() + n); return d.toISOString().slice(0, 10); };
const MDP = "Rh-Jetable-2026!";
const EMETTEUR_DEMO = { raison_sociale: "[DÉMO] SG Ingénierie", forme_juridique: "SAS", capital_social: "[DÉMO]", adresse: "[DÉMO] adresse",
  code_postal: "97200", ville: "Fort-de-France", siret: "00000000000000", immatriculation: "[DÉMO] immatriculation", tva_intracom: "[DÉMO]",
  validite_jours: "30", telephone: "", email: "", conditions_paiement: "", obligation_assurance: "non_requise" };

const nav = await chromium.launch({ executablePath: "/opt/pw-browsers/chromium-1194/chrome-linux/chrome", proxy: { server: process.env.HTTPS_PROXY } });
async function connexion(email) {
  const page = await (await nav.newContext({ ignoreHTTPSErrors: true })).newPage();
  page.on("dialog", (d) => d.accept());
  await page.goto(B + "/connexion"); await page.fill("#email", email); await page.fill("#mot_de_passe", MDP);
  await page.click("button[type=submit]"); await page.waitForURL((u) => !u.pathname.startsWith("/connexion"), { timeout: 30000 });
  return page;
}
async function saisir(page, { projet, date, heures, commentaire, motif, contourner = false }) {
  const f = page.locator("form", { has: page.locator("button:has-text('Enregistrer')") }).first();
  if (projet) await f.locator("[name=projet_id]").selectOption(projet);
  if (date) await f.locator("[name=date_saisie]").fill(date);
  if (contourner) await f.locator("[name=heures]").evaluate((e) => { e.removeAttribute("min"); e.removeAttribute("required"); e.type = "text"; });
  if (heures !== undefined) await f.locator("[name=heures]").fill(String(heures));
  if (commentaire !== undefined) await f.locator("[name=commentaire]").fill(commentaire);
  if (motif !== undefined) await f.locator("[name=motif_derogation]").fill(motif);
  await f.locator("button:has-text('Enregistrer')").click();
}
const statut = async (page) => (await page.locator("[role=status]").last().textContent({ timeout: 30000 })) ?? "";
const temps = async (id) => un(`/rest/v1/temps?id=eq.${id}&select=statut,heures,date_saisie,collaborateur_id,saisi_par,saisi_par_nom,valide_par_nom,historique`);
const sommeJour = async (f, d) => ((await api("GET", `/rest/v1/temps?collaborateur_id=eq.${f}&date_saisie=eq.${d}&select=heures`)).d ?? []).reduce((a, x) => a + Number(x.heures), 0);

const ids = { fiches: [], comptes: [], projetManuel: null };
try {
  console.log("== 0. Préparation (clé secrète) : fiches et comptes jetables, projet d'ESSAI");
  const fiche = async (nom, manager) => (await api("POST", "/rest/v1/collaborateurs?select=id", { nom, prenom: "Essai", email: `${nom.toLowerCase()}-${T}${DOM}`, poste: "Test", taux_horaire: 1, manager_id: manager })).d[0].id;
  const FM = await fiche("Jetable-Manager"); ids.fiches.push(FM);
  const FC = await fiche("Jetable-Collab", FM); ids.fiches.unshift(FC);
  const FH = await fiche("Jetable-HorsEquipe"); ids.fiches.unshift(FH);
  const compte = async (nom, role, ficheId) => {
    const email = `jetable-rh-${nom}-${T}${DOM}`;
    const r = await api("POST", "/auth/v1/admin/users", { email, password: MDP, email_confirm: true });
    await api("PATCH", `/rest/v1/profiles?id=eq.${r.d.id}`, { role, collaborateur_id: ficheId, nom: `Jetable ${nom}` });
    ids.comptes.push(r.d.id); return { id: r.d.id, email };
  };
  const A = await compte("admin", "admin", null), M = await compte("manager", "manager", FM);
  const C = await compte("collab", "collaborateur", FC), H = await compte("horsequipe", "manager", FH);
  verifier("4 comptes jetables et 3 fiches jetables créés", ids.comptes.length === 4 && ids.fiches.length === 3);
  const pr = await rpc("creer_prospect_essai", { p_nom: "Parcours RH", p_societe: "Parcours RH SARL", p_adresse: "1 rue de l'Essai", p_code_postal: "97200", p_ville: "Fort-de-France", p_pays: "MQ" });
  const dv = (await api("POST", "/rest/v1/devis?select=id", { prospect_id: pr.d, type_mission: "conseil", regime_tva: "taxable", territoire_tva: "MQ", taux_tva: 8.5,
    criteres_tva: { nature_mission: "prestation_intellectuelle", statut_client: "assujetti_france" } })).d[0].id;
  await api("POST", "/rest/v1/devis_lignes", { devis_id: dv, designation: "Mission RH (essai)", quantite: 1, prix_unitaire: 100 });
  await rpc("emettre_devis", { p_devis_id: dv, p_auteur: A.id, p_emetteur: EMETTEUR_DEMO, p_gabarit: "devis-v1" });
  const a = await connexion(A.email);
  await a.goto(`${B}/commercial/devis/${dv}`); await a.click("button:has-text('Régénérer le PDF')");
  await attendre(async () => (await un(`/rest/v1/devis?id=eq.${dv}&select=pdf_statut`))?.pdf_statut === "disponible");
  await rpc("declarer_envoi_devis", { p_devis_id: dv, p_auteur: A.id, p_date_envoi: new Date().toISOString(), p_canal: "email", p_destinataire: `essai-rh${DOM}` });
  await rpc("decider_devis", { p_devis_id: dv, p_auteur: A.id, p_decision: "accepte" });
  const PE = (await un(`/rest/v1/projets?devis_id=eq.${dv}&select=id,nom`));
  verifier("projet d'ESSAI créé par l'acceptation du devis d'essai (automatisme Commercial)", !!PE && PE.nom.startsWith("[ESSAI]"), PE?.nom);

  console.log("\n== 1. Admin : fiches et projets");
  await a.goto(B + "/rh/collaborateurs");
  const fn = a.locator("form", { has: a.locator("button:has-text('Créer la fiche')") });
  await fn.locator("[name=nom]").fill("Jetable-Fiche-UI"); await fn.locator("[name=email]").fill(`jetable-fiche-ui-${T}${DOM}`);
  await fn.locator("[name=manager_id]").selectOption(FM);
  await fn.locator("[name=taux_horaire]").evaluate((e) => e.removeAttribute("required"));
  await fn.locator("button:has-text('Créer la fiche')").click();
  verifier("création avec taux vide : message clair, saisie conservée, rien créé",
    (await statut(a)).includes("taux horaire est obligatoire") && (await fn.locator("[name=nom]").inputValue()) === "Jetable-Fiche-UI"
    && !(await un(`/rest/v1/collaborateurs?nom=eq.Jetable-Fiche-UI&select=id`)));
  await fn.locator("[name=taux_horaire]").fill("2");
  await fn.locator("button:has-text('Créer la fiche')").click();
  verifier("création de la fiche (taux saisi)", await attendre(async () => !!(await un(`/rest/v1/collaborateurs?nom=eq.Jetable-Fiche-UI&select=id`))));
  const FUI = (await un(`/rest/v1/collaborateurs?nom=eq.Jetable-Fiche-UI&select=id`)).id; ids.fiches.unshift(FUI);
  await a.goto(`${B}/rh/collaborateurs/${FUI}`);
  verifier("écran d'édition admin : taux relu (2)", (await a.locator("[name=taux_horaire]").inputValue()) === "2");
  await a.locator("[name=poste]").fill("Poste modifié");
  await a.locator("button:has-text('Enregistrer la fiche')").click();
  verifier("édition de la fiche enregistrée", await attendre(async () => (await un(`/rest/v1/collaborateurs?id=eq.${FUI}&select=poste`))?.poste === "Poste modifié"));
  await a.goto(`${B}/rh/collaborateurs/${FM}`);
  const opts = await a.locator("[name=manager_id] option").evaluateAll((o) => o.map((x) => x.value));
  verifier("manager proposé pour Jetable-Manager : ni lui-même, ni ses subordonnés", !opts.includes(FM) && !opts.includes(FC) && !opts.includes(FUI));
  await a.goto(B + "/rh/projets");
  const fp = a.locator("form", { has: a.locator("button:has-text('Créer le projet')") });
  await fp.locator("[name=nom]").fill(`Jetable mission interne ${T}`); await fp.locator("button:has-text('Créer le projet')").click();
  verifier("projet sans devis créé par l'admin", await attendre(async () => !!(await un(`/rest/v1/projets?nom=eq.Jetable mission interne ${T}&select=id`))));
  ids.projetManuel = (await un(`/rest/v1/projets?nom=eq.Jetable mission interne ${T}&select=id`)).id;

  console.log("\n== 2. Admin saisit pour la collaboratrice ; durée nulle refusée");
  await a.goto(`${B}/rh/temps?pour=${FC}`);
  await saisir(a, { projet: PE.id, date: AUJ, heures: 0, contourner: true });
  verifier("0 heure refusé (« zéro heure »), rien enregistré", (await statut(a)).includes("zéro heure") && (await sommeJour(FC, AUJ)) === 0);
  await saisir(a, { projet: PE.id, date: AUJ, heures: "2", commentaire: "saisi par l'admin" });
  verifier("brouillon de 2 h saisi par l'admin pour la collaboratrice", await attendre(async () => (await sommeJour(FC, AUJ)) === 2));
  const TA = (await un(`/rest/v1/temps?collaborateur_id=eq.${FC}&commentaire=eq.saisi par l'admin&select=id`)).id;
  const ta = await temps(TA);
  verifier("auteur de la saisie (admin) distinct du propriétaire", ta.saisi_par === A.id && ta.collaborateur_id === FC);

  console.log("\n== 3. Collaboratrice : reprise, cumuls, soumission, droits");
  const c = await connexion(C.email);
  await c.goto(B + "/rh/temps");
  const l = c.locator(`tr[data-temps="${TA}"]`);
  verifier("le brouillon de l'admin apparaît « pour vous »", (await l.textContent()).includes("pour vous"));
  await l.locator("a:has-text('Corriger')").click(); await c.waitForURL(/corriger=/);
  await saisir(c, { heures: "3", commentaire: "repris par la collaboratrice" });
  verifier("reprise : 3 h, auteur d'origine conservé, correction tracée à son nom",
    await attendre(async () => { const t = await temps(TA); return Number(t.heures) === 3 && t.saisi_par === A.id && t.historique.at(-1).action === "correction" && t.historique.at(-1).auteur === C.id; }));
  await c.goto(B + "/rh/temps");
  await saisir(c, { projet: PE.id, date: AUJ, heures: "8" });
  verifier("ajout de 8 h (cumul 11 h)", await attendre(async () => (await sommeJour(FC, AUJ)) === 11));
  await c.goto(B + "/rh/temps");
  const f2 = c.locator("form", { has: c.locator("button:has-text('Enregistrer')") }).first();
  await f2.locator("[name=projet_id]").selectOption(PE.id); await f2.locator("[name=heures]").fill("2");
  verifier("alerte AVANT l'envoi : 13 h", (await c.locator("[role=alert]", { hasText: "Alerte : 13 h" }).count()) === 1);
  await f2.locator("button:has-text('Enregistrer')").click();
  verifier("refus au-delà de 12 h pour la collaboratrice", (await statut(c)).includes("12 h") && (await sommeJour(FC, AUJ)) === 11);
  await c.goto(B + "/rh/temps"); await saisir(c, { projet: PE.id, date: jour(-1), heures: "10" });
  await attendre(async () => (await sommeJour(FC, jour(-1))) === 10);
  const T8 = (await un(`/rest/v1/temps?collaborateur_id=eq.${FC}&date_saisie=eq.${AUJ}&heures=eq.8&select=id`)).id;
  await c.goto(`${B}/rh/temps?corriger=${T8}`); await saisir(c, { date: jour(-1) });
  verifier("déplacer 8 h vers une journée à 10 h : refusé (cumul recalculé)", (await statut(c)).includes("12 h") && (await temps(T8)).date_saisie === AUJ);
  await c.goto(B + "/rh/temps"); await c.locator(`tr[data-temps="${TA}"] button:has-text('Soumettre')`).click();
  verifier("soumission", await attendre(async () => (await temps(TA)).statut === "soumis"));
  await c.goto(B + "/rh/validation");
  verifier("Validation inaccessible à la collaboratrice", new URL(c.url()).pathname === "/rh");
  await c.goto(B + "/rh/collaborateurs");
  verifier("Collaborateurs : sa fiche seulement", (await c.locator("main tbody tr").count()) === 1);
  verifier("fiche d'un autre : introuvable", (await c.goto(`${B}/rh/collaborateurs/${FM}`)).status() === 404);
  for (const ch of ["/rh/collaborateurs", "/rh/temps", "/rh/projets", `/rh/collaborateurs/${FC}`]) {
    await c.goto(B + ch); verifier(`collaboratrice ${ch} : aucun taux dans la page reçue`, !(await c.content()).includes("taux_horaire"));
  }
  await c.goto(B + "/rh/temps");
  verifier("ne voit que ses propres temps", (await c.locator("tbody tr[data-temps]").count()) === ((await api("GET", `/rest/v1/temps?collaborateur_id=eq.${FC}&select=id`)).d.length));

  console.log("\n== 4. Manager : validation par un tiers, projets (statut seulement)");
  const m = await connexion(M.email);
  await m.goto(B + "/rh/validation");
  await m.locator(`tr[data-temps="${TA}"] button:has-text('Valider')`).click();
  verifier("validation par le responsable (tiers)", await attendre(async () => { const t = await temps(TA); return t.statut === "valide" && t.valide_par_nom === "Jetable manager"; }));
  await m.goto(B + "/rh/projets");
  const lp = m.locator(`tr[data-projet="Jetable mission interne ${T}"]`);
  verifier("projets : le manager n'a que le champ statut", (await lp.locator("[name=nom]").count()) === 0 && (await lp.locator("[name=statut]").count()) === 1);
  await lp.locator("[name=statut]").selectOption("termine"); await lp.locator("button:has-text('Enregistrer')").click();
  verifier("le manager passe le projet en « terminé »", await attendre(async () => (await un(`/rest/v1/projets?id=eq.${ids.projetManuel}&select=statut`)).statut === "termine"));
  await lp.locator("form").evaluate((f) => { const i = document.createElement("input"); i.name = "nom"; i.value = "Renommé"; f.appendChild(i); });
  await lp.locator("[name=statut]").selectOption("en_cours"); await lp.locator("button:has-text('Enregistrer')").click();
  verifier("requête forcée avec un nom : statut changé, nom intact", await attendre(async () => {
    const p = await un(`/rest/v1/projets?id=eq.${ids.projetManuel}&select=statut,nom`); return p.statut === "en_cours" && p.nom === `Jetable mission interne ${T}`; }));
  for (const ch of ["/rh/collaborateurs", `/rh/collaborateurs/${FC}`, "/rh/validation", "/rh/temps"]) {
    await m.goto(B + ch); verifier(`manager ${ch} : aucun taux dans la page reçue`, !(await m.content()).includes("taux_horaire"));
  }
  await m.goto(B + "/rh/temps"); await saisir(m, { projet: PE.id, date: AUJ, heures: "3", commentaire: "temps du manager" });
  await attendre(async () => (await sommeJour(FM, AUJ)) === 3);
  const TM = (await un(`/rest/v1/temps?collaborateur_id=eq.${FM}&select=id`)).id;
  await m.goto(B + "/rh/temps"); await m.locator(`tr[data-temps="${TM}"] button:has-text('Soumettre')`).click();
  await attendre(async () => (await temps(TM)).statut === "soumis");
  await m.goto(B + "/rh/validation");
  verifier("le manager ne se voit pas proposer ses propres temps", (await m.locator(`tr[data-temps="${TM}"]`).count()) === 0);

  console.log("\n== 5. Manager hors équipe");
  const h = await connexion(H.email);
  await h.goto(B + "/rh/validation");
  verifier("aucun temps de l'autre équipe proposé", (await h.locator(`tr[data-temps="${TM}"], tr[data-temps="${TA}"]`).count()) === 0);

  console.log("\n== 6. Admin : validation du manager, réouverture motivée, dérogations, plafond absolu");
  await a.goto(B + "/rh/validation"); await a.locator(`tr[data-temps="${TM}"] button:has-text('Valider')`).click();
  verifier("l'admin valide les temps du manager", await attendre(async () => (await temps(TM)).statut === "valide"));
  await a.goto(B + "/rh/validation");
  const lv = a.locator(`tr[data-temps="${TA}"]`).last();
  await lv.locator("[name=motif]").fill("Erreur de projet signalée"); await lv.locator("button:has-text('Rouvrir')").click();
  verifier("réouverture motivée : brouillon, motif, validation précédente conservée",
    await attendre(async () => { const t = await temps(TA); const e = t.historique.at(-1);
      return t.statut === "brouillon" && e.action === "reouverture" && e.motif === "Erreur de projet signalée" && e.validation_precedente?.valide_par_nom === "Jetable manager"; }));
  await a.goto(`${B}/rh/temps?pour=${FC}`);
  await saisir(a, { projet: PE.id, date: jour(-2), heures: "12" });
  await attendre(async () => (await sommeJour(FC, jour(-2))) === 12);
  await a.goto(`${B}/rh/temps?pour=${FC}`);
  await saisir(a, { projet: PE.id, date: jour(-2), heures: "1" });
  verifier("admin : 13 h sans motif refusé", (await statut(a)).includes("motif") && (await sommeJour(FC, jour(-2))) === 12);
  await a.goto(`${B}/rh/temps?pour=${FC}`);
  await saisir(a, { projet: PE.id, date: jour(-2), heures: "1", motif: "Astreinte de chantier (essai)" });
  verifier("admin : 13 h avec motif = dérogation tracée", await attendre(async () => (await sommeJour(FC, jour(-2))) === 13));
  await a.goto(`${B}/rh/temps?pour=${FC}`);
  const f24 = a.locator("form", { has: a.locator("button:has-text('Enregistrer')") }).first();
  await f24.locator("[name=projet_id]").selectOption(PE.id); await f24.locator("[name=date_saisie]").fill(jour(-2));
  await f24.locator("[name=heures]").fill("11.25"); await f24.locator("[name=motif_derogation]").fill("Test du plafond absolu");
  verifier("24,25 h : l'écran prévient « impossible, même pour l'administrateur » et bloque le bouton",
    (await a.locator("[role=alert]", { hasText: "enregistrement impossible, même pour l'administrateur" }).count()) === 1
    && (await f24.locator("button:has-text('Enregistrer')").isDisabled()));
  await f24.locator("button:has-text('Enregistrer')").evaluate((b) => b.removeAttribute("disabled"));
  await f24.locator("button:has-text('Enregistrer')").click();
  verifier("24,25 h, bouton forcé : refus absolu par la base, même pour l'admin avec motif",
    (await statut(a)).includes("plafond absolu") && (await sommeJour(FC, jour(-2))) === 13);
  const der = (await api("GET", `/rest/v1/temps?collaborateur_id=eq.${FC}&date_saisie=eq.${jour(-2)}&heures=eq.1&select=historique`)).d[0];
  verifier("événement « dérogation » avec motif et cumul 13 h", der.historique.some((e) => e.action === "derogation" && e.motif === "Astreinte de chantier (essai)" && Number(e.cumul_jour) === 13));
  await c.goto(B + "/rh/temps"); await c.locator(`tr[data-temps="${TA}"] summary`).click();
  verifier("historique complet visible par la collaboratrice",
    /Saisie.*Correction.*Soumission.*Validation.*Réouverture/s.test(await c.locator(`tr[data-temps="${TA}"] details`).textContent()));

  console.log("\n== 7. Protections en production");
  const supF = await api("DELETE", `/rest/v1/collaborateurs?id=eq.${FC}`);
  verifier("supprimer une fiche qui a des temps : refusé (même clé secrète)", supF.s >= 400 &&
    /^Suppression refusée : la fiche .+ porte des temps(, .+)?\. Renseignez plutôt sa date de sortie\.$/.test(String(supF.d?.message)), supF.d?.message);
  verifier("fiche refusée toujours présente", (await api("GET", `/rest/v1/collaborateurs?id=eq.${FC}&select=id`)).d.length === 1);
  const supP = await api("DELETE", `/rest/v1/projets?id=eq.${PE.id}`);
  verifier("supprimer un projet qui a des temps : refusé", supP.s >= 400, supP.d?.message);
} catch (e) {
  verifier("parcours interrompu", false, e.message.split("\n")[0]);
} finally {
  console.log("\n== 8. Nettoyage (uniquement ce que ce parcours a créé)");
  const nt = await rpc("supprimer_essais_rh", {});
  verifier("temps d'essai supprimés", nt.s === 200, `${nt.d} temps`);
  for (const id of ids.comptes) await api("DELETE", `/auth/v1/admin/users/${id}`);
  for (const id of ids.fiches) { const r = await api("DELETE", `/rest/v1/collaborateurs?id=eq.${id}`); if (r.s >= 400) console.log("    fiche non supprimée :", r.d?.message); }
  if (ids.projetManuel) await api("DELETE", `/rest/v1/projets?id=eq.${ids.projetManuel}`);
  const nc = await rpc("supprimer_essais_commercial", {});
  if (nc.d?.pdf_chemins?.length) await api("DELETE", "/storage/v1/object/devis", { prefixes: nc.d.pdf_chemins });
  verifier("essais commerciaux supprimés", nc.s === 200, JSON.stringify(nc.d));
  const restes = {
    comptes: (await api("GET", "/auth/v1/admin/users?per_page=1000")).d.users.filter((u) => u.email.endsWith(DOM)).length,
    fiches: (await api("GET", "/rest/v1/collaborateurs?select=id&email=like.*exemple.invalid")).d.length,
    temps_jetables: (await api("GET", "/rest/v1/temps?select=id&saisi_par=not.is.null")).d.length,
    projets: (await api("GET", `/rest/v1/projets?select=id&or=(nom.like.*ESSAI*,nom.like.Jetable*)`)).d.length,
    fichiers_devis: (await api("POST", "/storage/v1/object/list/devis", { prefix: "" })).d.length,
    fichiers_justificatifs: (await api("POST", "/storage/v1/object/list/justificatifs", { prefix: "" })).d.length,
    compteurs: (await api("GET", "/rest/v1/compteurs?select=cle")).d.length,
  };
  verifier("aucun reste : comptes, fiches, temps, projets, fichiers, compteurs", Object.values(restes).every((v) => v === 0), JSON.stringify(restes));
  await nav.close();
  console.log(`\nBILAN : ${ok}/${ok + ko} contrôles réussis`);
}
