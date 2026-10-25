// Essais de bout en bout des relances sur la pile LOCALE (passerelle + base d'ESSAI + serveur Next local) avec une
// IMITATION du fournisseur (imitation_resend.mjs) : AUCUN email réel, aucune adresse réelle (destinataires en
// exemple.invalid, permis ici seulement : la règle réelle est rétablie et contrôlée à la fin).
// Prérequis : rejouer.sh comptes_navigateur.sql ; build sur 127.0.0.1:54321 ; pile_locale.sh start. Le script démarre
// lui-même l'imitation et le serveur Next (port 3200) avec des secrets ALÉATOIRES de ce seul essai (jamais affichés).
import { chromium } from "playwright";
import { execFileSync, spawn } from "node:child_process";
import { createHash, createHmac, randomBytes } from "node:crypto";
import { readFileSync } from "node:fs";
import { dirname, resolve } from "node:path";
import { fileURLToPath } from "node:url";

const ICI = dirname(fileURLToPath(import.meta.url));
// Lancé depuis scratchpad/essais (Playwright) : le dépôt est désigné par SGI_DEPOT, sinon déduit de l'emplacement.
const SIMU = process.env.SGI_DEPOT ? resolve(process.env.SGI_DEPOT, "tests-reels/simulation") : ICI;
const SERVEUR = resolve(SIMU, "serveur_local.sh");
const B = "http://127.0.0.1:3200", F = "http://127.0.0.1:3300", P = "http://127.0.0.1:54321";
let ok = 0, ko = 0;
const verifier = (l, c, d = "") => { c ? ok++ : ko++; console.log(`  [${c ? "OK " : "ÉCHEC"}] ${l}${d ? `  (${d})` : ""}`); };
const sql = (q) => execFileSync("psql", ["-h", "/var/tmp/pg-essai", "-p", "5499", "-U", "postgres", "-d", "essai", "-qAtX", "-v", "ON_ERROR_STOP=1", "-c", q]).toString().trim();
const SERVICE = /ESSAI_SERVICE=(\S+)/.exec(readFileSync("/var/tmp/pg-essai/cles_locales.sh", "utf8"))[1];
const CLE = "re_imitation_" + randomBytes(12).toString("hex"), CLE2 = "re_imitation_" + randomBytes(12).toString("hex");
const SECRET = randomBytes(24).toString("hex"), WHSEC = "whsec_" + randomBytes(24).toString("base64");
const ESSAI = "destinataire-essai@exemple.invalid";
const SECRETS = [CLE, CLE2, SECRET, WHSEC, WHSEC.slice(6)];

// --- Imitation du fournisseur et serveur Next --------------------------------------------------------------------
const imitation = spawn("node", [resolve(SIMU, "imitation_resend.mjs"), "3300", CLE], { stdio: "ignore" });
await new Promise((r) => setTimeout(r, 800));
const etat = async () => (await fetch(`${F}/__etat`)).json();
const modeImitation = (mode) => fetch(`${F}/__mode`, { method: "POST", body: JSON.stringify({ mode }) });
function serveur(env) {
  // Sorties ignorées : sinon le serveur lancé en arrière-plan garde la sortie ouverte et l'appel ne rend jamais la main.
  execFileSync("bash", [SERVEUR, "stop"], { stdio: "ignore" });
  execFileSync("bash", [SERVEUR, "start"], { stdio: "ignore", env: { ...process.env, RESEND_URL: F, RESEND_API_KEY: CLE,
    RELANCES_SECRET_CRON: SECRET, RESEND_WEBHOOK_SECRET: WHSEC, RELANCES_ADRESSE_ESSAI: ESSAI, RESEND_COMPTE_REFERENCE: "resend-essai-1", ...env } });
}
// Après un redémarrage du serveur, Node peut réutiliser une connexion vers l'ancien serveur arrêté (« other side
// closed ») : la demande n'a alors jamais été reçue, elle est renvoyée (une fois) sur une nouvelle connexion.
async function demander(url, options) {
  try {
    return await fetch(url, options);
  } catch (e) {
    if (e?.cause?.code !== "UND_ERR_SOCKET" && e?.cause?.code !== "ECONNRESET") throw e;
    return fetch(url, options);
  }
}
const executer = (auth = `Bearer ${SECRET}`, methode = "POST") =>
  demander(`${B}/api/relances/executer`, { method: methode, redirect: "manual", headers: auth ? { Authorization: auth } : {} });
// Événement de livraison signé comme le fait le fournisseur (format Svix), SANS étiquette de relance.
function evenementSansEtiquette(id, type, emailId, quand) {
  const corps = JSON.stringify({ type, created_at: quand, data: { email_id: emailId } });
  const t = Math.floor(Date.now() / 1000);
  const sig = createHmac("sha256", Buffer.from(WHSEC.slice(6), "base64")).update(`${id}.${t}.${corps}`).digest("base64");
  return demander(`${B}/api/relances/livraison`, { method: "POST", body: corps,
    headers: { "svix-id": id, "svix-timestamp": String(t), "svix-signature": `v1,${sig}`, "Content-Type": "application/json" } });
}
const relance = (num) => JSON.parse(sql(`select coalesce((select row_to_json(r) from (select r.* from public.relances r
  join public.factures f on f.id = r.facture_id where f.numero = '${num}' order by r.created_at desc limit 1) r), '{}')`));

// --- Données d'essai et horloge simulée ---------------------------------------------------------------------------
const DEF = sql("select md5(prosrc) from pg_proc where proname = 'relances_maintenant'");
sql(`create schema if not exists relt; create table if not exists relt.horloge (t timestamptz); delete from relt.horloge;
  insert into relt.horloge values ('2026-11-02 19:00:00+00'); grant usage on schema relt to service_role, authenticated;
  grant select on relt.horloge to service_role, authenticated;
  create or replace function public.relances_maintenant() returns timestamptz language sql stable
    as $f$ select coalesce((select t from relt.horloge), now()) $f$;
  create or replace function public.relances_adresse_fictive(p_adresse text) returns boolean language sql immutable as $f$ select false $f$;
  insert into public.clients (id, nom, email_contact) values
    ('55555555-0000-0000-0000-00000000e2e1', '[ESSAI] Client relances E2E', 'client-essai-e2e@exemple.invalid'),
    ('55555555-0000-0000-0000-00000000e2e2', '[ESSAI] Client sans email E2E', null);
  create or replace function relt.facture(p_num text, p_echeance date, p_client uuid) returns uuid language plpgsql as $$
  declare v uuid := gen_random_uuid();
  begin
    perform public.finance_contexte('emission', '{"action":"emission","test":"e2e_relances"}', v);
    insert into public.factures (id, client_id, numero, statut, essai, date_emission, date_echeance, total_ht, tva, total_ttc,
                                 instantane_emission, cle_emission, pdf_statut)
    values (v, p_client, p_num, 'emise', true, p_echeance - 30, p_echeance, 1000, 85, 1085, '{}', gen_random_uuid(), 'a_generer');
    perform public.finance_fin_contexte();
    return v;
  end $$;`);
const horloge = (t) => sql(`update relt.horloge set t = '${t}'`);
const PDF = Buffer.from("%PDF-1.4\n% PDF d'essai des relances (sans valeur)\n1 0 obj << /Type /Catalog >> endobj\ntrailer << /Root 1 0 R >>\n%%EOF\n");
const sha = (b) => createHash("sha256").update(b).digest("hex");
async function facture(num, joursRetard, { pdf = true, client = "55555555-0000-0000-0000-00000000e2e1", empreinte = null } = {}) {
  const id = sql(`select relt.facture('${num}', date '2026-11-02' - ${joursRetard}, '${client}')`);
  if (pdf) {
    const chemin = `${id}/${num}.pdf`;
    const r = await fetch(`${P}/storage/v1/object/factures/${chemin}`, { method: "POST", body: PDF,
      headers: { Authorization: `Bearer ${SERVICE}`, apikey: SERVICE, "Content-Type": "application/pdf" } });
    if (r.status !== 200) throw new Error(`dépôt du PDF d'essai : HTTP ${r.status}`);
    sql(`select public.finance_enregistrer_pdf('${id}', '${chemin}', '${empreinte ?? sha(PDF)}', ${PDF.length})`);
  }
  return id;
}
const FA = await facture("ESSAI-FAC-2026-0201", 40);
await facture("ESSAI-FAC-2026-0202", 20, { pdf: false });
await facture("ESSAI-FAC-2026-0203", 20, { client: "55555555-0000-0000-0000-00000000e2e2" });
await facture("ESSAI-FAC-2026-0204", 20, { empreinte: "0".repeat(64) });   // PDF stocké ≠ empreinte enregistrée (altéré)

try {
  console.log("== Route d'exécution, relances NON activées");
  serveur({ RELANCES_ACTIVES: "" });
  let r = await executer(null);
  verifier("sans secret : refusé (401), pas de redirection vers la connexion", r.status === 401, `HTTP ${r.status}`);
  r = await executer("Bearer " + "x".repeat(48));
  verifier("mauvais secret : refusé (401)", r.status === 401, `HTTP ${r.status}`);
  // Secret (aléatoire, de cet essai seulement) placé dans l'URL SANS en-tête : jamais accepté.
  r = await demander(`${B}/api/relances/executer?secret=${SECRET}&authorization=Bearer%20${SECRET}`, { method: "POST", redirect: "manual" });
  verifier("secret dans l'URL (sans en-tête Authorization) : refusé (401)", r.status === 401, `HTTP ${r.status}`);
  r = await executer(`Bearer ${SECRET}`, "GET");
  verifier("méthode GET : refusée (405)", r.status === 405, `HTTP ${r.status}`);
  r = await executer();
  const b0 = await r.json();
  verifier("bon secret, relances non activées : rien réservé, rien envoyé", r.status === 200 && b0.actives === false
    && sql("select count(*) from public.relances") === "0" && (await etat()).demandes.length === 0, JSON.stringify(b0));
  verifier("… le rapprochement et le nettoyage des événements tournent quand même (aucun envoi)",
    b0.evenements?.examines === 0 && b0.evenements?.purges === 0, JSON.stringify(b0.evenements));

  console.log("== Relances activées : première exécution (lundi 15 h en Martinique)");
  serveur({ RELANCES_ACTIVES: "1" });
  const b1 = await (await executer()).json();
  const ra = relance("ESSAI-FAC-2026-0201");
  verifier("J+40 : une seule relance (n° 1), acceptée, date d'envoi = acceptation", b1.reservees === 1 && b1.acceptees === 1
    && ra.rang === 1 && ra.statut === "acceptee" && ra.date_envoi?.startsWith("2026-11-02T19:00:00"), JSON.stringify(b1));
  verifier("PDF altéré : aucune réservation (contrôle AVANT la réservation)",
    b1.ignorees.some((i) => i.facture === "ESSAI-FAC-2026-0204" && /altéré/.test(i.motif)) && !relance("ESSAI-FAC-2026-0204").id);
  verifier("sans PDF archivé / client sans email : jamais relancées",
    !relance("ESSAI-FAC-2026-0202").id && !relance("ESSAI-FAC-2026-0203").id);
  let e = await etat();
  const em = e.emails[0];
  verifier("imitation : 1 email, à l'adresse de test, objet [ESSAI], clé anti-doublon de la relance", e.emails.length === 1
    && em.to[0] === ESSAI && em.subject === "[ESSAI] Facture ESSAI-FAC-2026-0201 : rappel d'échéance" && em.cle === `sgi-relance-${ra.id}`);
  verifier("pièce jointe = PDF archivé (même empreinte), nommée d'après le numéro",
    em.pieces.length === 1 && em.pieces[0].filename === "ESSAI-FAC-2026-0201.pdf" && em.pieces[0].sha256 === sha(PDF));
  verifier("étiquette de la relance transmise ; clé du fournisseur seulement dans l'en-tête Authorization",
    em.tags?.[0]?.value === ra.id && e.demandes[0].auth_ok && !SECRETS.some((s) => e.demandes[0].corps.includes(s)));
  verifier("texte envoyé = texte figé en base", em.text === ra.message && em.from === ra.requete_fournisseur.from);
  const b2 = await (await executer()).json();
  e = await etat();
  verifier("seconde exécution le même jour : aucune nouvelle relance, aucun appel", b2.reservees === 0 && e.demandes.length === 1, JSON.stringify(b2));

  console.log("== Coupure après acceptation par le fournisseur, avant l'enregistrement");
  await facture("ESSAI-FAC-2026-0205", 12);
  await modeImitation("coupure_apres_acceptation");
  await executer();
  let re = relance("ESSAI-FAC-2026-0205");
  verifier("réponse perdue : « envoi non confirmé », AUCUNE date d'envoi", re.statut === "en_cours" && re.date_envoi === null && re.tentatives === 1, re.erreur);
  // L'imitation a accepté l'email : son identifiant existe chez le fournisseur, pas encore dans la base. Événement sans
  // étiquette, envoyé maintenant : ENREGISTRÉ (200) et conservé en attente ; la relance n'est pas modifiée.
  const idPerdu = (await etat()).emails.find((x) => x.cle === `sgi-relance-${re.id}`).id;
  // Route sans référence de compte : 500, RIEN enregistré (le fournisseur renverra) ; puis remise en ordre et renvoi.
  serveur({ RELANCES_ACTIVES: "1", RESEND_COMPTE_REFERENCE: "" });
  let rp = await evenementSansEtiquette("msg_precoce", "email.delivered", idPerdu, "2026-11-02T19:00:20Z");
  verifier("route sans référence de compte : 500, rien enregistré", rp.status === 500
    && sql("select count(*) from public.relances_evenements where evenement_id = 'msg_precoce'") === "0", `HTTP ${rp.status}`);
  serveur({ RELANCES_ACTIVES: "1" });
  rp = await evenementSansEtiquette("msg_precoce", "email.delivered", idPerdu, "2026-11-02T19:00:20Z");
  const corpsPrecoce = await rp.json();
  verifier("renvoyé (sans étiquette, avant l'enregistrement de l'identifiant) : 200, CONSERVÉ en attente, relance inchangée",
    rp.status === 200 && corpsPrecoce.resultat === "en_attente"
    && sql("select statut || ',' || compte_fournisseur from public.relances_evenements where evenement_id = 'msg_precoce'") === "en_attente,resend-essai-1"
    && relance("ESSAI-FAC-2026-0205").livre_le === null && relance("ESSAI-FAC-2026-0205").fournisseur_id === null, `HTTP ${rp.status}`);
  await modeImitation("normal");
  horloge("2026-11-02 19:11:00+00");
  await executer();
  verifier("reprise acceptée : l'événement conservé est rapproché aussitôt (livre_le), sans renvoi du fournisseur",
    sql("select statut from public.relances_evenements where evenement_id = 'msg_precoce'") === "rapproche"
    && relance("ESSAI-FAC-2026-0205").livre_le?.startsWith("2026-11-02T19:00:20"));
  rp = await evenementSansEtiquette("msg_precoce", "email.delivered", idPerdu, "2026-11-02T19:00:20Z");
  verifier("renvoyé encore une fois : « déjà », un seul événement dans l'historique", (await rp.json()).resultat === "deja"
    && relance("ESSAI-FAC-2026-0205").historique.filter((e) => e.evenement_id === "msg_precoce").length === 1);
  re = relance("ESSAI-FAC-2026-0205");
  e = await etat();
  const demE = e.demandes.filter((d) => d.cle === `sgi-relance-${re.id}`);
  verifier("reprise : même demande et même clé → acceptée avec l'identifiant d'origine, UN seul email",
    re.statut === "acceptee" && re.tentatives === 2 && e.emails.filter((x) => x.cle === `sgi-relance-${re.id}`).length === 1
    && demE.length === 2 && demE[0].corps === demE[1].corps && re.fournisseur_id === e.emails.find((x) => x.cle === `sgi-relance-${re.id}`).id);

  console.log("== Configuration modifiée entre deux tentatives : la demande déjà tentée ne change pas");
  await facture("ESSAI-FAC-2026-0206", 12);
  await modeImitation("erreur_503");
  await executer();
  verifier("503 : réponse temporaire, en cours", relance("ESSAI-FAC-2026-0206").statut === "en_cours");
  serveur({ RELANCES_ACTIVES: "1", RELANCES_ADRESSE_ESSAI: "autre-essai@exemple.invalid" });
  await modeImitation("normal");
  horloge("2026-11-02 19:22:00+00");
  await executer();
  const rg = relance("ESSAI-FAC-2026-0206");
  e = await etat();
  verifier("reprise après changement d'adresse de test : envoyée à l'adresse FIGÉE (pas la nouvelle)",
    rg.statut === "acceptee" && e.emails.find((x) => x.cle === `sgi-relance-${rg.id}`)?.to[0] === ESSAI);

  console.log("== Compte fournisseur changé pendant une reprise");
  serveur({ RELANCES_ACTIVES: "1" });
  await facture("ESSAI-FAC-2026-0207", 12);
  await modeImitation("erreur_503");
  await executer();
  serveur({ RELANCES_ACTIVES: "1", RESEND_API_KEY: CLE2, RESEND_COMPTE_REFERENCE: "resend-essai-2" });
  await modeImitation("normal");
  horloge("2026-11-02 19:33:00+00");
  const n = (await etat()).demandes.length;
  await executer();
  const rh = relance("ESSAI-FAC-2026-0207");
  verifier("autre compte : « à vérifier », aucun appel au fournisseur", rh.statut === "a_verifier"
    && /Compte fournisseur différent/.test(rh.erreur) && (await etat()).demandes.length === n);
  // Événement reçu par le nouveau compte au sujet d'un email de l'ancien : jamais rapproché, alerte.
  rp = await evenementSansEtiquette("msg_autre_compte", "email.bounced", ra.fournisseur_id, "2026-11-02T19:34:00Z");
  verifier("événement signé pour le nouveau compte, email de l'ancien : en attente, alerte « Compte fournisseur différent »",
    rp.status === 200 && (await rp.json()).resultat === "en_attente"
    && sql("select alerte from public.relances_evenements where evenement_id = 'msg_autre_compte'").startsWith("Compte fournisseur différent")
    && relance("ESSAI-FAC-2026-0201").rebond_le === null);
  serveur({ RELANCES_ACTIVES: "1" });

  console.log("== Refus certain (422)");
  await facture("ESSAI-FAC-2026-0208", 12);
  await modeImitation("refus_422");
  await executer();
  await modeImitation("normal");
  const ri = relance("ESSAI-FAC-2026-0208");
  verifier("422 : « refusée », aucune date d'envoi, message sans secret", ri.statut === "refusee" && ri.date_envoi === null
    && ri.erreur === "HTTP 422 validation_error : Invalid `to` field");

  console.log("== Événements de livraison signés");
  const signer = (id, corps, t = Math.floor(Date.now() / 1000), secret = WHSEC) =>
    ({ "svix-id": id, "svix-timestamp": String(t), "svix-signature": "v1," + createHmac("sha256", Buffer.from(secret.slice(6), "base64")).update(`${id}.${t}.${corps}`).digest("base64"),
       "Content-Type": "application/json" });
  const evenement = (id, type, emailId, quand, extra = {}) => {
    const corps = JSON.stringify({ type, created_at: quand, data: { email_id: emailId, tags: { relance_id: null }, ...extra } });
    return demander(`${B}/api/relances/livraison`, { method: "POST", body: corps, headers: signer(id, corps) });
  };
  r = await evenement("msg_1", "email.delivered", ra.fournisseur_id, "2026-11-02T19:00:30Z");
  verifier("livraison signée : enregistrée et rapprochée (livre_le)", r.status === 200 && (await r.json()).resultat === "rapproche"
    && relance("ESSAI-FAC-2026-0201").livre_le?.startsWith("2026-11-02T19:00:30"));
  r = await evenement("msg_1", "email.delivered", ra.fournisseur_id, "2026-11-02T19:00:30Z");
  verifier("même événement renvoyé : « déjà »", (await r.json()).resultat === "deja");
  const corpsFaux = JSON.stringify({ type: "email.bounced", created_at: "2026-11-02T19:01:00Z", data: { email_id: ra.fournisseur_id } });
  r = await demander(`${B}/api/relances/livraison`, { method: "POST", body: corpsFaux, headers: signer("msg_x", corpsFaux, undefined, "whsec_" + randomBytes(24).toString("base64")) });
  verifier("signature fausse : refusée (401), rien enregistré", r.status === 401 && relance("ESSAI-FAC-2026-0201").statut === "acceptee");
  r = await demander(`${B}/api/relances/livraison`, { method: "POST", body: corpsFaux, headers: signer("msg_y", corpsFaux, Math.floor(Date.now() / 1000) - 600) });
  verifier("événement signé mais périmé (10 min) : refusé (401)", r.status === 401);
  r = await demander(`${B}/api/relances/livraison`, { method: "POST", body: corpsFaux });
  verifier("événement non signé : refusé (401)", r.status === 401);
  await evenement("msg_2", "email.bounced", re.fournisseur_id, "2026-11-02T19:12:00Z", { bounce: { message: "Mailbox does not exist" } });
  await evenement("msg_3", "email.delivered", re.fournisseur_id, "2026-11-02T19:13:00Z");
  const reb = relance("ESSAI-FAC-2026-0205");
  verifier("rejet définitif puis livraison tardive : « rejetée », motif conservé, rien effacé",
    reb.statut === "rejetee" && reb.rebond_motif === "Mailbox does not exist"
    && reb.livre_le?.startsWith("2026-11-02T19:00:20"));   // livraison antérieure conservée, la tardive (19 h 13) ignorée

  // Événement d'un email inconnu (aucune relance) et événement contradictoire (étiquette d'une relance refusée) : conservés.
  await evenement("msg_inconnu", "email.delivered", "em-inconnu-e2e", "2026-11-02T19:40:00Z");
  const corpsAl = JSON.stringify({ type: "email.delivered", created_at: "2026-11-02T19:41:00Z", data: { email_id: "em-autre-e2e", tags: [{ name: "relance_id", value: ri.id }] } });
  r = await demander(`${B}/api/relances/livraison`, { method: "POST", body: corpsAl, headers: signer("msg_alerte", corpsAl) });
  verifier("événement sur une relance refusée : 200, conservé en attente avec alerte, relance inchangée",
    r.status === 200 && (await r.json()).resultat === "en_attente"
    && /a été refusée par le fournisseur/.test(sql("select alerte from public.relances_evenements where evenement_id = 'msg_alerte'"))
    && relance("ESSAI-FAC-2026-0208").statut === "refusee");

  console.log("== Écran (administrateur) : simulation sans envoi, résolution");
  await facture("ESSAI-FAC-2026-0209", 12);
  const nav = await chromium.launch({ executablePath: "/opt/pw-browsers/chromium-1194/chrome-linux/chrome" });
  const page = await (await nav.newContext()).newPage();
  page.on("dialog", (d) => d.accept());
  await page.goto(B + "/connexion");
  await page.fill("#email", "sgi@gmx.fr"); await page.fill("#mot_de_passe", "Essai-Admin-2026!");
  await page.click("button[type=submit]");
  await page.waitForURL((u) => !u.pathname.startsWith("/connexion"));
  await page.goto(B + "/finance");
  let html = await page.content();
  verifier("Finance : lien « Relances » et limite « préparées mais NON activées » (texte)", html.includes('href="/finance/relances"')
    && html.includes("Relances automatiques des factures : préparées mais NON activées"));
  await page.goto(B + "/finance/relances");
  html = await page.content();
  verifier("écran : état de la configuration (présence seulement), sans aucune valeur secrète",
    (await page.locator("[data-etat-relances]").innerText()).includes("Clé du fournisseur : renseigné")
    && !SECRETS.some((s) => html.includes(s)));
  verifier("écran : relances réelles bloquées (domaine, expéditeur, signature)", (await page.locator("[data-blocages-reels] li").count()) === 3);
  verifier("écran : facture sans PDF et client sans email listés à part",
    (await page.locator("[data-sans-pdf]").textContent()).includes("ESSAI-FAC-2026-0202")
    && (await page.locator("[data-sans-email]").textContent()).includes("ESSAI-FAC-2026-0203"));
  verifier("écran : référence du compte fournisseur affichée (non secrète)",
    (await page.locator("[data-reference-compte]").innerText()).includes("resend-essai-1"));
  const attente = await page.locator("[data-evenements-attente]").innerText();
  verifier("écran : événements en attente listés (3), avec leurs alertes",
    (await page.locator("[data-evenement]").count()) === 3 && (await page.locator("[data-evenement] [data-alerte]").count()) === 2
    && attente.includes("Compte fournisseur différent") && attente.includes("a été refusée par le fournisseur"), attente.slice(0, 200));
  verifier("écran : boutons = simulation + « Classer sans suite » par événement (aucun bouton d'envoi, de réservation ou de modification d'échéance)",
    JSON.stringify(await page.locator("main button").allInnerTexts())
      === JSON.stringify(["Simuler les relances du jour (aucun envoi)", "Classer sans suite", "Classer sans suite", "Classer sans suite"]));
  for (const id of ["msg_inconnu", "msg_alerte", "msg_autre_compte"]) {
    await page.locator(`[data-evenement="${id}"] input[name=motif]`).fill("Essai : événement sans suite");
    await page.locator(`[data-evenement="${id}"] button`).click();
    await page.locator(`[data-evenement="${id}"]`).waitFor({ state: "detached" });
    await page.waitForSelector("[data-confirmation]");
  }
  verifier("classement par l'écran : 3 événements « sans suite » tracés (auteur, motif), aucune relance modifiée, aucun appel",
    sql("select count(*) from public.relances_evenements where statut = 'sans_suite' and classe_par is not null and motif_classement = 'Essai : événement sans suite'") === "3"
    && relance("ESSAI-FAC-2026-0208").statut === "refusee" && relance("ESSAI-FAC-2026-0201").rebond_le === null);
  verifier("écran : plus que le bouton de simulation", JSON.stringify(await page.locator("main button").allInnerTexts())
    === JSON.stringify(["Simuler les relances du jour (aucun envoi)"]));
  const avant = { relances: sql("select count(*) from public.relances"), demandes: (await etat()).demandes.length };
  await page.click("button:has-text('Simuler les relances du jour')");
  await page.waitForSelector("[data-simulation]");
  html = await page.content();
  verifier("simulation : message « rien n'a été réservé ni envoyé », relance n° 1 de 0209 présentée",
    html.includes("Simulation : rien n&#x27;a été réservé ni envoyé") || html.includes("Simulation : rien n'a été réservé ni envoyé"));
  verifier("simulation : objet du message affiché", (await page.locator('[data-simulation-facture="ESSAI-FAC-2026-0209"] [data-simulation-objet]').textContent())
    === "[ESSAI] Facture ESSAI-FAC-2026-0209 : rappel d'échéance");
  verifier("simulation : AUCUNE réservation, AUCUN appel au fournisseur",
    sql("select count(*) from public.relances") === avant.relances && (await etat()).demandes.length === avant.demandes);
  await page.goto(`${B}/finance/relances/${rh.id}`);
  verifier("fiche : relance à vérifier présentée comme bloquante, sans date d'envoi",
    (await page.content()).includes("bloque toute nouvelle relance") && (await page.locator("[data-date-envoi]").textContent()) === "—");
  verifier("fiche : seul bouton = enregistrer un constat (aucun renvoi)",
    JSON.stringify(await page.locator("main button").allInnerTexts()) === JSON.stringify(["Enregistrer la résolution"]));
  await page.selectOption("select[name=constat]", "aucun_envoi");
  await page.fill("input[name=motif]", "Aucun email visible chez le fournisseur");
  await page.click("button:has-text('Enregistrer la résolution')");
  await page.waitForSelector("[data-confirmation]");
  const rh2 = relance("ESSAI-FAC-2026-0207");
  verifier("résolution par l'écran : « abandonnée », tracée, aucun renvoi", rh2.statut === "abandonnee" && rh2.resolu_par !== null
    && (await etat()).demandes.length === avant.demandes);
  const collab = await (await nav.newContext()).newPage();
  await collab.goto(B + "/connexion");
  await collab.fill("#email", "collab@exemple.invalid"); await collab.fill("#mot_de_passe", "Essai-Collab-2026!");
  await collab.click("button[type=submit]");
  await collab.waitForURL((u) => !u.pathname.startsWith("/connexion"));
  await collab.goto(B + "/finance/relances");
  verifier("collaboratrice : écran des relances inaccessible (renvoyée à l'accueil)", new URL(collab.url()).pathname === "/");
  await nav.close();

  console.log("== Secrets");
  const tout = sql("select coalesce(string_agg(r::text, '|'), '') from public.relances r") + sql("select coalesce(string_agg(e::text, '|'), '') from public.relances_evenements e");
  verifier("aucun secret de l'essai dans les tables relances et relances_evenements", !SECRETS.some((s) => tout.includes(s)));
  const journal = readFileSync("/var/tmp/pg-essai/next.log", "utf8");
  verifier("aucun secret dans le journal du serveur", !SECRETS.some((s) => journal.includes(s)));
} finally {
  console.log("== Nettoyage");
  execFileSync("bash", [SERVEUR, "stop"], { stdio: "ignore" });
  imitation.kill();
  const net = JSON.parse(sql("select public.supprimer_essais_finance()"));
  // Événements sans lien avec une relance d'essai (classés « sans suite » par l'écran) : nettoyage à 30 jours (horloge simulée).
  sql("update relt.horloge set t = now() + interval '40 days'; select public.relances_purger_evenements();");
  for (const chemin of net.pdf_chemins) {
    await fetch(`${P}/storage/v1/object/factures`, { method: "DELETE", body: JSON.stringify({ prefixes: [chemin] }),
      headers: { Authorization: `Bearer ${SERVICE}`, apikey: SERVICE, "Content-Type": "application/json" } });
  }
  sql(`delete from public.clients where id in ('55555555-0000-0000-0000-00000000e2e1', '55555555-0000-0000-0000-00000000e2e2');
    create or replace function public.relances_maintenant()
returns timestamptz
language sql
stable
as $$
  select now();
$$;
    create or replace function public.relances_adresse_fictive(p_adresse text)
returns boolean
language sql
immutable
as $$
  select coalesce(lower(split_part(p_adresse, '@', 2)), '') ~
         '(^|\\.)(exemple\\.invalid|example\\.(com|net|org)|resend\\.dev)$|\\.(invalid|test|example|localhost)$|^localhost$|^$';
$$;
    drop schema relt cascade;`);
  verifier("heure réelle et règle des adresses fictives rétablies", sql("select md5(prosrc) from pg_proc where proname = 'relances_maintenant'") === DEF
    && sql("select public.relances_adresse_fictive('a@exemple.invalid')") === "t");
  verifier("aucun reste : relances, événements, factures d'essai, fichiers du bucket factures",
    sql("select (select count(*) from public.relances) + (select count(*) from public.relances_evenements) + (select count(*) from public.factures where essai) + (select count(*) from storage.objects where bucket_id = 'factures')") === "0");
  console.log(`\nBILAN : ${ok}/${ok + ko} contrôles réussis`);
}
