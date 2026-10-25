// Parcours Relances EN PRODUCTION (après le temps 2, envois DÉSACTIVÉS) : comptes jetables seulement, AUCUN email,
// aucune réservation, aucun appel au fournisseur (aucune clé n'est configurée), aucune donnée créée hors des comptes.
// - Admin : écran Finance → Relances (relances NON activées, configuration absente, relances réelles bloquées, un seul
//   bouton : la simulation) ; simulation : message « rien n'a été réservé ni envoyé », tables relances et
//   relances_evenements inchangées.
// - Manager et collaboratrice : écran et fiche refusés (renvoi à l'accueil).
// - Routes /api/relances/* sans secret : 401, sans redirection vers la connexion.
// - Nettoyage : comptes supprimés et vérifiés.
// Usage : NODE_USE_ENV_PROXY=1 NODE_EXTRA_CA_CERTS=/root/.ccr/ca-bundle.crt node parcours_relances_en_ligne.mjs <url>
import { chromium } from "playwright";
import { randomUUID } from "node:crypto";

const B = process.argv[2] ?? "https://sgi-mini-erp.vercel.app";
const U = process.env.NEXT_PUBLIC_SUPABASE_URL, S = process.env.SUPABASE_SERVICE_ROLE_KEY;
const T = Date.now(), DOM = "@exemple.invalid", MDP = "Rel-Jetable-2026!";
let ok = 0, ko = 0;
const verifier = (l, c, d = "") => { c ? ok++ : ko++; console.log(`  [${c ? "OK " : "ÉCHEC"}] ${l}${d ? `  (${d})` : ""}`); };
async function api(m, p, c) {
  const r = await fetch(U + p, { method: m, headers: { apikey: S, Authorization: `Bearer ${S}`, "Content-Type": "application/json", Prefer: "return=representation" },
    body: c === undefined ? undefined : JSON.stringify(c) });
  const t = await r.text(); let d = null; try { d = t ? JSON.parse(t) : null; } catch { d = t; }
  return { s: r.status, d };
}
const etatTables = async () => JSON.stringify([(await api("GET", "/rest/v1/relances?select=*")).d, (await api("GET", "/rest/v1/relances_evenements?select=*")).d]);

const nav = await chromium.launch({ executablePath: "/opt/pw-browsers/chromium-1194/chrome-linux/chrome",
  ...(process.env.HTTPS_PROXY && !B.startsWith("http://127.0.0.1") ? { proxy: { server: process.env.HTTPS_PROXY } } : {}) });
async function connexion(email) {
  const page = await (await nav.newContext({ ignoreHTTPSErrors: true })).newPage();
  page.on("dialog", (d) => d.accept());
  await page.goto(B + "/connexion"); await page.fill("#email", email); await page.fill("#mot_de_passe", MDP);
  await page.click("button[type=submit]"); await page.waitForURL((u) => !u.pathname.startsWith("/connexion"), { timeout: 30000 });
  return page;
}

const comptes = [];
try {
  console.log("== 0. Comptes jetables (admin, manager, collaboratrice)");
  const compte = async (nom, role) => {
    const email = `jetable-rel-${nom}-${T}${DOM}`;
    const r = await api("POST", "/auth/v1/admin/users", { email, password: MDP, email_confirm: true });
    await api("PATCH", `/rest/v1/profiles?id=eq.${r.d.id}`, { role, nom: `Jetable ${nom}` });
    comptes.push(r.d.id); return email;
  };
  const A = await compte("admin", "admin"), M = await compte("manager", "manager"), C = await compte("collab", "collaborateur");
  const avant = await etatTables();

  console.log("== 1. Routes sans secret");
  for (const [libelle, chemin, options] of [
    ["exécution sans en-tête", "/api/relances/executer", { method: "POST" }],
    ["exécution, secret faux", "/api/relances/executer", { method: "POST", headers: { Authorization: `Bearer ${randomUUID()}${randomUUID()}` } }],
    ["événement non signé", "/api/relances/livraison", { method: "POST", body: "{}", headers: { "Content-Type": "application/json" } }],
  ]) {
    const r = await fetch(B + chemin, { ...options, redirect: "manual" });
    verifier(`${libelle} : 401, sans redirection vers la connexion`, r.status === 401 && !r.headers.get("location"), `HTTP ${r.status}`);
  }

  console.log("== 2. Administrateur : écran et simulation");
  const pa = await connexion(A);
  await pa.goto(B + "/finance");
  verifier("Finance : lien « Relances »", (await pa.content()).includes('href="/finance/relances"'));
  await pa.goto(B + "/finance/relances");
  const html = await pa.content();
  verifier("relances NON activées (bandeau)", (await pa.locator("[data-etat-relances]").getAttribute("data-etat-relances")) === "inactives"
    && (html.includes("aucun email n&#x27;est envoyé") || html.includes("aucun email n'est envoyé")));
  const etat = await pa.locator("[data-etat-relances]").innerText();
  verifier("configuration : clé, secret partagé, signature, adresse de test et référence ABSENTS",
    ["Clé du fournisseur : absent", "Secret partagé avec la tâche planifiée : absent", "Secret de signature des événements de livraison : absent",
     "Adresse de test confirmée (essais) : absent", "Référence du compte fournisseur (non secrète) : absente"].every((x) => etat.includes(x)), etat.replace(/\n/g, " | "));
  verifier("relances réelles bloquées (3 raisons)", (await pa.locator("[data-blocages-reels] li").count()) === 3);
  verifier("aucun événement en attente", (await pa.locator("[data-evenement]").count()) === 0);
  verifier("un seul bouton : la simulation (aucun envoi, aucune réservation, aucune modification d'échéance)",
    JSON.stringify(await pa.locator("main button").allInnerTexts()) === JSON.stringify(["Simuler les relances du jour (aucun envoi)"]));
  await pa.click("button:has-text('Simuler les relances du jour')");
  await pa.waitForSelector("[data-simulation]");
  const sim = await pa.locator("[data-simulation] [role=status]").innerText();
  verifier("simulation : « rien n'a été réservé ni envoyé »", sim.includes("rien n'a été réservé ni envoyé"), sim);
  verifier("simulation : tables relances et relances_evenements inchangées (aucune réservation, aucune écriture)", (await etatTables()) === avant);
  await pa.goto(`${B}/finance/relances/${randomUUID()}`);
  verifier("fiche d'une relance inexistante : introuvable (404)", (await pa.content()).includes("404") || (await pa.title()).includes("404"));

  console.log("== 3. Manager et collaboratrice : accès refusé");
  for (const [qui, email] of [["manager", M], ["collaboratrice", C]]) {
    const p = await connexion(email);
    await p.goto(B + "/finance/relances");
    verifier(`${qui} : écran des relances refusé (renvoi à l'accueil)`, new URL(p.url()).pathname === "/", p.url());
    await p.goto(`${B}/finance/relances/${randomUUID()}`);
    verifier(`${qui} : fiche refusée (renvoi à l'accueil)`, new URL(p.url()).pathname === "/", p.url());
    await p.context().close();
  }
  verifier("après tout le parcours : tables relances et relances_evenements inchangées", (await etatTables()) === avant);
} catch (e) {
  verifier(`erreur inattendue : ${e.message}`, false);
} finally {
  console.log("== Nettoyage");
  await nav.close();
  for (const id of comptes) await api("DELETE", `/auth/v1/admin/users/${id}`);
  const restes = (await api("GET", "/auth/v1/admin/users?per_page=1000")).d.users.filter((u) => u.email.endsWith(DOM)).length;
  verifier("comptes jetables supprimés (aucun compte @exemple.invalid restant)", restes === 0, `${restes}`);
  console.log(`\nBILAN : ${ok}/${ok + ko} contrôles réussis`);
}
