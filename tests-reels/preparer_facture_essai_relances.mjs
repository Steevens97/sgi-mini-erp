// Préparation EN PRODUCTION de l'UNIQUE facture d'ESSAI du premier essai de relance (accord de l'utilisateur, 25/10/2026).
// Données jetables seulement : prospect/devis/client/projet d'ESSAI, une fiche jetable, un temps validé, compte admin jetable
// (supprimé à la fin). Facture ESSAI-FAC (compteur d'essai), PDF filigrané « ESSAI — SANS VALEUR », délai de paiement 1 jour.
// La facture est émise par la fonction de service de la base (finance_emettre_facture, clé secrète) — l'écran impose
// 30 jours aux essais —, avec les coordonnées et conditions [DÉMO] ; la base applique toutes ses règles. Le PDF est
// généré et archivé par le site (bouton « Générer / reprendre le PDF »).
// AUCUN email, aucune réservation de relance, aucun Cron. Les données créées sont CONSERVÉES VOLONTAIREMENT jusqu'à
// l'essai ; leur liste est écrite dans le fichier d'état passé en 2e argument, lu par nettoyer_essai_relances.mjs.
// Usage : NODE_USE_ENV_PROXY=1 NODE_EXTRA_CA_CERTS=/root/.ccr/ca-bundle.crt node preparer_facture_essai_relances.mjs <url> <etat.json>
import { chromium } from "playwright";
import { createHash, randomUUID } from "node:crypto";
import { writeFileSync } from "node:fs";

const B = process.argv[2] ?? "https://sgi-mini-erp.vercel.app";
const FICHIER_ETAT = process.argv[3];
if (!FICHIER_ETAT) throw new Error("Fichier d'état obligatoire (2e argument)");
const U = process.env.NEXT_PUBLIC_SUPABASE_URL, S = process.env.SUPABASE_SERVICE_ROLE_KEY;
const T = Date.now(), DOM = "@exemple.invalid", MDP = "Prep-Jetable-2026!";
let ok = 0, ko = 0;
const verifier = (l, c, d = "") => { c ? ok++ : ko++; console.log(`  [${c ? "OK " : "ÉCHEC"}] ${l}${d ? `  (${d})` : ""}`); };
async function api(m, p, c) {
  const r = await fetch(U + p, { method: m, headers: { apikey: S, Authorization: `Bearer ${S}`, "Content-Type": "application/json", Prefer: "return=representation" },
    body: c === undefined ? undefined : JSON.stringify(c) });
  const t = await r.text(); let d = null; try { d = t ? JSON.parse(t) : null; } catch { d = t; }
  if (r.status >= 400) throw new Error(`${m} ${p.split("?")[0]} : HTTP ${r.status} ${typeof d === "object" ? d?.message : d}`);
  return d;
}
const rpc = (f, a) => api("POST", `/rest/v1/rpc/${f}`, a);
const un = async (p) => (await api("GET", p))?.[0];
const attendre = async (fn, essais = 60) => { for (let i = 0; i < essais; i++) { if (await fn()) return true; await new Promise((r) => setTimeout(r, 1000)); } return false; };
const AUJ = new Intl.DateTimeFormat("en-CA", { timeZone: "America/Martinique" }).format(new Date());
const [an, mo] = AUJ.split("-").map(Number);
const MOIS = mo === 1 ? `${an - 1}-12` : `${an}-${String(mo - 1).padStart(2, "0")}`;
// Coordonnées et conditions de DÉMONSTRATION (copie de COORDONNEES_DEMO / CONDITIONS_DEMO de src/lib/entreprise.ts),
// délai de paiement ramené à 1 jour pour cet essai.
const EMETTEUR_DEVIS = { raison_sociale: "[DÉMO] SG Ingénierie", forme_juridique: "SAS", capital_social: "[DÉMO]", adresse: "[DÉMO] adresse",
  code_postal: "97200", ville: "Fort-de-France", siret: "00000000000000", immatriculation: "[DÉMO] immatriculation", tva_intracom: "[DÉMO]",
  validite_jours: "30", telephone: "", email: "", conditions_paiement: "", obligation_assurance: "non_requise" };
const EMETTEUR_FACTURE = Object.fromEntries(["raison_sociale", "forme_juridique", "capital_social", "adresse", "code_postal", "ville",
  "siret", "immatriculation", "tva_intracom", "telephone", "email"].map((c) => [c, EMETTEUR_DEVIS[c]]));
const CONDITIONS = { delai_paiement_jours: "1", penalites_retard: "[DÉMO] pénalités de retard",
  indemnite_recouvrement: "[DÉMO] indemnité de recouvrement", escompte: "[DÉMO] escompte" };
const TVA = { regime: "taxable", territoire: "MQ", pays: null, taux: 8.5, mention: null,
  criteres: { nature_mission: "prestation_intellectuelle", statut_client: "assujetti_france" } };

const etat = { cree_le: new Date().toISOString(), conserve_jusqu_a_l_essai: true, comptes: [], fiches: [], prospect: null, devis: null,
  projet: null, client: null, temps: [], facture: null, pdf_devis: null, pdf_facture: null };
const ecrire = () => writeFileSync(FICHIER_ETAT, JSON.stringify(etat, null, 1));
const nav = await chromium.launch({ executablePath: "/opt/pw-browsers/chromium-1194/chrome-linux/chrome",
  ...(process.env.HTTPS_PROXY && !B.startsWith("http://127.0.0.1") ? { proxy: { server: process.env.HTTPS_PROXY } } : {}) });
try {
  console.log("== 0. Contrôles préalables : aucune facture, aucun compteur de facture, aucune relance");
  verifier("aucune facture existante", (await api("GET", "/rest/v1/factures?select=id")).length === 0);
  verifier("aucun compteur de facture", (await api("GET", "/rest/v1/compteurs?select=cle&cle=like.*facture*")).length === 0);
  verifier("aucune relance, aucun événement", (await api("GET", "/rest/v1/relances?select=id")).length === 0
    && (await api("GET", "/rest/v1/relances_evenements?select=evenement_id")).length === 0);
  if (ko) throw new Error("préalables non remplis : rien n'est créé");

  console.log("== 1. Compte admin jetable et fiche jetable");
  const emailA = `jetable-prep-admin-${T}${DOM}`;
  const A = await api("POST", "/auth/v1/admin/users", { email: emailA, password: MDP, email_confirm: true });
  etat.comptes.push(A.id); ecrire();
  await api("PATCH", `/rest/v1/profiles?id=eq.${A.id}`, { role: "admin", nom: "Jetable préparation relances" });
  const FC = (await api("POST", "/rest/v1/collaborateurs?select=id", { nom: "Jetable-Relances-Collab", prenom: "Essai",
    email: `jetable-relances-collab-${T}${DOM}`, poste: "Test", taux_horaire: 37 }))[0].id;
  etat.fiches.push(FC); ecrire();

  console.log("== 2. Devis d'ESSAI accepté → client et projet d'ESSAI");
  etat.prospect = await rpc("creer_prospect_essai", { p_nom: "Essai relances", p_societe: "Essai relances SARL", p_adresse: "1 rue de l'Essai",
    p_code_postal: "97200", p_ville: "Fort-de-France", p_pays: "MQ" }); ecrire();
  // Email du client d'essai : adresse FICTIVE (jamais destinataire : une relance d'essai part vers RELANCES_ADRESSE_ESSAI).
  await api("PATCH", `/rest/v1/prospects?id=eq.${etat.prospect}`, { email: "client-essai-relances@exemple.invalid" });
  etat.devis = (await api("POST", "/rest/v1/devis?select=id", { prospect_id: etat.prospect, type_mission: "conseil", regime_tva: "taxable",
    territoire_tva: "MQ", taux_tva: 8.5, criteres_tva: TVA.criteres }))[0].id; ecrire();
  await api("POST", "/rest/v1/devis_lignes", { devis_id: etat.devis, designation: "Régie (essai relances)", quantite: 1, prix_unitaire: 100 });
  await rpc("emettre_devis", { p_devis_id: etat.devis, p_auteur: A.id, p_emetteur: EMETTEUR_DEVIS, p_gabarit: "devis-v1" });
  const page = await (await nav.newContext({ ignoreHTTPSErrors: true })).newPage();
  page.on("dialog", (d) => d.accept());
  await page.goto(B + "/connexion"); await page.fill("#email", emailA); await page.fill("#mot_de_passe", MDP);
  await page.click("button[type=submit]"); await page.waitForURL((u) => !u.pathname.startsWith("/connexion"), { timeout: 30000 });
  await page.goto(`${B}/commercial/devis/${etat.devis}`); await page.click("button:has-text('Régénérer le PDF')");
  verifier("PDF du devis d'essai archivé", await attendre(async () => (await un(`/rest/v1/devis?id=eq.${etat.devis}&select=pdf_statut`))?.pdf_statut === "disponible"));
  etat.pdf_devis = (await un(`/rest/v1/devis?id=eq.${etat.devis}&select=pdf_chemin`)).pdf_chemin; ecrire();
  await rpc("declarer_envoi_devis", { p_devis_id: etat.devis, p_auteur: A.id, p_date_envoi: new Date().toISOString(), p_canal: "autre", p_destinataire: null });
  await rpc("decider_devis", { p_devis_id: etat.devis, p_auteur: A.id, p_decision: "accepte" });
  const PE = await un(`/rest/v1/projets?devis_id=eq.${etat.devis}&select=id,nom,client_id`);
  etat.projet = PE.id; etat.client = PE.client_id; ecrire();
  const cl = await un(`/rest/v1/clients?id=eq.${PE.client_id}&select=nom,email_contact`);
  verifier("client et projet d'ESSAI créés par l'acceptation", PE.nom.startsWith("[ESSAI]") && cl.nom.startsWith("[ESSAI]")
    && cl.email_contact === "client-essai-relances@exemple.invalid", `${PE.nom} / ${cl.nom}`);

  console.log(`== 3. Un temps validé (1 h, mois ${MOIS}), mode au temps passé, tarif 100 €/h`);
  const tid = await rpc("rh_enregistrer_temps", { p_auteur: A.id, p_temps_id: null, p_collaborateur_id: FC, p_projet_id: PE.id,
    p_date: `${MOIS}-15`, p_heures: 1, p_commentaire: "Essai relances", p_motif_derogation: "Essai relances (régularisation)" });
  etat.temps.push(tid); ecrire();
  await rpc("rh_changer_statut_temps", { p_auteur: A.id, p_temps_ids: [tid], p_action: "soumettre", p_motif: null });
  await rpc("rh_changer_statut_temps", { p_auteur: A.id, p_temps_ids: [tid], p_action: "valider", p_motif: null });
  await rpc("finance_definir_mode", { p_auteur: A.id, p_projet: PE.id, p_mode: "temps_passe" });
  const concernes = await rpc("finance_temps_concernes", { p_projet: PE.id, p_date_effet: `${MOIS}-01` });
  await rpc("finance_confirmer_tarif", { p_auteur: A.id, p_projet: PE.id, p_tarif: 100, p_date_effet: `${MOIS}-01`,
    p_reference: "Essai relances", p_empreinte_temps: concernes.empreinte });

  console.log("== 4. Émission de la facture d'ESSAI (délai de paiement 1 jour) et PDF");
  const calc = await rpc("finance_calculer", { p_client: PE.client_id, p_mois: `${MOIS}-01`, p_projets: [PE.id], p_tva: TVA });
  verifier("aperçu : facture d'ESSAI, 100,00 € HT, 108,50 € TTC", calc.essai === true && Number(calc.totaux?.total_ht) === 100
    && Number(calc.totaux?.total_ttc) === 108.5, JSON.stringify(calc.totaux));
  const em = await rpc("finance_emettre_facture", { p_auteur: A.id, p_cle_emission: randomUUID(), p_client: PE.client_id, p_mois: `${MOIS}-01`,
    p_projets: [PE.id], p_tva: TVA, p_empreinte: calc.empreinte, p_emetteur: EMETTEUR_FACTURE, p_conditions: CONDITIONS, p_gabarit: "facture-v1" });
  etat.facture = em.facture_id; ecrire();
  await page.goto(`${B}/finance/factures/${etat.facture}`);
  await page.click("button:has-text('Générer / reprendre le PDF')");
  verifier("PDF de la facture d'essai archivé par le site", await attendre(async () =>
    (await un(`/rest/v1/factures?id=eq.${etat.facture}&select=pdf_statut`))?.pdf_statut === "disponible"));
  const f = await un(`/rest/v1/factures?id=eq.${etat.facture}&select=numero,essai,statut,date_emission,date_echeance,total_ttc,pdf_chemin,pdf_empreinte`);
  etat.pdf_facture = f.pdf_chemin; etat.numero = f.numero; etat.date_emission = f.date_emission; etat.date_echeance = f.date_echeance; ecrire();
  const tel = await page.request.get(`${B}/finance/factures/${etat.facture}/pdf`);
  const pdf = await tel.body();
  verifier("PDF téléchargé = PDF archivé (SHA-256)", tel.status() === 200 && createHash("sha256").update(pdf).digest("hex") === f.pdf_empreinte);
  verifier("facture d'ESSAI émise, statut « émise »", f.essai && f.statut === "emise" && f.numero.startsWith(`ESSAI-FAC-${AUJ.slice(0, 4)}-`), f.numero);
  const echeanceAttendue = new Date(Date.parse(`${AUJ}T12:00:00Z`) + 86400000).toISOString().slice(0, 10);
  verifier("dates : émission = aujourd'hui (Martinique), échéance = lendemain", f.date_emission === AUJ && f.date_echeance === echeanceAttendue,
    `${f.date_emission} → ${f.date_echeance}`);
  verifier("compteurs : essai seulement, aucun compteur réel", JSON.stringify((await api("GET", "/rest/v1/compteurs?select=cle,valeur&cle=like.*facture*")))
    === JSON.stringify([{ cle: `essai_facture_${AUJ.slice(0, 4)}`, valeur: 1 }]));

  console.log("== 5. Situation de relance (lecture seule) et absence de tout envoi");
  const situ = await rpc("relances_situation", { p_facture: etat.facture });
  verifier("aujourd'hui : aucune relance due (facture pas encore échue)", !situ.rang, JSON.stringify(situ));
  verifier("aucune relance réservée, aucun événement", (await api("GET", "/rest/v1/relances?select=id")).length === 0
    && (await api("GET", "/rest/v1/relances_evenements?select=evenement_id")).length === 0);
  await page.context().close();
} catch (e) {
  verifier(`préparation interrompue : ${e.message.split("\n")[0]}`, false);
} finally {
  await nav.close();
  // Le compte admin jetable ne sert qu'à la préparation : supprimé (les traces gardent son identifiant et son nom recopié).
  for (const id of etat.comptes) await fetch(`${U}/auth/v1/admin/users/${id}`, { method: "DELETE", headers: { apikey: S, Authorization: `Bearer ${S}` } });
  etat.comptes_supprimes = etat.comptes; etat.comptes = [];
  ecrire();
  const restes = (await api("GET", "/auth/v1/admin/users?per_page=1000")).users.filter((u) => u.email.endsWith(DOM)).length;
  verifier("compte admin jetable supprimé (aucun compte @exemple.invalid restant)", restes === 0, `${restes}`);
  console.log(`\nÉtat (données conservées jusqu'à l'essai) : ${FICHIER_ETAT}`);
  console.log(`BILAN : ${ok}/${ok + ko} contrôles réussis`);
}
