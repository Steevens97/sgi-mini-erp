// Test navigateur du module Commercial sur l'environnement LOCAL (passerelle + base d'essai).
// Coordonnées « SIMULATION LOCALE — SANS VALEUR ». Jamais exécuté contre Supabase.
// Usage : node tests-reels/simulation/navigateur_commercial.mjs [url] [mode : simulation|reel]
import { chromium } from "playwright";
import { execFileSync } from "node:child_process";
import { createHash } from "node:crypto";
import { inflateSync } from "node:zlib";

const B = process.argv[2] ?? "http://127.0.0.1:3200";
const MODE = process.argv[3] ?? "simulation";
let ok = 0, ko = 0;
const verifier = (libelle, cond, detail = "") => {
  cond ? ok++ : ko++;
  console.log(`  [${cond ? "OK " : "ÉCHEC"}] ${libelle}${detail ? `  (${detail})` : ""}`);
};
const sql = (q) => execFileSync("psql", ["-h", "/var/tmp/pg-essai", "-p", "5499", "-U", "postgres", "-d", "essai", "-qAtX", "-c", q]).toString().trim();
const texteDuPdf = (octets) => {
  const brut = Buffer.from(octets);
  let i = 0, tout = "";
  for (;;) {
    const d = brut.indexOf("stream\n", i); if (d < 0) break;
    const f = brut.indexOf("\nendstream", d);
    try { tout += inflateSync(brut.subarray(d + 7, f)).toString("latin1"); } catch { /* flux non compressé */ }
    i = f + 10;
  }
  return tout.toUpperCase();
};
const contientPdf = (octets, t) => texteDuPdf(octets).includes(Buffer.from(t, "latin1").toString("hex").toUpperCase());

const nav = await chromium.launch({ executablePath: "/opt/pw-browsers/chromium-1194/chrome-linux/chrome" });
async function connexion(email, mdp) {
  const ctx = await nav.newContext();
  const page = await ctx.newPage();
  page.on("dialog", (d) => d.accept());
  await page.goto(B + "/connexion");
  await page.fill("#email", email);
  await page.fill("#mot_de_passe", mdp);
  await page.click("button[type=submit]");
  await page.waitForURL((u) => !u.pathname.startsWith("/connexion"), { timeout: 30000 });
  return page;
}
const attendre = (page, texte) => page.waitForSelector(`text=${texte}`, { timeout: 20000 });

try {
  if (MODE === "reel") {
    console.log("== Mode réel (coordonnées réelles vides) : émission bloquée");
    const m = await connexion("manager@exemple.invalid", "Essai-Manager-2026!");
    await m.goto(B + "/commercial");
    verifier("bandeau « Émission des devis bloquée »", (await m.locator("[role=alert]", { hasText: "Émission des devis bloquée" }).count()) === 1);
    const id = sql("select id from public.devis where statut = 'brouillon' and not essai order by created_at desc limit 1");
    await m.goto(B + `/commercial/devis/${id}`);
    verifier("brouillon : aucun bouton « Émettre »", (await m.locator("text=Émettre (attribue").count()) === 0);
    verifier("brouillon : blocages listés (coordonnées, assurance à confirmer)",
      (await m.locator("text=coordonnées : Raison sociale").count()) === 1 && (await m.locator("text=obligation d'assurance à confirmer").count()) === 1);
    throw new Error("FIN");
  }

  console.log("== Manager : prospect et devis brouillon");
  const m = await connexion("manager@exemple.invalid", "Essai-Manager-2026!");
  await m.goto(B + "/commercial");
  verifier("pas de bandeau de blocage (simulation : coordonnées complètes)", (await m.locator("text=Émission des devis bloquée").count()) === 0);
  await m.click("text=Nouveau prospect");
  await m.fill("[name=nom]", "Mme Navigateur");
  await m.fill("[name=societe]", "[SIMULATION] BTP Navigateur");
  await m.fill("[name=email]", "navigateur@exemple.invalid");
  await m.fill("[name=adresse]", "3 rue du Test");
  await m.fill("[name=code_postal]", "97200");
  await m.fill("[name=ville]", "Fort-de-France");
  await m.click("button:has-text('Créer le prospect')");
  await m.waitForURL(/\/commercial\/prospects\/[0-9a-f-]{36}$/);
  verifier("prospect créé, statut « Contacté »", (await m.locator("text=Statut : Contacté").count()) === 1);
  await m.click("button:has-text('Nouveau devis')");
  await m.waitForURL(/\/commercial\/devis\/[0-9a-f-]{36}$/);
  const devisId = m.url().split("/").pop();
  verifier("devis brouillon créé", (await m.locator("h1", { hasText: "brouillon" }).count()) === 1);
  verifier("émission bloquée tant que la mission n'est pas renseignée", (await m.locator("text=type de mission non renseigné").count()) === 1);

  console.log("== Traitement fiscal et lignes");
  await m.selectOption("[name=type_mission]", "conseil");
  await m.selectOption("[name=nature_mission]", "prestation_intellectuelle");
  await m.selectOption("[name=statut_client]", "assujetti_france");
  await m.fill("[name=lieu_client]", "MQ");
  verifier("proposition affichée (8,5 %, art. 296)", (await m.locator("text=taux normal de 8,5 %").count()) === 1);
  await m.click("text=Reprendre la proposition");
  verifier("proposition reprise dans le formulaire (pas appliquée seule)", (await m.inputValue("[name=taux_tva]")) === "8.5"
    && sql(`select coalesce(regime_tva, 'vide') from public.devis where id = '${devisId}'`) === "vide");
  await m.click("text=Enregistrer le traitement fiscal");
  await attendre(m, "Traitement fiscal enregistré");
  verifier("traitement enregistré en base (taxable MQ 8,5, mission conseil)",
    sql(`select regime_tva || '/' || territoire_tva || '/' || taux_tva || '/' || type_mission from public.devis where id = '${devisId}'`) === "taxable/MQ/8.500/conseil");
  for (const [des, q, pu] of [["Diagnostic structure", "2", "450"], ["Note de calcul", "1", "333,34"]]) {
    await m.fill("input[placeholder='Désignation']", des);
    await m.fill("input[placeholder='Qté']", q);
    await m.fill("input[placeholder='P.U. HT']", pu);
    await m.click("button:has-text('Ajouter la ligne')");
    await attendre(m, "Ligne ajoutée");
    await m.reload();
  }
  verifier("totaux calculés par la base affichés (1 338,17 € TTC)", (await m.locator("text=Total TTC : 1 338,17 €").count()) === 1);

  const apercu = await m.request.get(B + `/commercial/devis/${devisId}/pdf`);
  const apercuPdf = await apercu.body();
  verifier("aperçu PDF du brouillon : filigrane « BROUILLON », sans numéro, rien écrit en base",
    apercu.status() === 200 && contientPdf(apercuPdf, "BROUILLON") && !contientPdf(apercuPdf, "DEV-2026")
    && sql(`select coalesce(numero, 'aucun') || '/' || coalesce(pdf_statut, 'aucun') from public.devis where id = '${devisId}'`) === "aucun/aucun");

  console.log("== Émission");
  await m.click("button:has-text('Émettre')");
  await m.waitForSelector("h1:has-text('Émis')", { timeout: 30000 });
  await attendre(m, "PDF archivé : disponible");
  const numero = sql(`select numero from public.devis where id = '${devisId}'`);
  verifier("numéro attribué à l'émission", /^DEV-\d{4}-\d{4}$/.test(numero), numero);
  await m.reload();
  verifier("lignes figées : plus aucun champ de saisie", (await m.locator("input[placeholder='Désignation']").count()) === 0);
  const telecharge = await m.request.get(B + `/commercial/devis/${devisId}/pdf`);
  const pdf = await telecharge.body();
  const empreinte = createHash("sha256").update(pdf).digest("hex");
  verifier("PDF archivé : numéro imprimé, sans filigrane, empreinte identique à celle enregistrée",
    contientPdf(pdf, `DEVIS ${numero}`) && !contientPdf(pdf, "BROUILLON")
    && empreinte === sql(`select pdf_empreinte from public.devis where id = '${devisId}'`));
  verifier("PDF : pas de ligne d'assurance pour une mission « conseil » (non requise)", !contientPdf(pdf, "Assurance :"));
  const second = await m.request.get(B + `/commercial/devis/${devisId}/pdf`);
  verifier("second téléchargement : même fichier, aucun changement d'état",
    createHash("sha256").update(await second.body()).digest("hex") === empreinte
    && sql(`select statut from public.devis where id = '${devisId}'`) === "emis");

  console.log("== Envoi, acceptation");
  await m.fill("[name=date_envoi]", new Date(Date.now() - 4 * 3600e3 - 60e3).toISOString().slice(0, 16));
  await m.selectOption("[name=canal_envoi]", "email");
  await m.fill("[name=envoi_destinataire]", "navigateur@exemple.invalid");
  await m.click("button:has-text(\"Déclarer l'envoi\")");
  await m.waitForSelector("h1:has-text('Envoyé')", { timeout: 30000 });
  const etatEnvoi = sql(`select statut || '/' || canal_envoi || '/' || (envoi_declare_par is not null) from public.devis where id = '${devisId}'`)
    + " ; prospect " + sql(`select p.statut from public.prospects p join public.devis d on d.prospect_id = p.id where d.id = '${devisId}'`);
  verifier("envoi déclaré (canal, auteur) ; prospect « devis envoyé »", etatEnvoi === "envoye/email/true ; prospect devis_envoye", etatEnvoi);
  await m.reload();
  await m.click("button:has-text('Client : accepté')");
  await m.waitForSelector("h1:has-text('Accepté')", { timeout: 30000 });
  verifier("acceptation : projet de la mission affiché", (await m.locator(`text=Projet ${numero}`).count()) === 1);
  verifier("acceptation : client créé avec l'adresse, prospect « gagné »",
    sql(`select c.nom || '|' || replace(c.adresse, E'\\n', ' ') || '|' || p.statut from public.prospects p join public.clients c on c.id = p.client_id join public.devis d on d.prospect_id = p.id where d.id = '${devisId}'`)
      === "[SIMULATION] BTP Navigateur|3 rue du Test 97200 Fort-de-France MQ|gagne");

  console.log("== Avenant (moins-value)");
  await m.click("button:has-text('Créer un avenant')");
  await m.waitForURL((u) => !u.pathname.endsWith(devisId));
  const avenantId = m.url().split("/").pop();
  const etatAvenant = sql(`select statut || '/' || type_mission || '/' || (avenant_du_devis_id = '${devisId}') from public.devis where id = '${avenantId}'`);
  verifier("avenant créé (brouillon, mission reprise)", etatAvenant === "brouillon/conseil/true", `${etatAvenant} ; adresse ${m.url()}`);
  await m.fill("input[placeholder='Désignation']", "Retrait de la note de calcul");
  await m.fill("input[placeholder='Qté']", "-1");
  await m.fill("input[placeholder='P.U. HT']", "333,34");
  await m.click("button:has-text('Ajouter la ligne')");
  await attendre(m, "Ligne ajoutée");
  await m.reload();
  await m.click("button:has-text('Émettre')");
  await m.waitForSelector("h1:has-text('Émis')", { timeout: 30000 });
  const pdfAvenant = await (await m.request.get(B + `/commercial/devis/${avenantId}/pdf`)).body();
  verifier("PDF de l'avenant : « Moins-value » et référence au devis initial", contientPdf(pdfAvenant, "Moins-value") && contientPdf(pdfAvenant, `au devis ${numero}`));
  await m.reload();
  verifier("avenant visible avec le projet de la mission", (await m.locator(`text=Projet ${numero}`).count()) === 1);

  console.log("== Collaboratrice : consultation seule");
  const c = await connexion("collab@exemple.invalid", "Essai-Collab-2026!");
  await c.goto(B + "/commercial");
  verifier("liste des devis visible (via les vues)", (await c.locator(`text=${numero}`).count()) >= 1);
  verifier("pas de bouton « Nouveau prospect »", (await c.locator("text=Nouveau prospect").count()) === 0);
  await c.goto(B + `/commercial/devis/${devisId}`);
  verifier("fiche du devis : aucune action, aucun lien PDF", (await c.locator("text=Actions").count()) === 0 && (await c.locator("text=PDF").count()) === 0);
  const refus = await c.request.get(B + `/commercial/devis/${devisId}/pdf`);
  verifier("téléchargement direct du PDF refusé (403)", refus.status() === 403, `HTTP ${refus.status()}`);
  await c.goto(B + "/commercial/prospects/nouveau");
  verifier("page « Nouveau prospect » refusée (renvoi)", !c.url().endsWith("/nouveau"), c.url());
} catch (e) {
  if (e.message !== "FIN") { ko++; console.log("  [ÉCHEC] erreur inattendue :", e.message.split("\n")[0]); }
} finally {
  await nav.close();
  console.log(`\nBILAN : ${ok}/${ok + ko} contrôles réussis`);
}
