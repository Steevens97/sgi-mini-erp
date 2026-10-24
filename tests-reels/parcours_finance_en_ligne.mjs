// Parcours Finance EN PRODUCTION (après le temps 2), avec des comptes, des fiches et des données d'ESSAI uniquement.
// - Facture d'ESSAI seulement (ESSAI-FAC, compteur d'essai, filigrane « ESSAI — SANS VALEUR ») : aucune facture réelle,
//   aucun numéro réel, aucun email. Projet d'ESSAI issu d'un devis d'essai accepté ; temps saisis pour une fiche jetable.
// - Vérifie : mode et tarif à date d'effet (tarif nul refusé, confirmation périmée, correction tracée), aperçu sans
//   écriture, écart d'arrondi expliqué, aperçu périmé, émission unique (second onglet), PDF archivé = téléchargé,
//   envoi déclaré, paiement partiel refusé, règlement intégral et correction, droits des autres rôles, émission réelle
//   bloquée (coordonnées et conditions vides).
// - Nettoyage intégré : essais Finance → essais RH → comptes → fiches → essais Commercial → fichiers des deux buckets.
// Usage : NODE_USE_ENV_PROXY=1 NODE_EXTRA_CA_CERTS=/root/.ccr/ca-bundle.crt node parcours_finance_en_ligne.mjs <url>
import { chromium } from "playwright";
import { createHash } from "node:crypto";
import { inflateSync } from "node:zlib";

const B = process.argv[2] ?? "https://sgi-mini-erp.vercel.app";
const U = process.env.NEXT_PUBLIC_SUPABASE_URL, S = process.env.SUPABASE_SERVICE_ROLE_KEY, ANON = process.env.NEXT_PUBLIC_SUPABASE_ANON_KEY;
const T = Date.now(), DOM = "@exemple.invalid", MDP = "Fin-Jetable-2026!";
let ok = 0, ko = 0;
const verifier = (l, c, d = "") => { c ? ok++ : ko++; console.log(`  [${c ? "OK " : "ÉCHEC"}] ${l}${d ? `  (${d})` : ""}`); };
async function api(m, p, c, h = {}, cle = S, jeton = S) {
  const r = await fetch(U + p, { method: m, headers: { apikey: cle, Authorization: `Bearer ${jeton}`, "Content-Type": "application/json", Prefer: "return=representation", ...h }, body: c === undefined ? undefined : JSON.stringify(c) });
  const t = await r.text(); let d = null; try { d = t ? JSON.parse(t) : null; } catch { d = t; }
  return { s: r.status, d };
}
const rpc = (f, a) => api("POST", `/rest/v1/rpc/${f}`, a);
const un = async (p) => (await api("GET", p)).d?.[0];
const attendre = async (fn, essais = 60) => { for (let i = 0; i < essais; i++) { if (await fn()) return true; await new Promise((r) => setTimeout(r, 1000)); } return false; };
const AUJ = new Intl.DateTimeFormat("en-CA", { timeZone: "America/Martinique" }).format(new Date());
const [an, mo] = AUJ.split("-").map(Number);
const MOIS = mo === 1 ? `${an - 1}-12` : `${an}-${String(mo - 1).padStart(2, "0")}`;
const J = (n) => `${MOIS}-${String(n).padStart(2, "0")}`;
const EMETTEUR_DEMO = { raison_sociale: "[DÉMO] SG Ingénierie", forme_juridique: "SAS", capital_social: "[DÉMO]", adresse: "[DÉMO] adresse",
  code_postal: "97200", ville: "Fort-de-France", siret: "00000000000000", immatriculation: "[DÉMO] immatriculation", tva_intracom: "[DÉMO]",
  validite_jours: "30", telephone: "", email: "", conditions_paiement: "", obligation_assurance: "non_requise" };
const TVA = "regime_tva=taxable&territoire_tva=MQ&taux_tva=8.5&nature_mission=prestation_intellectuelle&statut_client=assujetti_france";

// Proxy du conteneur pour le site en ligne ; aucun pour une répétition sur la pile locale (127.0.0.1).
const nav = await chromium.launch({ executablePath: "/opt/pw-browsers/chromium-1194/chrome-linux/chrome",
  ...(process.env.HTTPS_PROXY && !B.startsWith("http://127.0.0.1") ? { proxy: { server: process.env.HTTPS_PROXY } } : {}) });
async function connexion(email) {
  const page = await (await nav.newContext({ ignoreHTTPSErrors: true })).newPage();
  page.on("dialog", (d) => d.accept());
  await page.goto(B + "/connexion"); await page.fill("#email", email); await page.fill("#mot_de_passe", MDP);
  await page.click("button[type=submit]"); await page.waitForURL((u) => !u.pathname.startsWith("/connexion"), { timeout: 30000 });
  return page;
}
const vu = async (page, texte, selecteur = "[role=status]") => {
  try { await page.locator(selecteur, { hasText: texte }).first().waitFor({ timeout: 40000 }); return true; } catch { return false; }
};
// Texte d'un PDF (flux compressés, texte en hexadécimal WinAnsi écrit par pdf-lib).
const WINANSI = { "€": 0x80, "…": 0x85, "•": 0x95, "–": 0x96, "—": 0x97 };
function pdfContient(pdf, texte) {
  const brut = Buffer.from(pdf); const morceaux = []; let i = 0;
  for (;;) {
    const debut = brut.indexOf("stream\n", i); if (debut < 0) break;
    const fin = brut.indexOf("\nendstream", debut);
    try { morceaux.push(inflateSync(brut.subarray(debut + 7, fin)).toString("latin1")); } catch { /* flux non compressé */ }
    i = fin + 10;
  }
  const hex = Buffer.from([...texte].map((c) => WINANSI[c] ?? c.charCodeAt(0))).toString("hex").toUpperCase();
  return morceaux.join("\n").toUpperCase().includes(hex);
}
const jetonDe = async (email) => (await api("POST", "/auth/v1/token?grant_type=password", { email, password: MDP }, {}, ANON, ANON)).d.access_token;

const ids = { fiches: [], comptes: [] };
try {
  console.log("== 0. Préparation (clé secrète) : comptes et fiches jetables, projet d'ESSAI, temps validés");
  const fiche = async (nom, manager) => (await api("POST", "/rest/v1/collaborateurs?select=id", { nom, prenom: "Essai", email: `${nom.toLowerCase()}-${T}${DOM}`, poste: "Test", taux_horaire: 37, manager_id: manager })).d[0].id;
  const FM = await fiche("Jetable-Fin-Manager"); ids.fiches.push(FM);
  const FC = await fiche("Jetable-Fin-Collab", FM); ids.fiches.unshift(FC);
  const compte = async (nom, role, ficheId) => {
    const email = `jetable-fin-${nom}-${T}${DOM}`;
    const r = await api("POST", "/auth/v1/admin/users", { email, password: MDP, email_confirm: true });
    await api("PATCH", `/rest/v1/profiles?id=eq.${r.d.id}`, { role, collaborateur_id: ficheId, nom: `Jetable ${nom}` });
    ids.comptes.push(r.d.id); return { id: r.d.id, email };
  };
  const A = await compte("admin", "admin", null), M = await compte("manager", "manager", FM), C = await compte("collab", "collaborateur", FC);
  const pr = await rpc("creer_prospect_essai", { p_nom: "Parcours Finance", p_societe: "Parcours Finance SARL", p_adresse: "1 rue de l'Essai", p_code_postal: "97200", p_ville: "Fort-de-France", p_pays: "MQ" });
  const dv = (await api("POST", "/rest/v1/devis?select=id", { prospect_id: pr.d, type_mission: "conseil", regime_tva: "taxable", territoire_tva: "MQ", taux_tva: 8.5,
    criteres_tva: { nature_mission: "prestation_intellectuelle", statut_client: "assujetti_france" } })).d[0].id;
  await api("POST", "/rest/v1/devis_lignes", { devis_id: dv, designation: "Régie (essai)", quantite: 1, prix_unitaire: 100 });
  await rpc("emettre_devis", { p_devis_id: dv, p_auteur: A.id, p_emetteur: EMETTEUR_DEMO, p_gabarit: "devis-v1" });
  const a = await connexion(A.email);
  await a.goto(`${B}/commercial/devis/${dv}`); await a.click("button:has-text('Régénérer le PDF')");
  await attendre(async () => (await un(`/rest/v1/devis?id=eq.${dv}&select=pdf_statut`))?.pdf_statut === "disponible");
  await rpc("declarer_envoi_devis", { p_devis_id: dv, p_auteur: A.id, p_date_envoi: new Date().toISOString(), p_canal: "autre", p_destinataire: null });
  await rpc("decider_devis", { p_devis_id: dv, p_auteur: A.id, p_decision: "accepte" });
  const PE = await un(`/rest/v1/projets?devis_id=eq.${dv}&select=id,nom,client_id`);
  verifier("projet d'ESSAI créé par l'acceptation du devis d'essai", !!PE && PE.nom.startsWith("[ESSAI]"), PE?.nom);
  const saisie = async (jour, h) => (await rpc("rh_enregistrer_temps", { p_auteur: A.id, p_temps_id: null, p_collaborateur_id: FC, p_projet_id: PE.id,
    p_date: J(jour), p_heures: h, p_commentaire: null, p_motif_derogation: "Essai Finance (régularisation)" })).d;
  const t = [await saisie(2, 0.25), await saisie(3, 0.25), await saisie(4, 0.25), await saisie(15, 2.5)];
  const brouillon = await saisie(20, 1);
  await rpc("rh_changer_statut_temps", { p_auteur: A.id, p_temps_ids: t, p_action: "soumettre", p_motif: null });
  await rpc("rh_changer_statut_temps", { p_auteur: A.id, p_temps_ids: t, p_action: "valider", p_motif: null });
  verifier("4 temps validés et 1 brouillon d'essai", (await api("GET", `/rest/v1/temps?projet_id=eq.${PE.id}&statut=eq.valide&select=id`)).d.length === 4);

  console.log("\n== 1. Admin : accueil Finance, mode et tarifs à date d'effet");
  await a.goto(B + "/finance");
  let html = await a.content();
  verifier("émission réelle bloquée (coordonnées et conditions de paiement vides)", html.includes("Émission réelle bloquée"));
  verifier("limites et facturation électronique provisoire affichées", html.includes("Règlement intégral uniquement") && html.includes("information provisoire"));
  await a.goto(`${B}/finance/projets/${PE.id}`);
  await a.locator("select[name=mode_facturation]").selectOption("temps_passe");
  await a.locator("button:has-text('Enregistrer le mode')").click();
  verifier("mode « au temps passé » enregistré", await vu(a, "Mode de facturation enregistré"));
  await a.goto(`${B}/finance/projets/${PE.id}?date_effet=${J(1)}`);
  verifier("temps concernés listés (5)", (await a.locator("[data-temps-concernes] li").count()) === 5);
  await a.fill("input[name=tarif]", "0"); await a.fill("input[name=reference]", "Contrat essai"); await a.check("input[name=confirmation]");
  await a.locator("button:has-text('Confirmer le tarif')").click();
  verifier("tarif nul refusé, saisie conservée", (await vu(a, "strictement positif")) && (await a.inputValue("input[name=reference]")) === "Contrat essai");
  await a.fill("input[name=tarif]", "10,01"); await a.check("input[name=confirmation]");
  await a.locator("button:has-text('Confirmer le tarif')").click();
  verifier("tarif 10,01 € confirmé", await vu(a, "Tarif confirmé"));
  await a.goto(`${B}/finance/projets/${PE.id}?date_effet=${J(11)}`);
  await rpc("rh_enregistrer_temps", { p_auteur: A.id, p_temps_id: brouillon, p_collaborateur_id: FC, p_projet_id: PE.id, p_date: J(20), p_heures: 1.5, p_commentaire: null, p_motif_derogation: "Essai Finance (régularisation)" });
  await a.fill("input[name=tarif]", "90"); await a.fill("input[name=reference]", "Avenant essai"); await a.check("input[name=confirmation]");
  await a.locator("button:has-text('Confirmer le tarif')").click();
  verifier("temps concerné modifié pendant la confirmation : confirmation périmée", await vu(a, "Confirmation périmée"));
  await a.goto(`${B}/finance/projets/${PE.id}?date_effet=${J(11)}`);
  await a.fill("input[name=tarif]", "90"); await a.fill("input[name=reference]", "Avenant essai"); await a.check("input[name=confirmation]");
  await a.locator("button:has-text('Confirmer le tarif')").click();
  verifier("liste actualisée : 90 € au 11", await vu(a, "Tarif confirmé"));
  await a.goto(`${B}/finance/projets/${PE.id}?correction=1`);
  await a.fill("input[name=tarif]", "80"); await a.fill("input[name=motif]", "Erreur de saisie (essai)"); await a.check("input[name=confirmation]");
  await a.locator("button:has-text('Enregistrer la correction')").click();
  verifier("dernier tarif corrigé (80 €), ancienne valeur conservée", (await vu(a, "Dernier tarif corrigé"))
    && (await un(`/rest/v1/projets?id=eq.${PE.id}&select=tarif_historique`)).tarif_historique.length === 3);

  console.log("\n== 2. Admin : aperçu, aperçu périmé, émission unique");
  const url = `${B}/finance/nouvelle?client_id=${PE.client_id}&mois=${MOIS}&projet_id=${PE.id}&${TVA}&apercu=1`;
  await a.goto(url);
  verifier("aperçu : HT 207,50 € ; TTC 225,14 €", (await a.locator("[data-total-ht]").textContent()).includes("207,50") && (await a.locator("[data-total-ttc]").textContent()).includes("225,14"));
  verifier("écart d'arrondi expliqué (-0,01 €)", (await a.locator("[data-ecart]").first().textContent()).includes("écart d'arrondi : -0,01 €"));
  const ap = await a.request.get(`${B}/finance/nouvelle/pdf?client_id=${PE.client_id}&mois=${MOIS}&projet_id=${PE.id}&${TVA}`);
  verifier("aperçu PDF à la volée", ap.status() === 200 && ap.headers()["content-type"] === "application/pdf");
  verifier("aperçu sans écriture : aucune facture, aucun compteur", (await api("GET", "/rest/v1/factures?select=id")).d.length === 0
    && (await api("GET", "/rest/v1/compteurs?select=cle&cle=like.*facture*")).d.length === 0);
  await rpc("rh_changer_statut_temps", { p_auteur: A.id, p_temps_ids: [t[3]], p_action: "rouvrir", p_motif: "Vérification (essai)" });
  await a.locator("button:has-text(\"Émettre la facture d'essai\")").click();
  verifier("aperçu périmé : rien d'émis", (await vu(a, "Aperçu périmé")) && (await api("GET", "/rest/v1/factures?select=id")).d.length === 0);
  await rpc("rh_changer_statut_temps", { p_auteur: A.id, p_temps_ids: [t[3]], p_action: "soumettre", p_motif: null });
  await rpc("rh_changer_statut_temps", { p_auteur: A.id, p_temps_ids: [t[3]], p_action: "valider", p_motif: null });
  const onglet = await a.context().newPage();
  await a.goto(url); await onglet.goto(url);
  await a.locator("button:has-text(\"Émettre la facture d'essai\")").click();
  await a.waitForURL(/\/finance\/factures\//, { timeout: 60000 });
  const fid = a.url().split("/").pop();
  const f = await un(`/rest/v1/factures?id=eq.${fid}&select=numero,essai,total_ttc,pdf_statut,pdf_empreinte`);
  verifier("facture d'ESSAI émise (ESSAI-FAC-AAAA-0001), TTC 225,14 €", f.numero === `ESSAI-FAC-${AUJ.slice(0, 4)}-0001` && f.essai && Number(f.total_ttc) === 225.14, f.numero);
  await onglet.locator("button:has-text(\"Émettre la facture d'essai\")").click();
  verifier("second onglet : refusé, aucune double facturation", (await vu(onglet, "Aucun temps validé et non facturé")) && (await api("GET", "/rest/v1/factures?select=id")).d.length === 1);
  verifier("compteurs : essai seulement (essai_facture = 1), aucun compteur réel", JSON.stringify((await api("GET", "/rest/v1/compteurs?select=cle,valeur&cle=like.*facture*")).d)
    === JSON.stringify([{ cle: `essai_facture_${AUJ.slice(0, 4)}`, valeur: 1 }]));
  verifier("PDF archivé dès l'émission", await attendre(async () => (await un(`/rest/v1/factures?id=eq.${fid}&select=pdf_statut`)).pdf_statut === "disponible"));
  const tel = await a.request.get(`${B}/finance/factures/${fid}/pdf`);
  const pdf = await tel.body();
  verifier("PDF téléchargé = PDF archivé (SHA-256)", tel.status() === 200
    && createHash("sha256").update(pdf).digest("hex") === (await un(`/rest/v1/factures?id=eq.${fid}&select=pdf_empreinte`)).pdf_empreinte);
  verifier("PDF client : aucun nom d'intervenant, références T-01…, filigrane d'essai",
    !pdfContient(pdf, "Jetable-Fin-Collab") && pdfContient(pdf, "T-01") && pdfContient(pdf, "ESSAI — SANS VALEUR"));
  verifier("fiche facture (admin) : détail nominatif conservé", (await a.locator("[data-detail-admin]").textContent()).includes("Jetable-Fin-Collab"));
  html = await a.content();
  verifier("aucun coût interne dans la fiche facture (fiches jetables à 37 €)", !html.includes("37,00") && !html.includes("taux_horaire"));

  console.log("\n== 3. Admin : envoi déclaré, règlement intégral, correction");
  await a.locator("select[name=canal]").selectOption("courrier");
  await a.locator("button:has-text(\"Déclarer l'envoi\")").click();
  verifier("envoi déclaré (aucun email)", await vu(a, "Envoyée (déclarée)", "[data-statut]"));
  verifier("message de confirmation visible après l'envoi", await vu(a, "Envoi déclaré. Aucun email n'a été envoyé", "[data-confirmation]"));
  await a.reload();
  await a.locator("select[name=mode_reglement]").selectOption("virement");
  await a.locator("button:has-text('Enregistrer le règlement intégral')").click();
  verifier("sans confirmer la totalité : paiement partiel refusé", (await vu(a, "Paiement partiel non géré")) && (await un(`/rest/v1/factures?id=eq.${fid}&select=statut`)).statut === "envoyee");
  await a.check("input[name=integral]");
  await a.locator("button:has-text('Enregistrer le règlement intégral')").click();
  verifier("règlement intégral déclaré", await vu(a, "Réglée (déclarée)", "[data-statut]"));
  verifier("message de confirmation visible après le règlement", await vu(a, "Règlement intégral enregistré.", "[data-confirmation]"));
  await a.reload();
  await a.locator("select[name=action_correction]").selectOption("annuler");
  await a.fill("input[name=motif]", "Déclaration erronée (essai)");
  await a.locator("button:has-text('Corriger la déclaration de règlement')").click();
  verifier("message de confirmation visible après la correction", await vu(a, "Déclaration de règlement corrigée", "[data-confirmation]"));
  verifier("déclaration annulée, facture inchangée", (await vu(a, "Envoyée (déclarée)", "[data-statut]"))
    && Number((await un(`/rest/v1/factures?id=eq.${fid}&select=total_ttc`)).total_ttc) === 225.14);

  console.log("\n== 4. Autres rôles et jetons : aucun accès");
  for (const [x, libelle] of [[M, "manager"], [C, "collaboratrice"]]) {
    const p = await connexion(x.email);
    await p.goto(`${B}/finance`);
    verifier(`${libelle} : /finance redirige vers l'accueil`, new URL(p.url()).pathname === "/");
    const r = await p.request.get(`${B}/finance/factures/${fid}/pdf`);
    verifier(`${libelle} : PDF de facture refusé (403)`, r.status() === 403, `HTTP ${r.status()}`);
    await p.goto(`${B}/rh/temps`);
    html = await p.content();
    verifier(`${libelle} : « Mes temps » sans tarif ni montant facturé`, !html.includes("10,01") && !html.includes("80,00"));
    await p.context().close();
  }
  for (const [x, libelle] of [[A, "admin"], [M, "manager"], [C, "collaboratrice"]]) {
    const j = await jetonDe(x.email);
    for (const chemin of ["/rest/v1/projets?select=tarif_vente_ht", "/rest/v1/projets?select=*", "/rest/v1/temps?select=taux_facture", "/rest/v1/factures?select=id"]) {
      const r = await api("GET", chemin, undefined, {}, ANON, j);
      verifier(`${libelle} (jeton) : ${chemin.replace("/rest/v1/", "")} refusé`, r.s === 401 || r.s === 403, `HTTP ${r.s}`);
    }
  }
} catch (e) {
  verifier("parcours interrompu", false, e.message.split("\n")[0]);
} finally {
  console.log("\n== 5. Nettoyage (uniquement ce que ce parcours a créé)");
  const nf = await rpc("supprimer_essais_finance", {});
  if (nf.d?.pdf_chemins?.length) await api("DELETE", "/storage/v1/object/factures", { prefixes: nf.d.pdf_chemins });
  verifier("essais Finance supprimés", nf.s === 200, JSON.stringify(nf.d));
  const nt = await rpc("supprimer_essais_rh", {});
  verifier("temps d'essai supprimés", nt.s === 200, `${nt.d} temps`);
  for (const id of ids.comptes) await api("DELETE", `/auth/v1/admin/users/${id}`);
  for (const id of ids.fiches) { const r = await api("DELETE", `/rest/v1/collaborateurs?id=eq.${id}`); if (r.s >= 400) console.log("    fiche non supprimée :", r.d?.message); }
  const nc = await rpc("supprimer_essais_commercial", {});
  if (nc.d?.pdf_chemins?.length) await api("DELETE", "/storage/v1/object/devis", { prefixes: nc.d.pdf_chemins });
  verifier("essais commerciaux supprimés", nc.s === 200, JSON.stringify(nc.d));
  const restes = {
    comptes: (await api("GET", "/auth/v1/admin/users?per_page=1000")).d.users.filter((u) => u.email.endsWith(DOM)).length,
    fiches: (await api("GET", "/rest/v1/collaborateurs?select=id&email=like.*exemple.invalid")).d.length,
    temps_jetables: (await api("GET", "/rest/v1/temps?select=id&saisi_par=not.is.null")).d.length,
    projets: (await api("GET", "/rest/v1/projets?select=id&nom=like.*ESSAI*")).d.length,
    factures: (await api("GET", "/rest/v1/factures?select=id")).d.length,
    fichiers_factures: (await api("POST", "/storage/v1/object/list/factures", { prefix: "" })).d.length,
    fichiers_devis: (await api("POST", "/storage/v1/object/list/devis", { prefix: "" })).d.length,
    compteurs: (await api("GET", "/rest/v1/compteurs?select=cle")).d.length,
  };
  verifier("aucun reste : comptes, fiches, temps, projets, factures, fichiers, compteurs", Object.values(restes).every((v) => v === 0), JSON.stringify(restes));
  await nav.close();
  console.log(`\nBILAN : ${ok}/${ok + ko} contrôles réussis`);
}
