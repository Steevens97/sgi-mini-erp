// Test navigateur du module Absences et notes de frais sur l'environnement LOCAL (passerelle + base d'ESSAI), jamais
// Supabase. Prérequis : rejouer.sh comptes_navigateur.sql comptes_navigateur_absences.sql ; pile_locale.sh start ;
// build sur 127.0.0.1:54321 ; serveur_local.sh start. Lancer depuis scratchpad/essais (Playwright).
import { chromium } from "playwright";
import { execFileSync } from "node:child_process";
import { createHash } from "node:crypto";
import { mkdirSync, writeFileSync, readFileSync, existsSync } from "node:fs";

const B = process.argv[2] ?? "http://127.0.0.1:3200";
const DOSSIER = process.argv[3] ?? "/var/tmp/pg-essai/fichiers-essai";
let ok = 0, ko = 0;
const verifier = (l, c, d = "") => { c ? ok++ : ko++; console.log(`  [${c ? "OK " : "ÉCHEC"}] ${l}${d ? `  (${d})` : ""}`); };
const sql = (q) => execFileSync("psql", ["-h", "/var/tmp/pg-essai", "-p", "5499", "-U", "postgres", "-d", "essai", "-qAtX", "-c", q]).toString().trim();
const J = (n) => sql(`select ((now() at time zone 'America/Martinique')::date + ${n})::text`);
const fr = (iso) => iso.split("-").reverse().join("/");
const sha = (b) => createHash("sha256").update(b).digest("hex");
const LEA = "22222222-2222-2222-2222-222222222221", NGU = "22222222-2222-2222-2222-222222222223", FADM = "22222222-2222-2222-2222-2222222222fa";
const STOCKAGE = "/var/tmp/pg-essai/stockage/justificatifs";

// Fichiers d'essai : vrai PDF, vrai PNG, faux PDF (texte), PNG renommé en .pdf, fichier de plus de 10 Mo.
mkdirSync(DOSSIER, { recursive: true });
const PDF = Buffer.from("%PDF-1.4\n1 0 obj<</Type/Catalog/Pages 2 0 R>>endobj 2 0 obj<</Type/Pages/Kids[]/Count 0>>endobj\ntrailer<</Root 1 0 R>>\n%%EOF\n");
const PNG = Buffer.from("89504e470d0a1a0a0000000d4948445200000001000000010806000000" + "1f15c4890000000d49444154789c6360000002000154a24f5d0000000049454e44ae426082", "hex");
const fichiers = {
  vrai: [`${DOSSIER}/ticket-restaurant.pdf`, PDF], png: [`${DOSSIER}/peage.png`, PNG],
  faux: [`${DOSSIER}/faux-justificatif.pdf`, Buffer.from("Ceci n'est pas un PDF : simple texte.\n")],
  renomme: [`${DOSSIER}/image-renommee.pdf`, PNG], gros: [`${DOSSIER}/trop-gros.pdf`, Buffer.concat([PDF, Buffer.alloc(10 * 1024 * 1024 + 10)])],
  second: [`${DOSSIER}/hotel.pdf`, Buffer.concat([PDF, Buffer.from("% hotel\n")])],
};
for (const [chemin, contenu] of Object.values(fichiers)) writeFileSync(chemin, contenu);
const nbObjets = () => Number(sql("select count(*) from storage.objects where bucket_id = 'justificatifs'"));

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
const vu = async (zone, texte, selecteur = "[role=status]") => {
  try { await zone.locator(selecteur, { hasText: texte }).first().waitFor({ timeout: 30000 }); return true; } catch { return false; }
};
const formConge = (p) => p.locator("form", { has: p.locator("input[name=nb_jours]") }).first();
async function demande(p, { type = "conges_payes", debut, fin, apresMidi = false, finMidi = false, jours, pour, motifRetro }) {
  const f = formConge(p);
  if (pour) await f.locator("select[name=collaborateur_id]").selectOption(pour);
  await f.locator("select[name=type]").selectOption(type);
  await f.locator("input[name=date_debut]").fill(debut);
  await f.locator("input[name=date_fin]").fill(fin);
  await f.locator("input[name=debut_apres_midi]").setChecked(apresMidi);
  await f.locator("input[name=fin_midi]").setChecked(finMidi);
  await f.locator("input[name=nb_jours]").fill(jours);
  if (motifRetro) await f.locator("input[name=motif_retroactif]").fill(motifRetro);
  return f;
}
const formNote = (p) => p.locator("form[data-formulaire-note=nouvelle]");
async function note(p, { date, montant, categorie = "repas", precision, objet, fichier }) {
  const f = formNote(p);
  await f.locator("input[name=date_depense]").fill(date);
  await f.locator("input[name=montant]").fill(montant);
  await f.locator("select[name=categorie]").selectOption(categorie);
  if (precision) await f.locator("input[name=categorie_precision]").fill(precision);
  await f.locator("input[name=objet]").fill(objet);
  if (fichier) await f.locator("input[name=fichier]").setInputFiles(fichier);
  await f.locator("button[type=submit]").click();
  return f;
}

// ============================ Collaboratrice (Léa Moreau) ============================
const l = await connexion("collab@exemple.invalid", "Essai-Collab-2026!");
console.log("== Collaboratrice — soldes et demandes");
await l.goto(B + "/absences");
let soldes = await l.locator("[data-mes-soldes]").textContent();
verifier("ses soldes : congés payés 25 jours, RTT « droits non renseignés » (pas « 0 »)",
  soldes.includes("Congés payés : 25 jour(s)") && soldes.includes("droits non renseignés") && soldes.includes("Cela ne signifie pas que vous n'avez aucun droit"));
verifier("aucune section « À décider » pour une collaboratrice", !(await l.content()).includes("À décider ("));
let f = await demande(l, { debut: J(10), fin: J(10), apresMidi: true, finMidi: true, jours: "0.5" });
verifier("un jour commencé l'après-midi et fini à midi : refus affiché AVANT l'envoi, bouton bloqué",
  (await f.locator("[role=alert]").first().textContent()).includes("Demi-journées incohérentes") && await f.locator("button[type=submit]").isDisabled());
f = await demande(l, { debut: J(10), fin: J(11), finMidi: true, jours: "2" });
verifier("2 jours sur J+10 → J+11 midi : dépassement signalé (1,5 au plus)", (await f.textContent()).includes("dépasse la période demandée (1,5 jour(s) au plus"));
f = await demande(l, { debut: J(10), fin: J(11), finMidi: true, jours: "1.5" });
verifier("limite et estimation indicative affichées (le nombre saisi fait foi)",
  (await f.textContent()).includes("Au plus 1,5 jour(s)") && (await f.textContent()).includes("c'est le nombre saisi qui sera enregistré"));
await f.locator("button[type=submit]").click();
verifier("demande de 1,5 jour envoyée", await vu(l, "Demande enregistrée"));
const cLea = sql(`select id from public.conges where collaborateur_id = '${LEA}' and date_debut = '${J(10)}'`);
verifier("enregistrée « demandée », 1,5 jour, demi-journée de fin", sql(`select statut || '/' || nb_jours || '/' || fin_midi from public.conges where id = '${cLea}'`) === "demandee/1.50/true");
await l.goto(B + "/absences");
f = await demande(l, { debut: J(11), fin: J(11), finMidi: true, jours: "0.5" });
await f.locator("button[type=submit]").click();
verifier("chevauchement du matin de J+11 : refusé par la base, message clair", await vu(l, "Chevauchement : une demande en attente existe déjà"));
verifier("saisie refusée conservée à l'écran (dates et jours)",
  (await formConge(l).locator("input[name=date_debut]").inputValue()) === J(11) && (await formConge(l).locator("input[name=nb_jours]").inputValue()) === "0.5");
await formConge(l).locator("input[name=debut_apres_midi]").setChecked(true);
await formConge(l).locator("input[name=fin_midi]").setChecked(false);
await formConge(l).locator("button[type=submit]").click();
verifier("l'après-midi de J+11 (libre) : accepté", await vu(l, "Demande enregistrée"));
await l.goto(B + "/absences");
f = await demande(l, { type: "rtt", debut: J(20), fin: J(20), jours: "1" });
verifier("RTT : avertissement « droits non renseignés » avant l'envoi", (await f.textContent()).includes("Droits RTT non renseignés pour cette personne"));
await f.locator("button[type=submit]").click();
verifier("demande de RTT enregistrée", await vu(l, "Demande enregistrée"));
await l.goto(B + "/absences");
f = await demande(l, { debut: J(-3), fin: J(-3), jours: "1" });
verifier("date passée : refusée pour une collaboratrice (bouton bloqué, message)",
  await f.locator("button[type=submit]").isDisabled() && (await f.textContent()).includes("réservée à l'administrateur"));

console.log("== Collaboratrice — notes de frais et justificatifs");
await l.goto(B + "/rh/notes-de-frais");
const avant = nbObjets();
await note(l, { date: J(-1), montant: "18.4", objet: "Faux justificatif", fichier: fichiers.faux[0] });
verifier("faux PDF (texte renommé) : refusé par le SERVEUR (signature)", await vu(l, "son contenu n'est pas un PDF, un JPEG ou un PNG valide"));
verifier("fichier refusé supprimé du stockage (aucun reste)", nbObjets() === avant, `${nbObjets()} objet(s)`);
verifier("saisie conservée après le refus (montant, objet)",
  (await formNote(l).locator("input[name=montant]").inputValue()) === "18.4" && (await formNote(l).locator("input[name=objet]").inputValue()) === "Faux justificatif");
await l.goto(B + "/rh/notes-de-frais");
await note(l, { date: J(-1), montant: "18.4", objet: "Image renommée", fichier: fichiers.renomme[0] });
verifier("PNG renommé en .pdf : refusé (contenu ≠ extension)", await vu(l, "son contenu ne correspond pas à son extension"));
verifier("fichier renommé supprimé du stockage", nbObjets() === avant);
await l.goto(B + "/rh/notes-de-frais");
await note(l, { date: J(-1), montant: "18.4", objet: "Trop gros", fichier: fichiers.gros[0] });
verifier("fichier de plus de 10 Mo : refusé avant tout envoi", await vu(l, "Fichier de plus de 10 Mo : refusé."));
verifier("rien déposé pour le fichier trop gros", nbObjets() === avant);
// Échec ENTRE le dépôt et la création : la base refuse (dépense avant l'entrée), le fichier déposé est réutilisé ensuite.
sql(`update public.collaborateurs set date_entree = '${J(-5)}' where id = '${LEA}'`);
await l.goto(B + "/rh/notes-de-frais");
f = await note(l, { date: J(-10), montant: "42.5", objet: "Déjeuner chantier", fichier: fichiers.vrai[0] });
verifier("dépôt fait puis note refusée par la base (dépense avant l'entrée) : message clair", await vu(l, "antérieure à l'entrée du collaborateur"));
verifier("le fichier déposé est conservé pour la nouvelle tentative (1 dépôt, non rattaché)", nbObjets() === avant + 1
  && (await f.textContent()).includes("Fichier déjà déposé : ticket-restaurant.pdf"));
await f.locator("input[name=date_depense]").fill(J(-1));
await f.locator("button[type=submit]").click();
verifier("nouvelle tentative : note créée avec le MÊME fichier (aucun second dépôt)", await vu(l, "Note de frais déposée") && nbObjets() === avant + 1);
const n1 = sql(`select id from public.notes_de_frais where collaborateur_id = '${LEA}' and objet = 'Déjeuner chantier'`);
const chemin1 = sql(`select justificatif_url from public.notes_de_frais where id = '${n1}'`);
verifier("empreinte enregistrée = SHA-256 du fichier envoyé ; chemin dans le dossier de la fiche",
  sql(`select justificatif_empreinte from public.notes_de_frais where id = '${n1}'`) === sha(fichiers.vrai[1]) && chemin1.startsWith(`${LEA}/`));
const reponse = await l.request.get(`${B}/rh/notes-de-frais/${n1}/justificatif`);
const recu = await reponse.body();
verifier("consultation : lien temporaire, fichier reçu identique (SHA-256)", reponse.ok() && sha(recu) === sha(fichiers.vrai[1]), `HTTP ${reponse.status()}`);
verifier("le lien temporaire n'est stocké nulle part en base", sql(`select count(*) from public.notes_de_frais where historique::text like '%token=%' or justificatif_url like '%token%'`) === "0");
await l.goto(B + "/rh/notes-de-frais");
const ligne = l.locator(`tr[data-note="${n1}"]`);
await ligne.locator("summary", { hasText: "Modifier" }).click();
await ligne.locator("input[name=montant]").fill("40");
await ligne.locator("input[name=fichier]").setInputFiles(fichiers.png[0]);
await ligne.locator("button[type=submit]").click();
verifier("note soumise modifiée (montant, justificatif remplacé)", await vu(ligne, "l'ancien justificatif reste conservé"));
verifier("ancien justificatif toujours dans le stockage et rattaché par l'historique",
  existsSync(`${STOCKAGE}/${chemin1}`) && sql(`select public.abs_justificatif_rattache('${chemin1}')`) === "t");
await l.goto(B + "/rh/notes-de-frais");
const ancien = await l.request.get(`${B}/rh/notes-de-frais/${n1}/justificatif?ancien=0`);
verifier("ancien justificatif consultable (même contrôle d'empreinte)", ancien.ok() && sha(await ancien.body()) === sha(fichiers.vrai[1]));

// ============================ Manager de l'équipe (Dubois) ============================
const m = await connexion("manager@exemple.invalid", "Essai-Manager-2026!");
console.log("== Manager de l'équipe — décisions");
await m.goto(B + "/absences");
const ligneConge = m.locator(`tr[data-conge="${cLea}"]`);
verifier("demande de Léa à décider, solde affiché (25 j)", (await ligneConge.textContent()).includes("Solde Congés payés : 25 j"));
await ligneConge.locator("button", { hasText: "Valider" }).click();
verifier("validation : confirmation visible en haut de page", await vu(m, "Demande validée ; le solde est prélevé une seule fois.", "[data-confirmation]"));
verifier("solde de Léa : 25 → 23,5", sql(`select solde_conges from public.collaborateurs where id = '${LEA}'`) === "23.50");
await m.goto(B + "/absences");
const cRtt = sql(`select id from public.conges where collaborateur_id = '${LEA}' and type = 'rtt'`);
const ligneRtt = m.locator(`tr[data-conge="${cRtt}"]`);
await ligneRtt.locator("button", { hasText: "Valider" }).click();
verifier("RTT sans droits renseignés : validation refusée, message explicite", await vu(ligneRtt, "(droits RTT non renseignés). Validation refusée."));
verifier("refus de validation : demande toujours « demandée »", sql(`select statut from public.conges where id = '${cRtt}'`) === "demandee");
await m.goto(B + "/rh/notes-de-frais");
const ligneNote = m.locator(`tr[data-note="${n1}"]`);
const vueManager = await m.request.get(`${B}/rh/notes-de-frais/${n1}/justificatif`);
verifier("manager de l'équipe : justificatif consultable", vueManager.ok() && sha(await vueManager.body()) === sha(fichiers.png[1]));
await ligneNote.locator("button", { hasText: "Valider" }).click();
verifier("note de Léa validée par son manager (confirmation en haut de page)", await vu(m, "Note validée", "[data-confirmation]") && sql(`select statut from public.notes_de_frais where id = '${n1}'`) === "validee");
await l.goto(B + "/rh/notes-de-frais");
verifier("note validée : plus de « Modifier » pour Léa", (await l.locator(`tr[data-note="${n1}"] summary`, { hasText: "Modifier" }).count()) === 0);
await l.goto(B + "/absences");
verifier("Léa voit son nouveau solde (23,5) et l'historique du prélèvement",
  (await l.locator("[data-mes-soldes]").textContent()).includes("Congés payés : 23,5 jour(s)"));

// ============================ Accès croisés ============================
console.log("== Accès croisés");
const k = await connexion("karim@exemple.invalid", "Essai-Karim-2026!");
await k.goto(B + "/absences");
verifier("manager hors équipe : aucune demande de Léa", !(await k.content()).includes("Moreau"));
const rk = await k.request.get(`${B}/rh/notes-de-frais/${n1}/justificatif`, { maxRedirects: 0 });
verifier("manager hors équipe : justificatif de Léa refusé", rk.status() === 404, `HTTP ${rk.status()}`);
const c = await connexion("chloe@exemple.invalid", "Essai-Chloe-2026!");
const rc = await c.request.get(`${B}/rh/notes-de-frais/${n1}/justificatif`, { maxRedirects: 0 });
verifier("collègue de la même équipe : justificatif de Léa refusé", rc.status() === 404, `HTTP ${rc.status()}`);
await c.goto(B + "/rh/notes-de-frais");
verifier("collègue : aucune note de Léa listée", (await c.locator(`tr[data-note="${n1}"]`).count()) === 0 && (await c.locator("tr[data-note]").count()) === 0);
await c.goto(B + "/absences");
verifier("collègue : soldes de Léa invisibles (seulement les siens)", (await c.locator("[data-mes-soldes]").textContent()).includes("Congés payés : 25 jour(s)")
  && !(await c.content()).includes("23,5"));
const anonyme = await (await nav.newContext()).request.get(`${B}/rh/notes-de-frais/${n1}/justificatif`, { maxRedirects: 0 });
verifier("visiteur non connecté : renvoyé vers la connexion", [302, 303, 307].includes(anonyme.status()) && (anonyme.headers().location ?? "").includes("/connexion"),
  `HTTP ${anonyme.status()}`);

// ============================ Administrateur ============================
const a = await connexion("sgi@gmx.fr", "Essai-Admin-2026!");
console.log("== Administrateur — soldes, décisions, remboursements");
await a.goto(B + "/absences/soldes");
const ligneLea = a.locator(`tr[data-fiche="${LEA}"]`);
verifier("vue globale : Léa 23,5 j, RTT « droits non renseignés »", (await ligneLea.textContent()).includes("23,5 j") && (await ligneLea.textContent()).includes("droits non renseignés"));
verifier("sa propre fiche : aucun formulaire d'ajustement", (await a.locator(`tr[data-fiche="${FADM}"]`).textContent()).includes("ajustement par un autre administrateur"));
await ligneLea.locator("select[name=type]").selectOption("rtt");
await ligneLea.locator("input[name=nouveau]").fill("3");
await ligneLea.locator("input[name=motif]").fill("Accord RTT 2026 (essai)");
await ligneLea.locator("button", { hasText: "Ajuster" }).click();
verifier("droits RTT renseignés (0 → 3), motivés", await vu(a, "Solde ajusté", "[data-confirmation]"));
await a.goto(B + "/absences/soldes");
verifier("RTT de Léa affiché 3 j, historique avec le motif", (await a.locator(`tr[data-fiche="${LEA}"]`).textContent()).includes("3 j")
  && (await a.locator(`tr[data-fiche="${LEA}"]`).textContent()).includes("Accord RTT 2026 (essai)"));
await a.goto(B + "/absences");
await a.locator(`tr[data-conge="${cRtt}"] button`, { hasText: "Valider" }).click();
verifier("RTT validée après renseignement des droits (3 → 2)", await vu(a, "Demande validée", "[data-confirmation]")
  && sql(`select solde_rtt from public.collaborateurs where id = '${LEA}'`) === "2.00");
await a.goto(B + "/absences");
f = await demande(a, { pour: FADM, debut: J(30), fin: J(30), jours: "1" });
await f.locator("button[type=submit]").click();
verifier("admin : sa propre demande enregistrée", await vu(a, "Demande enregistrée"));
const cAdm = sql(`select id from public.conges where collaborateur_id = '${FADM}'`);
await a.goto(B + "/absences");
verifier("sa propre demande : jamais dans « À décider » (pas d'auto-validation)", (await a.locator(`tr[data-conge="${cAdm}"]`).count()) === 1
  && (await a.locator(`tr[data-conge="${cAdm}"] button`, { hasText: "Valider" }).count()) === 0);
// Demande rétroactive sur des jours où Léa a déjà saisi des temps (données de démonstration : J-5 et J-4).
f = await demande(a, { pour: LEA, type: "sans_solde", debut: J(-5), fin: J(-4), jours: "2", motifRetro: "Régularisation (essai)" });
verifier("alerte AVANT l'envoi : temps déjà saisis sur la période", (await f.textContent()).includes("des temps sont déjà saisis sur cette période"));
await f.locator("button[type=submit]").click();
verifier("demande rétroactive motivée (admin) enregistrée", await vu(a, "Demande enregistrée"));
await a.goto(B + "/absences");
const cRetro = sql(`select id from public.conges where collaborateur_id = '${LEA}' and date_debut = '${J(-5)}'`);
const ligneRetro = a.locator(`tr[data-conge="${cRetro}"]`);
verifier("à décider : alerte précise des temps saisis (dates, heures), sans modification automatique",
  (await ligneRetro.textContent()).includes(`Temps saisis sur cette période : ${fr(J(-5))} (6,5 h), ${fr(J(-4))} (7 h)`)
  && sql(`select count(*) from public.temps where collaborateur_id = '${LEA}' and date_saisie between '${J(-5)}' and '${J(-4)}'`) === "2");
await ligneRetro.locator("input[name=motif]").fill("Temps déjà saisis ces jours-là");
await ligneRetro.locator("button", { hasText: "Refuser" }).click();
verifier("refus motivé (confirmation), aucun temps modifié", await vu(a, "Demande refusée (motif enregistré)", "[data-confirmation]")
  && sql(`select statut || '/' || motif_decision from public.conges where id = '${cRetro}'`) === "refusee/Temps déjà saisis ces jours-là");
await a.goto(B + "/rh/notes-de-frais");
const ligneR = a.locator(`tr[data-note="${n1}"]`);
await ligneR.locator("input[name=rembourse_le]").fill(J(0));
await ligneR.locator("input[name=reference]").fill("VIR-ESSAI-1");
await ligneR.locator("button", { hasText: "Déclarer le remboursement" }).click();
verifier("remboursement déclaré (confirmation)", await vu(a, "Remboursement déclaré", "[data-confirmation]"));
await a.goto(B + "/rh/notes-de-frais");
const ligneC = a.locator(`tr[data-note="${n1}"]`);
await ligneC.locator("input[aria-label='Référence corrigée']").fill("VIR-ESSAI-2");
await ligneC.locator("input[aria-label='Motif de la correction']").fill("Référence mal recopiée");
await ligneC.locator("button", { hasText: "Corriger" }).click();
verifier("déclaration corrigée (motif)", await vu(a, "Déclaration de remboursement corrigée", "[data-confirmation]"));
await a.goto(B + "/rh/notes-de-frais");
await a.locator(`tr[data-note="${n1}"] input[aria-label="Motif de l'annulation"]`).fill("Virement rejeté (essai)");
await a.locator(`tr[data-note="${n1}"] button`, { hasText: "Annuler la déclaration" }).click();
verifier("déclaration annulée : note redevenue « validée », historique complet",
  await vu(a, "Déclaration annulée", "[data-confirmation]")
  && sql(`select statut || ':' || (select string_agg(e ->> 'action', ',' order by o) from jsonb_array_elements(historique) with ordinality x(e, o)) from public.notes_de_frais where id = '${n1}'`)
     === "validee:soumission,modification,validation,remboursement_declare,remboursement_corrige,remboursement_annule");
// Dépôts abandonnés : un vieux dépôt non rattaché est supprimé ; les justificatifs rattachés (même anciens) restent.
const orphelin = `${NGU}/00000000-0000-4000-8000-000000000001.pdf`;
mkdirSync(`${STOCKAGE}/${NGU}`, { recursive: true }); writeFileSync(`${STOCKAGE}/${orphelin}`, PDF);
sql(`insert into storage.objects (bucket_id, name, metadata, created_at) values ('justificatifs', '${orphelin}', '{"size": ${PDF.length}, "mimetype": "application/pdf"}', now() - interval '2 hours')`);
sql(`update storage.objects set created_at = now() - interval '3 hours' where name = '${chemin1}'`);
await a.goto(B + "/rh/notes-de-frais");
await a.locator("button", { hasText: "Supprimer les dépôts abandonnés" }).click();
verifier("nettoyage : 1 dépôt abandonné supprimé", await vu(a, "1 dépôt(s) abandonné(s) supprimé(s)"));
verifier("justificatifs rattachés (actuel et ancien, même vieux de 3 h) intacts",
  existsSync(`${STOCKAGE}/${chemin1}`) && sql(`select count(*) from storage.objects where name = '${chemin1}'`) === "1" && !existsSync(`${STOCKAGE}/${orphelin}`));
// Fichier altéré dans le stockage : consultation bloquée.
const chemin2 = sql(`select justificatif_url from public.notes_de_frais where id = '${n1}'`);
const original = readFileSync(`${STOCKAGE}/${chemin2}`);
writeFileSync(`${STOCKAGE}/${chemin2}`, Buffer.concat([original.subarray(0, original.length - 1), Buffer.from([original[original.length - 1] ^ 1])]));
const altere = await a.request.get(`${B}/rh/notes-de-frais/${n1}/justificatif`, { maxRedirects: 0 });
verifier("fichier altéré (même taille) : consultation bloquée", altere.status() === 409 && (await altere.text()).includes("Justificatif altéré"), `HTTP ${altere.status()}`);
writeFileSync(`${STOCKAGE}/${chemin2}`, original);

// ============================ Anciennes sessions ============================
console.log("== Anciennes sessions");
// Page ouverte AVANT la révocation : l'envoi qui suit ne doit rien déposer ni enregistrer.
await l.goto(B + "/rh/notes-de-frais");
const avantRevoc = nbObjets();
sql(`delete from auth.sessions where user_id = (select id from auth.users where email = 'collab@exemple.invalid')`);
const apres = await l.request.get(`${B}/rh/notes-de-frais/${n1}/justificatif`, { maxRedirects: 0 });
verifier("session révoquée : justificatif refusé (renvoi vers la connexion)",
  [302, 303, 307].includes(apres.status()) && (apres.headers().location ?? "").includes("/connexion"), `HTTP ${apres.status()}`);
await note(l, { date: J(-1), montant: "5", objet: "Après révocation", fichier: fichiers.second[0] });
await l.waitForTimeout(3000);
verifier("session révoquée : dépôt refusé depuis une page déjà ouverte, rien dans le stockage ni en base",
  nbObjets() === avantRevoc && sql("select count(*) from public.notes_de_frais where objet = 'Après révocation'") === "0", `${nbObjets()} / ${avantRevoc}`);
await l.goto(B + "/absences");
verifier("session révoquée : renvoyée vers la connexion, plus aucun solde visible", l.url().includes("/connexion") && !(await l.content()).includes("23,5"));

await nav.close();
console.log(`\nBILAN : ${ok}/${ok + ko} contrôles réussis`);
