// Test navigateur du module RH sur l'environnement LOCAL (passerelle + base d'ESSAI), rôle par rôle.
// Prérequis : rejouer.sh comptes_navigateur.sql comptes_navigateur_rh.sql ; pile_locale.sh start ;
// build sur 127.0.0.1:54321 ; next start -p 3200. Lancer depuis scratchpad/essais (Playwright).
import { chromium } from "playwright";
import { execFileSync } from "node:child_process";

const B = process.argv[2] ?? "http://127.0.0.1:3200";
let ok = 0, ko = 0;
const verifier = (l, c, d = "") => { c ? ok++ : ko++; console.log(`  [${c ? "OK " : "ÉCHEC"}] ${l}${d ? `  (${d})` : ""}`); };
const sql = (q) => execFileSync("psql", ["-h", "/var/tmp/pg-essai", "-p", "5499", "-U", "postgres", "-d", "essai", "-qAtX", "-c", q]).toString().trim();
const attendre = async (q, attendu, essais = 40) => {
  for (let i = 0; i < essais; i++) { if (sql(q) === attendu) return true; await new Promise((r) => setTimeout(r, 250)); }
  return false;
};
const AUJ = new Intl.DateTimeFormat("en-CA", { timeZone: "America/Martinique" }).format(new Date());
const LEA = "22222222-2222-2222-2222-222222222221", BRUNO = "22222222-2222-2222-2222-222222222222", CHLOE = "22222222-2222-2222-2222-222222222223";
const PROJET1 = sql("select id from public.projets where nom = 'Projet démo 1'");

const nav = await chromium.launch({ executablePath: "/opt/pw-browsers/chromium-1194/chrome-linux/chrome" });
async function connexion(email, mdp) {
  const page = await (await nav.newContext()).newPage();
  page.on("dialog", (d) => d.accept());
  await page.goto(B + "/connexion");
  await page.fill("#email", email); await page.fill("#mot_de_passe", mdp);
  await page.click("button[type=submit]");
  await page.waitForURL((u) => !u.pathname.startsWith("/connexion"), { timeout: 30000 });
  return page;
}
// Remplit le formulaire de temps (le contrôle du navigateur peut être contourné pour tester le serveur).
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
const statut = (page) => page.locator("[role=status]").last().textContent({ timeout: 20000 });

try {
  // ==================== ADMIN ====================
  console.log("== Admin (sans fiche personnelle)");
  const a = await connexion("sgi@gmx.fr", "Essai-Admin-2026!");
  await a.goto(B + "/rh");
  verifier("accueil RH : Mes temps, Validation, Projets, Collaborateurs", (await a.locator("main a").allTextContents()).join("|").match(/Mes temps.*Validation.*Projets.*Collaborateurs/s) !== null);
  await a.goto(B + "/rh/collaborateurs");
  verifier("liste des fiches : aucun taux affiché", !(await a.textContent("main")).match(/\b(120|95|75|110)([,.]00)?\b/));
  const fNouvelle = a.locator("form", { has: a.locator("button:has-text('Créer la fiche')") });
  verifier("nouvelle fiche : taux vide et obligatoire", (await fNouvelle.locator("[name=taux_horaire]").inputValue()) === "" && (await fNouvelle.locator("[name=taux_horaire]").getAttribute("required")) !== null);
  await fNouvelle.locator("[name=nom]").fill("Jetable-RH"); await fNouvelle.locator("[name=prenom]").fill("Test");
  await fNouvelle.locator("[name=email]").fill("jetable-rh@exemple.invalid");
  await fNouvelle.locator("[name=manager_id]").selectOption(BRUNO);
  await fNouvelle.locator("[name=taux_horaire]").evaluate((e) => e.removeAttribute("required"));
  await fNouvelle.locator("button:has-text('Créer la fiche')").click();
  verifier("taux vide (contrôle du navigateur contourné) : message clair, rien créé",
    (await statut(a)).includes("taux horaire est obligatoire") && sql("select count(*) from public.collaborateurs where nom = 'Jetable-RH'") === "0");
  verifier("saisie refusée conservée : nom, prénom, email et manager toujours remplis (rien à retaper)",
    (await fNouvelle.locator("[name=nom]").inputValue()) === "Jetable-RH" && (await fNouvelle.locator("[name=manager_id]").inputValue()) === BRUNO
    && (await fNouvelle.locator("[name=email]").inputValue()) === "jetable-rh@exemple.invalid");
  await fNouvelle.locator("[name=taux_horaire]").fill("70");
  await fNouvelle.locator("button:has-text('Créer la fiche')").click();
  verifier("fiche jetable créée avec son manager et son taux", await attendre("select manager_id || '/' || taux_horaire from public.collaborateurs where nom = 'Jetable-RH'", `${BRUNO}/70.00`));
  const JETABLE = sql("select id from public.collaborateurs where nom = 'Jetable-RH'");
  await a.goto(B + `/rh/collaborateurs/${BRUNO}`);
  const optionsBruno = await a.locator("[name=manager_id] option").evaluateAll((o) => o.map((x) => x.value));
  verifier("modifier Dubois : manager proposé ≠ lui-même ni son équipe (boucle impossible à choisir)",
    !optionsBruno.includes(BRUNO) && !optionsBruno.includes(LEA) && !optionsBruno.includes(CHLOE) && !optionsBruno.includes(JETABLE), optionsBruno.length + " option(s)");
  verifier("écran d'édition admin : taux relu côté serveur (120)", (await a.locator("[name=taux_horaire]").inputValue()) === "120");
  await a.locator("[name=manager_id]").evaluate((s) => { const o = document.createElement("option"); o.value = s.form.fiche_id.value; o.text = "soi"; s.add(o); s.value = o.value; });
  await a.locator("button:has-text('Enregistrer la fiche')").click();
  verifier("se choisir soi-même comme manager (requête forcée) : refusé avec un message",
    (await statut(a)).includes("propre manager") && sql(`select manager_id is null from public.collaborateurs where id = '${BRUNO}'`) === "t");
  await a.goto(B + "/rh/projets");
  const fp = a.locator("form", { has: a.locator("button:has-text('Créer le projet')") });
  await fp.locator("[name=nom]").fill("Mission interne jetable");
  await fp.locator("button:has-text('Créer le projet')").click();
  verifier("projet sans devis ni client créé par l'admin", await attendre("select count(*) from public.projets where nom = 'Mission interne jetable' and devis_id is null and client_id is null", "1"));
  const INTERNE = sql("select id from public.projets where nom = 'Mission interne jetable'");
  // Saisie pour Léa (brouillon que Léa pourra reprendre).
  await a.goto(B + `/rh/temps?pour=${LEA}`);
  verifier("admin : « Saisir pour » propose toutes les fiches", (await a.locator("[name=pour] option").count()) >= 4);
  await saisir(a, { projet: PROJET1, date: AUJ, heures: 0, contourner: true });
  verifier("0 heure (navigateur contourné) : refusé « zéro heure est refusé », rien enregistré",
    (await statut(a)).includes("zéro heure") && sql(`select count(*) from public.temps where collaborateur_id = '${LEA}' and date_saisie = '${AUJ}'`) === "0");
  await saisir(a, { projet: PROJET1, date: AUJ, heures: "2", commentaire: "saisi par l'admin" });
  verifier("admin saisit 2 h pour Léa (brouillon)", await attendre(`select count(*) from public.temps where collaborateur_id = '${LEA}' and date_saisie = '${AUJ}' and statut = 'brouillon'`, "1"));
  const T_ADMIN = sql(`select id from public.temps where collaborateur_id = '${LEA}' and commentaire = 'saisi par l''admin'`);
  verifier("auteur de la saisie (admin) distinct du propriétaire (Léa)",
    sql(`select saisi_par_nom || '|' || collaborateur_id from public.temps where id = '${T_ADMIN}'`) === `Admin d'essai|${LEA}`);

  // ==================== COLLABORATRICE (Léa) ====================
  console.log("== Collaboratrice (Léa, équipe de Dubois)");
  const l = await connexion("collab@exemple.invalid", "Essai-Collab-2026!");
  await l.goto(B + "/rh");
  verifier("accueil RH : pas d'entrée Validation", !(await l.textContent("main")).includes("Validation"));
  await l.goto(B + "/rh/temps");
  const ligneAdmin = l.locator(`tr[data-temps="${T_ADMIN}"]`);
  verifier("le brouillon saisi par l'admin apparaît chez Léa, « Saisi par Admin d'essai — pour vous »",
    (await ligneAdmin.textContent()).includes("Admin d'essai") && (await ligneAdmin.textContent()).includes("pour vous"));
  verifier("liste des collaborateurs : uniquement sa propre fiche (choix verrouillé)", (await l.locator("select[aria-label=Collaborateur] option").count()) === 1 && (await l.locator("input[type=hidden][name=collaborateur_id]").first().inputValue()) === LEA);
  const projetsLea = await l.locator("[name=projet_id] option").evaluateAll((o) => o.map((x) => x.value).filter(Boolean));
  verifier("projets proposés = projets ouverts uniquement", projetsLea.length === Number(sql("select count(*) from public.projets where statut = 'en_cours'")));
  await ligneAdmin.locator("a:has-text('Corriger')").click();
  await l.waitForURL(/corriger=/);
  await saisir(l, { heures: "3", commentaire: "repris par Léa" });
  verifier("Léa reprend le brouillon de l'admin : 3 h, auteur d'origine conservé, correction tracée à son nom",
    await attendre(`select heures || '|' || saisi_par_nom || '|' || (historique -> -1 ->> 'action') || '|' || (historique -> -1 ->> 'auteur_nom') from public.temps where id = '${T_ADMIN}'`,
      "3.00|Admin d'essai|correction|Collaboratrice d'essai"));
  await l.goto(B + "/rh/temps");
  await saisir(l, { projet: PROJET1, date: AUJ, heures: "8" });
  verifier("Léa ajoute 8 h (cumul 11 h)", await attendre(`select sum(heures) from public.temps where collaborateur_id = '${LEA}' and date_saisie = '${AUJ}'`, "11.00"));
  await l.goto(B + "/rh/temps");
  const fl = l.locator("form", { has: l.locator("button:has-text('Enregistrer')") }).first();
  await fl.locator("[name=projet_id]").selectOption(PROJET1);
  await fl.locator("[name=heures]").fill("2");
  verifier("alerte AVANT l'envoi : 13 h, réservé à l'administrateur avec motif",
    (await l.locator("[role=alert]", { hasText: "Alerte : 13 h" }).count()) === 1);
  await fl.locator("button:has-text('Enregistrer')").click();
  verifier("serveur : refus au-delà de 12 h pour un collaborateur", (await statut(l)).includes("12 h") &&
    sql(`select sum(heures) from public.temps where collaborateur_id = '${LEA}' and date_saisie = '${AUJ}'`) === "11.00");
  // Changement de date vers une journée déjà chargée : plafond recalculé.
  const VEILLE = sql(`select (date '${AUJ}' - 1)::text`);
  await l.goto(B + "/rh/temps");
  await saisir(l, { projet: PROJET1, date: VEILLE, heures: "10" });
  await attendre(`select count(*) from public.temps where collaborateur_id = '${LEA}' and date_saisie = '${VEILLE}'`, "1");
  const T_8 = sql(`select id from public.temps where collaborateur_id = '${LEA}' and date_saisie = '${AUJ}' and heures = 8`);
  await l.goto(B + `/rh/temps?corriger=${T_8}`);
  await saisir(l, { date: VEILLE });
  verifier("déplacer 8 h vers une journée qui a déjà 10 h : refusé (18 h > 12 h)", (await statut(l)).includes("12 h") &&
    sql(`select date_saisie from public.temps where id = '${T_8}'`) === AUJ);
  await l.goto(B + "/rh/temps");
  await l.locator(`tr[data-temps="${T_ADMIN}"] button:has-text('Soumettre')`).click();
  verifier("Léa soumet le temps repris", await attendre(`select statut from public.temps where id = '${T_ADMIN}'`, "soumis"));
  await l.goto(B + "/rh/validation");
  verifier("Validation inaccessible au collaborateur (renvoyé vers RH)", new URL(l.url()).pathname === "/rh");
  await l.goto(B + "/rh/collaborateurs");
  verifier("Collaborateurs : uniquement sa fiche, sans taux", (await l.locator("main tbody tr").count()) === 1 && !(await l.textContent("main")).includes("95"));
  const r404 = await l.goto(B + `/rh/collaborateurs/${BRUNO}`);
  verifier("fiche d'un autre : introuvable pour un collaborateur", r404.status() === 404);
  await l.goto(B + "/rh/projets");
  verifier("Projets : ouverts seulement, nom du client sans coordonnées", (await l.textContent("main")).includes("Projet démo 1") && !(await l.textContent("main")).includes("@"));

  // ==================== MANAGER (Dubois) ====================
  console.log("== Manager (Dubois)");
  const m = await connexion("manager@exemple.invalid", "Essai-Manager-2026!");
  await m.goto(B + "/rh/validation");
  verifier("Validation : le temps soumis de Léa est proposé", (await m.locator(`tr[data-temps="${T_ADMIN}"]`).count()) === 1);
  await m.locator(`tr[data-temps="${T_ADMIN}"] button:has-text('Valider')`).click();
  verifier("le manager valide le temps de son équipe (valideur enregistré)", await attendre(`select statut || '|' || valide_par_nom from public.temps where id = '${T_ADMIN}'`, "valide|Manager d'essai"));
  await m.goto(B + "/rh/projets");
  const ligneInterne = m.locator('tr[data-projet="Mission interne jetable"]');
  verifier("projets (manager) : seul le statut est modifiable (aucun champ nom ni client)",
    (await ligneInterne.locator("[name=nom]").count()) === 0 && (await ligneInterne.locator("[name=client_id]").count()) === 0 && (await ligneInterne.locator("[name=statut]").count()) === 1);
  await ligneInterne.locator("[name=statut]").selectOption("termine");
  await ligneInterne.locator("button:has-text('Enregistrer')").click();
  verifier("le manager passe le projet en « terminé »", await attendre(`select statut from public.projets where id = '${INTERNE}'`, "termine"));
  await ligneInterne.locator("form").evaluate((f) => { const i = document.createElement("input"); i.name = "nom"; i.value = "Renommé par le manager"; f.appendChild(i); });
  await ligneInterne.locator("[name=statut]").selectOption("en_cours");
  await ligneInterne.locator("button:has-text('Enregistrer')").click();
  verifier("requête forcée avec un nom : le statut change, le nom NON", await attendre(`select statut || '|' || nom from public.projets where id = '${INTERNE}'`, "en_cours|Mission interne jetable"));
  await m.goto(B + "/rh/temps");
  await saisir(m, { projet: PROJET1, date: AUJ, heures: "3", commentaire: "temps du manager" });
  await attendre(`select count(*) from public.temps where collaborateur_id = '${BRUNO}'`, "1");
  const T_M = sql(`select id from public.temps where collaborateur_id = '${BRUNO}'`);
  await m.goto(B + "/rh/temps");
  await m.locator(`tr[data-temps="${T_M}"] button:has-text('Soumettre')`).click();
  await attendre(`select statut from public.temps where id = '${T_M}'`, "soumis");
  await m.goto(B + "/rh/validation");
  verifier("le manager ne voit pas ses propres temps à valider (note explicative)",
    (await m.locator(`tr[data-temps="${T_M}"]`).count()) === 0 && (await m.textContent("main")).includes("Vos propres temps soumis"));

  for (const chemin of ["/rh/collaborateurs", `/rh/collaborateurs/${LEA}`, "/rh/temps", "/rh/validation", "/rh/projets"]) {
    await m.goto(B + chemin);
    verifier(`manager ${chemin} : aucun taux dans la page reçue (texte et données cachées)`, !(await m.content()).includes("taux_horaire"));
  }
  for (const chemin of ["/rh/collaborateurs", `/rh/collaborateurs/${LEA}`, "/rh/temps", "/rh/projets"]) {
    await l.goto(B + chemin);
    verifier(`collaboratrice ${chemin} : aucun taux dans la page reçue`, !(await l.content()).includes("taux_horaire"));
  }
  await a.goto(B + `/rh/collaborateurs/${LEA}`);
  const brut = await a.content();
  verifier("écran d'édition admin : seul le taux de la fiche éditée est transmis",
    (brut.match(/taux_horaire/g) ?? []).length >= 1 && !brut.includes('"taux_horaire":120') && !brut.includes('"taux_horaire":75'));

  // ==================== MANAGER HORS ÉQUIPE (Hugo) ====================
  console.log("== Manager hors équipe (Hugo)");
  const h = await connexion("hugo@exemple.invalid", "Essai-Hugo-2026!");
  sql(`select 1`);
  const T_CHLOE = sql(`select id from public.temps where collaborateur_id = '${CHLOE}' and statut = 'soumis' limit 1`);
  await h.goto(B + "/rh/validation");
  verifier("aucun temps de l'équipe de Dubois proposé à Hugo", (await h.locator(`tr[data-temps="${T_CHLOE}"], tr[data-temps="${T_M}"]`).count()) === 0);

  // ==================== ADMIN : validation et réouverture ====================
  console.log("== Admin : validation des temps du manager, réouverture tracée");
  await a.goto(B + "/rh/validation");
  await a.locator(`tr[data-temps="${T_M}"] button:has-text('Valider')`).click();
  verifier("l'admin valide les temps du manager", await attendre(`select statut from public.temps where id = '${T_M}'`, "valide"));
  await a.goto(B + "/rh/validation");
  const ligneValidee = a.locator(`tr[data-temps="${T_ADMIN}"]`).last();
  await ligneValidee.locator("[name=motif]").fill("Erreur de projet signalée");
  await ligneValidee.locator("button:has-text('Rouvrir')").click();
  verifier("réouverture : brouillon, motif et validation précédente (Manager d'essai) conservés",
    await attendre(`select statut || '|' || (historique -> -1 ->> 'motif') || '|' || (historique -> -1 -> 'validation_precedente' ->> 'valide_par_nom') from public.temps where id = '${T_ADMIN}'`,
      "brouillon|Erreur de projet signalée|Manager d'essai"));
  await l.goto(B + "/rh/temps");
  await l.locator(`tr[data-temps="${T_ADMIN}"] summary`).click();
  verifier("Léa voit l'historique complet (saisie admin, correction, validation, réouverture)",
    /Saisie.*Correction.*Soumission.*Validation.*Réouverture/s.test(await l.locator(`tr[data-temps="${T_ADMIN}"] details`).textContent()));
  // Existants : provenance documentée à l'écran, rien d'inventé.
  await l.goto(B + "/rh/temps");
  verifier("temps antérieurs : « inconnu (antérieur au module RH) » affiché", (await l.textContent("main")).includes("inconnu (antérieur au module RH)"));

  // ==================== Nettoyage des données jetables ====================
  sql(`update public.profiles set collaborateur_id = collaborateur_id where false`);
} catch (e) {
  verifier("parcours interrompu", false, e.message.split("\n")[0]);
} finally {
  await nav.close();
  console.log(`\nBILAN : ${ok}/${ok + ko} contrôles réussis`);
}
