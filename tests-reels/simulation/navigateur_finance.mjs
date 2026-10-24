// Test navigateur du module Finance sur l'environnement LOCAL (passerelle + base d'ESSAI), jamais Supabase.
// Prérequis : rejouer.sh comptes_navigateur.sql comptes_navigateur_finance.sql ; pile_locale.sh start ;
// build sur 127.0.0.1:54321 ; next start -p 3200 (SIMULATION_LOCALE=1 : coordonnées « SIMULATION LOCALE »).
// Mode « bloque » (SIMULATION_LOCALE vide) : seule la vérification du blocage de l'émission réelle est faite.
// Lancer depuis scratchpad/essais (Playwright).
import { chromium } from "playwright";
import { execFileSync } from "node:child_process";
import { createHash } from "node:crypto";
import { inflateSync } from "node:zlib";

const B = process.argv[2] ?? "http://127.0.0.1:3200";
const MODE = process.argv[3] ?? "simulation";
let ok = 0, ko = 0;
const verifier = (l, c, d = "") => { c ? ok++ : ko++; console.log(`  [${c ? "OK " : "ÉCHEC"}] ${l}${d ? `  (${d})` : ""}`); };
const sql = (q) => execFileSync("psql", ["-h", "/var/tmp/pg-essai", "-p", "5499", "-U", "postgres", "-d", "essai", "-qAtX", "-c", q]).toString().trim();
const AUJ = new Intl.DateTimeFormat("en-CA", { timeZone: "America/Martinique" }).format(new Date());
const MOIS = sql("select to_char(date_trunc('month', (now() at time zone 'America/Martinique')::date) - interval '1 month', 'YYYY-MM')");
const J = (n) => sql(`select ('${MOIS}-01'::date + ${n - 1})::text`);
const fr = (iso) => iso.split("-").reverse().join("/");
const CLIENT = "33333333-3333-3333-3333-3333333333b1", PRA = "44444444-4444-4444-4444-4444444444b1", PRB = "44444444-4444-4444-4444-4444444444b2";
const PF = "44444444-4444-4444-4444-4444444444b3", ADMIN = "11111111-1111-1111-1111-111111111111";

const nav = await chromium.launch({ executablePath: "/opt/pw-browsers/chromium-1194/chrome-linux/chrome" });
async function connexion(email, mdp) {
  const ctx = await nav.newContext();
  const page = await ctx.newPage();
  page.on("dialog", (d) => d.accept());
  await page.goto(B + "/connexion");
  await page.fill("#email", email); await page.fill("#mot_de_passe", mdp);
  await page.click("button[type=submit]");
  await page.waitForURL((u) => !u.pathname.startsWith("/connexion"), { timeout: 30000 });
  return page;
}
const statut = async (page) => (await page.locator("[role=status]").last().textContent({ timeout: 30000 })) ?? "";
// Attend qu'un message contenant ce texte apparaisse (la réponse du serveur, pas celle de l'action précédente).
const vu = async (page, texte, selecteur = "[role=status]") => {
  try { await page.locator(selecteur, { hasText: texte }).first().waitFor({ timeout: 30000 }); return true; } catch { return false; }
};
const contenu = (page) => page.content();
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

const a = await connexion("sgi@gmx.fr", "Essai-Admin-2026!");
console.log(`== Admin — accueil Finance (mode ${MODE})`);
await a.goto(B + "/finance");
let html = await contenu(a);
verifier("limites de la version affichées", html.includes("Facturation au temps passé uniquement") && html.includes("Règlement intégral uniquement")
  && html.includes("Aucun email ni relance automatique"));
verifier("facturation électronique : documentation présentée comme provisoire", html.includes("information provisoire"));
if (MODE === "bloque") {
  verifier("émission réelle bloquée : coordonnées et conditions de paiement à confirmer",
    html.includes("Émission réelle bloquée") && html.includes("conditions de paiement : Délai de paiement (jours)"));
}

console.log("== Admin — mode et tarifs à date d'effet");
await a.goto(`${B}/finance/projets`);
verifier("projet sans mode ni tarif : « À définir », « Aucun »", (await a.locator(`tr[data-projet="Régie navigateur"]`).textContent()).includes("À définir"));
await a.goto(`${B}/finance/projets/${PRA}`);
await a.locator("select[name=mode_facturation]").selectOption("temps_passe");
await a.locator("button:has-text('Enregistrer le mode')").click();
verifier("mode « au temps passé » enregistré", await vu(a, "Mode de facturation enregistré"));
await a.goto(`${B}/finance/projets/${PRA}`);
await a.fill("input[name=date_effet]", `${MOIS}-01`);
await a.locator("button:has-text('Vérifier les temps concernés')").click();
await a.waitForSelector("[data-temps-concernes]");
verifier("temps concernés listés avant confirmation (5 temps non facturés)", (await a.locator("[data-temps-concernes] li").count()) === 5);
await a.fill("input[name=tarif]", "0");
await a.fill("input[name=reference]", "Contrat navigateur 2026");
await a.check("input[name=confirmation]");
await a.locator("button:has-text('Confirmer le tarif')").click();
verifier("tarif nul refusé (navigateur ou serveur)", await vu(a, "strictement positif"));
verifier("saisie refusée conservée à l'écran (référence)", (await a.inputValue("input[name=reference]")) === "Contrat navigateur 2026");
await a.fill("input[name=tarif]", "10,01");
await a.check("input[name=confirmation]");
await a.locator("button:has-text('Confirmer le tarif')").click();
verifier("tarif 10,01 € confirmé", await vu(a, "Tarif confirmé"));
// 2e période au 11 : un temps concerné change entre l'affichage et la confirmation → refus.
await a.goto(`${B}/finance/projets/${PRA}?date_effet=${J(11)}`);
await a.waitForSelector("[data-temps-concernes]");
const brouillon = sql(`select id from public.temps where projet_id = '${PRA}' and statut = 'brouillon'`);
sql(`select public.rh_enregistrer_temps('${ADMIN}', '${brouillon}', '22222222-2222-2222-2222-222222222221', '${PRA}', '${J(20)}', 1.5, null, 'Correction pendant la confirmation')`);
await a.fill("input[name=tarif]", "90");
await a.fill("input[name=reference]", "Avenant 1");
await a.check("input[name=confirmation]");
await a.locator("button:has-text('Confirmer le tarif')").click();
verifier("temps concerné modifié pendant la confirmation (même nombre) : confirmation périmée", await vu(a, "Confirmation périmée"));
await a.goto(`${B}/finance/projets/${PRA}?date_effet=${J(11)}`);
await a.fill("input[name=tarif]", "90"); await a.fill("input[name=reference]", "Avenant 1"); await a.check("input[name=confirmation]");
await a.locator("button:has-text('Confirmer le tarif')").click();
verifier("liste actualisée : tarif 90 € confirmé au 11", await vu(a, "Tarif confirmé"));
await a.goto(`${B}/finance/projets/${PRA}?correction=1`);
await a.fill("input[name=tarif]", "80"); await a.fill("input[name=motif]", "Erreur de saisie : 80 € au contrat"); await a.check("input[name=confirmation]");
await a.locator("button:has-text('Enregistrer la correction')").click();
verifier("dernier tarif corrigé (80 €)", await vu(a, "Dernier tarif corrigé"));
await a.goto(`${B}/finance/projets/${PRA}`);
html = await contenu(a);
verifier("historique : la période remplacée reste affichée, marquée « Remplacé »", html.includes("Remplacé par une correction") && html.includes("90,00 €"));
for (const [p, tarif, date] of [[PRB, "100", `${MOIS}-01`], [PRB, "120", sql(`select ('${AUJ}'::date + 30)::text`)]]) {
  await a.goto(`${B}/finance/projets/${p}?date_effet=${date}`);
  if (tarif === "100") {
    await a.goto(`${B}/finance/projets/${p}`);
    await a.locator("select[name=mode_facturation]").selectOption("temps_passe");
    await a.locator("button:has-text('Enregistrer le mode')").click();
    await vu(a, "Mode de facturation enregistré");
    await a.goto(`${B}/finance/projets/${p}?date_effet=${date}`);
  }
  await a.fill("input[name=tarif]", tarif); await a.fill("input[name=reference]", `Contrat ${tarif}`); await a.check("input[name=confirmation]");
  await a.locator("button:has-text('Confirmer le tarif')").click();
  await vu(a, "Tarif confirmé");
}
await a.goto(`${B}/finance/projets/${PRB}`);
verifier("tarif futur : « Dernier tarif confirmé » 120 € à compter de J+30, « pas encore applicable »",
  (await a.locator("[data-dernier-tarif]").textContent()).includes("120,00 €") && (await a.locator("[data-dernier-tarif]").textContent()).includes("pas encore applicable"));
verifier("applicable aujourd'hui : 100 €", (await a.locator("[data-tarif-applicable]").textContent()).includes("100,00 €"));
await a.goto(`${B}/finance/projets/${PF}`);
await a.locator("select[name=mode_facturation]").selectOption("forfait");
await a.locator("button:has-text('Enregistrer le mode')").click();
await vu(a, "Mode de facturation enregistré");

console.log("== Admin — aperçu (aucune écriture)");
const tva = "regime_tva=taxable&territoire_tva=MQ&taux_tva=8.5&nature_mission=prestation_intellectuelle&statut_client=assujetti_france";
const urlApercu = (projets) => `${B}/finance/nouvelle?client_id=${CLIENT}&mois=${MOIS}&${projets.map((x) => `projet_id=${x}`).join("&")}&${tva}&apercu=1`;
const compteurs = () => sql("select count(*) from public.compteurs where cle like '%facture%'");
await a.goto(urlApercu([PRA, PRB, PF]));
verifier("projet au forfait sélectionné : aperçu bloqué avec le motif", await vu(a, "mode de facturation « forfait »", "[role=alert]"));
await a.goto(urlApercu([PRA, PRB]));
verifier("totaux de l'aperçu : HT 307,50 € (7,50 + 200,00 + 100,00), TTC 333,64 €",
  (await a.locator("[data-total-ht]").textContent()).includes("307,50") && (await a.locator("[data-total-ttc]").textContent()).includes("333,64"));
verifier("écart d'arrondi expliqué (somme des temps 7,50 € ; théorique 7,51 € ; écart -0,01 €)",
  (await a.locator("[data-ecart]").first().textContent()).includes("écart d'arrondi : -0,01 €"));
const reponsePdf = await a.request.get(`${B}/finance/nouvelle/pdf?client_id=${CLIENT}&mois=${MOIS}&projet_id=${PRA}&projet_id=${PRB}&${tva}`);
verifier("aperçu PDF généré à la volée (non stocké)", reponsePdf.status() === 200 && reponsePdf.headers()["content-type"] === "application/pdf");
verifier("aperçu sans écriture : aucune facture, aucun compteur", sql("select count(*) from public.factures") === "0" && compteurs() === "0");
if (MODE === "bloque") {
  verifier("émission réelle : bouton désactivé, motif affiché", await a.locator("button:has-text('Émettre la facture')").isDisabled());
  await nav.close();
  console.log(`\nBILAN : ${ok}/${ok + ko} contrôles réussis`);
  process.exit(ko ? 1 : 0);
}

console.log("== Admin — émission");
// Aperçu périmé : un temps rouvert après l'affichage.
const t5 = sql(`select id from public.temps where projet_id = '${PRB}'`);
sql(`select public.rh_changer_statut_temps('${ADMIN}', array['${t5}']::uuid[], 'rouvrir', 'Vérification pendant l''aperçu')`);
await a.locator("button:has-text('Émettre la facture')").click();
verifier("aperçu périmé : émission refusée, rien d'émis", (await vu(a, "Aperçu périmé")) && sql("select count(*) from public.factures") === "0");
sql(`select public.rh_changer_statut_temps('${ADMIN}', array['${t5}']::uuid[], 'soumettre', null), public.rh_changer_statut_temps('${ADMIN}', array['${t5}']::uuid[], 'valider', null)`);
const onglet2 = await a.context().newPage();
await a.goto(urlApercu([PRA, PRB]));
await onglet2.goto(urlApercu([PRA, PRB]));
await a.locator("button:has-text('Émettre la facture')").click();
await a.waitForURL(/\/finance\/factures\//, { timeout: 30000 });
const fid = a.url().split("/").pop();
const numero = sql(`select numero from public.factures where id = '${fid}'`);
verifier("facture émise : numéro FAC-AAAA-0001, fiche affichée", numero === `FAC-${AUJ.slice(0, 4)}-0001` && (await a.locator("[data-numero]").textContent()).includes(numero), numero);
verifier("montants de la facture = aperçu (TTC 333,64 €)", (await a.locator("[data-total-ttc]").textContent()).includes("333,64"));
await onglet2.locator("button:has-text('Émettre la facture')").click();
verifier("même sélection depuis un second onglet : refusée, aucune double facturation",
  (await vu(onglet2, "Aucun temps validé et non facturé")) && sql("select count(*) from public.factures") === "1");
verifier("un seul numéro consommé", sql("select valeur from public.compteurs where cle like 'facture_%'") === "1");
verifier("PDF archivé dès l'émission", sql(`select pdf_statut from public.factures where id = '${fid}'`) === "disponible");
const telecharge = await a.request.get(`${B}/finance/factures/${fid}/pdf`);
const corps = await telecharge.body();
verifier("PDF téléchargé = PDF archivé (SHA-256)", telecharge.status() === 200
  && createHash("sha256").update(corps).digest("hex") === sql(`select pdf_empreinte from public.factures where id = '${fid}'`));
verifier("PDF client téléchargé : aucun nom d'intervenant (« Lea », « Moreau »)", !pdfContient(corps, "Moreau") && !pdfContient(corps, "Lea ")
  && pdfContient(corps, "T-01"));
html = await contenu(a);
verifier("aucun coût interne dans la page (fiche admin à 37 €)", !html.includes("37,00") && !html.includes("taux_horaire"));
verifier("fiche facture (admin) : détail nominatif conservé, annoncé « non imprimé sur le PDF client »",
  (await a.locator("[data-detail-admin]").textContent()).includes("Lea Moreau") && html.includes("non imprimé sur le PDF client"));

console.log("== Admin — envoi déclaré, règlement intégral, correction");
await a.locator("select[name=canal]").selectOption("courrier");
await a.fill("input[name=destinataire]", "Service comptable");
await a.locator("button:has-text(\"Déclarer l'envoi\")").click();
// La section « Envoi » est remplacée par « Règlement » : on vérifie le nouveau statut affiché.
verifier("envoi déclaré (aucun email envoyé) : statut « Envoyée (déclarée) »", await vu(a, "Envoyée (déclarée)", "[data-statut]"));
verifier("message de confirmation visible après l'envoi", await vu(a, "Envoi déclaré. Aucun email n'a été envoyé", "[data-confirmation]"));
await a.reload();
verifier("mention « paiements partiels non gérés » affichée", (await a.locator("[role=note]").textContent()).includes("paiements partiels ne sont pas gérés"));
await a.locator("select[name=mode_reglement]").selectOption("virement");
await a.fill("input[name=reference_reglement]", "VIR-NAV-1");
await a.locator("button:has-text('Enregistrer le règlement intégral')").click();
verifier("sans confirmer la totalité reçue : refusé, aucun règlement", (await vu(a, "Paiement partiel non géré"))
  && sql(`select statut from public.factures where id = '${fid}'`) === "envoyee");
verifier("saisie refusée conservée (référence)", (await a.inputValue("input[name=reference_reglement]")) === "VIR-NAV-1");
await a.check("input[name=integral]");
await a.locator("button:has-text('Enregistrer le règlement intégral')").click();
verifier("règlement intégral enregistré : statut « Réglée (déclarée) »", await vu(a, "Réglée (déclarée)", "[data-statut]"));
verifier("message de confirmation visible après le règlement", await vu(a, "Règlement intégral enregistré.", "[data-confirmation]"));
await a.reload();
await a.locator("select[name=action_correction]").selectOption("annuler");
await a.fill("input[name=motif]", "Virement non reçu : déclaration erronée");
await a.locator("button:has-text('Corriger la déclaration de règlement')").click();
verifier("message de confirmation visible après la correction", await vu(a, "Déclaration de règlement corrigée", "[data-confirmation]"));
verifier("déclaration de règlement annulée (admin, motif), facture inchangée", (await vu(a, "Envoyée (déclarée)", "[data-statut]"))
  && sql(`select statut || '/' || total_ttc from public.factures where id = '${fid}'`) === "envoyee/333.64");
await a.reload();
verifier("historique : émission, PDF, envoi, règlement, annulation", (await a.locator("[data-historique] li").count()) === 5);

console.log("== Admin — facture d'essai, PDF à reprendre");
const ce = sql("select client_id from public.projets where devis_id = '55555555-5555-5555-5555-5555555555b1'");
const pe = sql("select id from public.projets where devis_id = '55555555-5555-5555-5555-5555555555b1'");
const empreinte = sql(`select public.finance_calculer('${ce}', '${MOIS}-01', array['${pe}']::uuid[], '{"regime":"taxable","territoire":"MQ","taux":8.5,"criteres":{"nature_mission":"prestation_intellectuelle","statut_client":"assujetti_france"}}') ->> 'empreinte'`);
// Émise directement par la fonction (comme après une coupure entre l'émission et l'archivage) : PDF à générer.
const fe = sql(`select public.finance_emettre_facture('${ADMIN}', gen_random_uuid(), '${ce}', '${MOIS}-01', array['${pe}']::uuid[], '{"regime":"taxable","territoire":"MQ","taux":8.5,"criteres":{"nature_mission":"prestation_intellectuelle","statut_client":"assujetti_france"}}', '${empreinte}', '{"raison_sociale":"[DÉMO] SG Ingénierie","forme_juridique":"SAS","capital_social":"[DÉMO]","adresse":"[DÉMO] adresse","code_postal":"97200","ville":"Fort-de-France","siret":"00000000000000","immatriculation":"[DÉMO]","tva_intracom":"[DÉMO]"}', '{"delai_paiement_jours":"30","penalites_retard":"[DÉMO] p","indemnite_recouvrement":"[DÉMO] i","escompte":"[DÉMO] e"}', 'facture-v1') ->> 'facture_id'`);
await a.goto(`${B}/finance/factures/${fe}`);
verifier("facture d'essai : ESSAI-FAC, marquée ESSAI", (await a.locator("[data-numero]").textContent()).includes("ESSAI-FAC-"));
verifier("PDF non archivé : envoi impossible (bouton désactivé)", await a.locator("button:has-text(\"Déclarer l'envoi\")").isDisabled());
await a.locator("button:has-text('Générer / reprendre le PDF')").click();
verifier("message de confirmation visible après la reprise du PDF", await vu(a, "PDF archivé et disponible.", "[data-confirmation]"));
verifier("reprise du PDF : archivé avec le même numéro", (await vu(a, "Télécharger le PDF archivé", "[data-telecharger]")) && sql(`select pdf_statut from public.factures where id = '${fe}'`) === "disponible");

console.log("== Autres rôles : aucun accès");
for (const [email, mdp, libelle] of [["manager@exemple.invalid", "Essai-Manager-2026!", "manager"], ["collab@exemple.invalid", "Essai-Collab-2026!", "collaboratrice"]]) {
  const p = await connexion(email, mdp);
  verifier(`${libelle} : pas d'entrée « Finance » dans le menu`, !(await p.locator("nav a[href='/finance']").count()));
  await p.goto(`${B}/finance`);
  verifier(`${libelle} : /finance redirige vers l'accueil`, new URL(p.url()).pathname === "/");
  for (const chemin of [`/finance/factures/${fid}/pdf`, `/finance/nouvelle/pdf?client_id=${CLIENT}&mois=${MOIS}&projet_id=${PRA}&${tva}`]) {
    const r = await p.request.get(B + chemin);
    verifier(`${libelle} : ${chemin.split("?")[0].replace(fid, "<id>")} refusé (403)`, r.status() === 403, `HTTP ${r.status()}`);
  }
  await p.goto(`${B}/rh/temps`);
  html = await contenu(p);
  verifier(`${libelle} : écran « Mes temps » sans tarif ni montant facturé`, !html.includes("10,01") && !html.includes("80,00") && !html.includes("taux_facture")
    && !html.includes("montant_facture"));
  await p.context().close();
}

console.log("== Nettoyage des essais (clé secrète)");
const net = JSON.parse(sql("select public.supprimer_essais_finance()"));
sql("select public.supprimer_essais_rh(), public.supprimer_essais_commercial()");
verifier("facture d'essai et compteur d'essai supprimés ; facture réelle locale conservée",
  net.factures === 1 && sql("select count(*) from public.factures where essai") === "0" && sql("select count(*) from public.factures") === "1");
await nav.close();
console.log(`\nBILAN : ${ok}/${ok + ko} contrôles réussis`);
