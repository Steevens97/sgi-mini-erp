// Test de bout en bout de l'écran Utilisateurs avec des comptes et fiches jetables.
// Usage : node ecran_utilisateurs.mjs <url de base>
import { chromium } from "playwright";

const B = process.argv[2] ?? "http://localhost:3100";
const U = process.env.NEXT_PUBLIC_SUPABASE_URL;
const S = process.env.SUPABASE_SERVICE_ROLE_KEY;
const t = Date.now();
const DOM = "@exemple.invalid";
const MDP_ADMIN = "Jetable-Admin-2026!";
const emailAdmin = `jetable-admin-${t}${DOM}`;
const emailCollab = `jetable-collab-${t}${DOM}`;
let ok = 0, ko = 0;
const verifier = (libelle, cond, detail = "") => {
  cond ? ok++ : ko++;
  console.log(`  [${cond ? "OK " : "ÉCHEC"}] ${libelle}${detail ? `  (${detail})` : ""}`);
};
const api = async (methode, chemin, corps) => {
  const r = await fetch(U + chemin, {
    method: methode,
    headers: { apikey: S, Authorization: `Bearer ${S}`, "Content-Type": "application/json", Prefer: "return=representation" },
    body: corps ? JSON.stringify(corps) : undefined,
  });
  const txt = await r.text();
  return txt ? JSON.parse(txt) : null;
};
const profil = async (email) => (await api("GET", `/rest/v1/profiles?email=eq.${encodeURIComponent(email)}&select=*`))[0];
const compteAuth = async (email) =>
  (await api("GET", "/auth/v1/admin/users?per_page=1000")).users.find((u) => u.email === email);

const nav = await chromium.launch({
  executablePath: "/opt/pw-browsers/chromium-1194/chrome-linux/chrome",
  ...(B.startsWith("https") ? { proxy: { server: process.env.HTTPS_PROXY } } : {}),
});
const seConnecter = async (page, email, mdp) => {
  await page.goto(B + "/connexion");
  await page.fill("#email", email);
  await page.fill("#mot_de_passe", mdp);
  await page.click("button[type=submit]");
  await Promise.race([
    page.waitForURL((u) => !u.pathname.startsWith("/connexion"), { timeout: 30000 }),
    page.waitForSelector("form [role=alert]", { timeout: 30000 }),
  ]);
};
const ligne = (page, texte) => page.locator("tbody tr", { hasText: texte });

try {
  console.log(`Site testé : ${B}\n\n== Préparation : un admin jetable (créé avec la clé secrète)`);
  const a = await api("POST", "/auth/v1/admin/users", { email: emailAdmin, password: MDP_ADMIN, email_confirm: true });
  await api("PATCH", `/rest/v1/profiles?id=eq.${a.id}`, { role: "admin" });

  const admin = await (await nav.newContext()).newPage();
  admin.on("dialog", (d) => d.accept());
  await seConnecter(admin, emailAdmin, MDP_ADMIN);
  await admin.goto(B + "/utilisateurs");
  verifier("l'admin ouvre l'écran Utilisateurs", (await admin.textContent("h1")) === "Utilisateurs");
  const lignes = await admin.locator("tbody tr").count();
  verifier("les fiches existantes sont listées", lignes >= 3, `${lignes} ligne(s)`);
  const blocSgi = admin.locator("li", { hasText: "sgi@gmx.fr" });
  verifier("sgi@gmx.fr apparaît parmi les comptes sans fiche", (await blocSgi.count()) === 1);
  verifier("aucun bouton Révoquer/Changer le rôle pour sgi@gmx.fr",
    (await blocSgi.locator("text=Révoquer").count()) === 0 && (await blocSgi.locator("text=Changer le rôle").count()) === 0);

  console.log("\n== Fiche personnelle de l'admin, rattachée à son compte");
  verifier("bandeau « non rattaché » visible avant", (await admin.locator("[role=alert]", { hasText: "Compte non rattaché à une fiche" }).count()) === 1);
  const formFiche = admin.locator("form", { hasText: "Rattacher cette fiche à mon compte" });
  await formFiche.locator("[name=prenom]").fill("Admin");
  await formFiche.locator("[name=nom]").fill(`Jetable-${t}`);
  await formFiche.locator("[name=email]").fill(emailAdmin);
  await formFiche.locator("[name=poste]").fill("Test");
  await formFiche.locator("[name=rattacher_a_mon_compte]").check();
  await formFiche.locator("button[type=submit]").click();
  await admin.waitForSelector("text=Fiche créée et rattachée à votre compte.");
  await admin.reload();
  verifier("fiche créée et rattachée : bandeau disparu", (await admin.locator("[role=alert]", { hasText: "Compte non rattaché à une fiche" }).count()) === 0);
  const pa = await profil(emailAdmin);
  verifier("profil de l'admin pointe vers sa nouvelle fiche", !!pa.collaborateur_id);
  verifier("sa ligne indique « Votre compte » sans action dangereuse",
    (await ligne(admin, `Jetable-${t}`).locator("text=Votre compte").count()) === 1);

  console.log("\n== Création d'une fiche + « Créer l'accès » (collaborateur)");
  await formFiche.locator("[name=prenom]").fill("Collab");
  await formFiche.locator("[name=nom]").fill(`Jetable2-${t}`);
  await formFiche.locator("[name=email]").fill(emailCollab);
  await formFiche.locator("button[type=submit]").click();
  await admin.waitForSelector("text=Fiche créée.");
  await admin.reload();
  const lc = ligne(admin, `Jetable2-${t}`);
  verifier("état : « Aucun accès »", (await lc.locator("text=Aucun accès").count()) === 1);
  await lc.locator("select[name=role]").selectOption("collaborateur");
  await lc.locator("text=Créer l'accès").click();
  await admin.waitForSelector("[data-mot-de-passe]");
  const mdpProvisoire = (await admin.textContent("[data-mot-de-passe]")).trim();
  verifier("mot de passe provisoire affiché une fois", /^[A-Za-z0-9]{4}-[A-Za-z0-9]{4}-[A-Za-z0-9]{4}$/.test(mdpProvisoire));
  verifier("identifiant = email de la fiche", (await admin.locator("strong", { hasText: emailCollab }).count()) === 1);
  await admin.click("text=J'ai transmis le mot de passe, masquer");
  verifier("mot de passe masqué après confirmation", (await admin.locator("[data-mot-de-passe]").count()) === 0);
  await admin.reload();
  verifier("mot de passe introuvable après rechargement", !(await admin.content()).includes(mdpProvisoire));
  const pc = await profil(emailCollab);
  const ac = await compteAuth(emailCollab);
  verifier("profil créé : rôle collaborateur + rattaché à la fiche", pc?.role === "collaborateur" && !!pc?.collaborateur_id);
  verifier("compte confirmé + obligation de changer le mot de passe",
    !!ac?.email_confirmed_at && ac?.app_metadata?.doit_changer_mot_de_passe === true);
  verifier("état : « Mot de passe provisoire à remplacer »",
    (await ligne(admin, `Jetable2-${t}`).locator("text=Mot de passe provisoire à remplacer").count()) === 1);

  console.log("\n== Première connexion du collaborateur");
  const collab = await (await nav.newContext()).newPage();
  await seConnecter(collab, emailCollab, mdpProvisoire);
  verifier("redirigé vers le changement de mot de passe", collab.url().endsWith("/changer-mot-de-passe"), collab.url());
  for (const p of ["/", "/rh", "/absences"]) {
    await collab.goto(B + p);
    verifier(`  ${p} bloqué tant que le mot de passe n'est pas changé`, collab.url().endsWith("/changer-mot-de-passe"));
  }
  await collab.fill("#nouveau", mdpProvisoire);
  await collab.fill("#confirmation", mdpProvisoire);
  await collab.click("button[type=submit]");
  await collab.waitForSelector("form [role=alert]");
  verifier("réutiliser le mot de passe provisoire est refusé", (await collab.textContent("form [role=alert]")).includes("différent"),
    await collab.textContent("form [role=alert]"));
  const MDP_COLLAB = "Nouveau-Collab-2026!";
  await collab.fill("#nouveau", MDP_COLLAB);
  await collab.fill("#confirmation", MDP_COLLAB);
  await collab.click("button[type=submit]");
  await collab.waitForURL(B + "/");
  verifier("nouveau mot de passe accepté → Accueil", collab.url() === B + "/");
  verifier("obligation levée", (await compteAuth(emailCollab)).app_metadata?.doit_changer_mot_de_passe === false);
  await collab.goto(B + "/rh");
  const vues = await collab.locator("ul li").allTextContents();
  verifier("le collaborateur ne voit qu'UNE fiche (la sienne)", vues.length === 1 && vues[0].includes(`Jetable2-${t}`), vues.join(" / "));
  const menu = await collab.$$eval("aside nav a", (l) => l.map((x) => x.textContent).join(" | "));
  verifier("menu sans Finance ni Utilisateurs", menu === "Accueil | Commercial | RH | Absences", menu);

  console.log("\n== Un non-admin qui appelle directement une action serveur d'admin");
  // On capture la requête que l'admin enverrait (sans la laisser partir), puis on la rejoue
  // avec la session du collaborateur.
  let capture = null;
  await admin.route("**/utilisateurs", async (route) => {
    const req = route.request();
    if (req.method() === "POST" && !capture) {
      capture = { headers: req.headers(), body: req.postDataBuffer() };
      return route.abort();
    }
    return route.continue();
  });
  const lc2 = ligne(admin, `Jetable2-${t}`);
  await lc2.locator("select[name=role]").selectOption("admin");
  await lc2.locator("text=Changer le rôle").click();
  await admin.waitForTimeout(1500);
  await admin.unroute("**/utilisateurs");
  verifier("requête « passer admin » capturée (non envoyée)", !!capture && (await profil(emailCollab)).role === "collaborateur");
  const entetes = Object.fromEntries(Object.entries(capture.headers).filter(([k]) => !["cookie", "content-length", "host"].includes(k)));
  const rep = await collab.context().request.post(B + "/utilisateurs", { headers: entetes, data: capture.body, maxRedirects: 0 });
  verifier("rejouée par le collaborateur : sans effet", (await profil(emailCollab)).role === "collaborateur", `HTTP ${rep.status()}`);

  console.log("\n== Actions de l'admin sur le compte du collaborateur");
  await admin.reload();
  const lc3 = ligne(admin, `Jetable2-${t}`);
  await lc3.locator("select[name=role]").selectOption("manager");
  await lc3.locator("text=Changer le rôle").click();
  await admin.waitForSelector("text=changé en « manager »");
  verifier("rôle changé en manager", (await profil(emailCollab)).role === "manager");
  await collab.goto(B + "/rh");
  const vuesManager = await collab.locator("ul li").count();
  verifier("devenu manager, il voit toutes les fiches", vuesManager >= 4, `${vuesManager} fiche(s)`);
  await admin.reload();
  await ligne(admin, `Jetable2-${t}`).locator("select[name=role]").selectOption("collaborateur");
  await ligne(admin, `Jetable2-${t}`).locator("text=Changer le rôle").click();
  await admin.waitForSelector("text=changé en « collaborateur »");
  verifier("rôle remis à collaborateur", (await profil(emailCollab)).role === "collaborateur");

  await admin.reload();
  await ligne(admin, `Jetable2-${t}`).locator("text=Réinitialiser le mot de passe").click();
  await admin.waitForSelector("[data-mot-de-passe]");
  const mdp2 = (await admin.textContent("[data-mot-de-passe]")).trim();
  verifier("réinitialisation : nouveau mot de passe provisoire", mdp2 !== mdpProvisoire);
  const collab2 = await (await nav.newContext()).newPage();
  await seConnecter(collab2, emailCollab, MDP_COLLAB);
  verifier("l'ancien mot de passe ne marche plus", collab2.url().endsWith("/connexion"));
  await seConnecter(collab2, emailCollab, mdp2);
  verifier("le provisoire impose de nouveau le changement", collab2.url().endsWith("/changer-mot-de-passe"), collab2.url());
  await collab.goto(B + "/rh");
  verifier("la session déjà ouverte n'accède plus à /rh",
    collab.url().endsWith("/changer-mot-de-passe") || collab.url().endsWith("/connexion"), collab.url());

  console.log("\n== Garde-fous vérifiés côté serveur (formulaire modifié à la main)");
  await admin.reload();
  const idSgi = (await profil("sgi@gmx.fr")).id;
  const essaiForce = async (bouton, idCible, attendu, libelle) => {
    await admin.reload();
    const l = ligne(admin, `Jetable2-${t}`);
    const form = l.locator("form", { has: admin.locator(`text=${bouton}`) });
    await form.locator("input[name=profil_id]").evaluate((e, v) => (e.value = v), idCible);
    await form.locator(`text=${bouton}`).click();
    await admin.waitForSelector(`text=${attendu}`, { timeout: 15000 }).catch(() => null);
    verifier(libelle, (await admin.locator(`text=${attendu}`).count()) >= 1);
  };
  await essaiForce("Révoquer l'accès", idSgi, "Ce compte est protégé", "révoquer sgi@gmx.fr : refusé");
  await essaiForce("Changer le rôle", idSgi, "Ce compte est protégé", "changer le rôle de sgi@gmx.fr : refusé");
  await essaiForce("Réinitialiser le mot de passe", idSgi, "Ce compte est protégé", "réinitialiser sgi@gmx.fr : refusé");
  await essaiForce("Révoquer l'accès", a.id, "Vous ne pouvez pas révoquer votre propre accès", "l'admin se révoque lui-même : refusé");
  await essaiForce("Changer le rôle", a.id, "Vous ne pouvez pas modifier votre propre rôle", "l'admin change son propre rôle : refusé");
  const ps = await profil("sgi@gmx.fr");
  verifier("sgi@gmx.fr intact (admin)", ps.role === "admin" && !!(await compteAuth("sgi@gmx.fr")));

  console.log("\n== Révocation de l'accès du collaborateur");
  await admin.reload();
  await ligne(admin, `Jetable2-${t}`).locator("text=Révoquer l'accès").click();
  await admin.waitForSelector("text=La fiche collaborateur est conservée");
  verifier("compte supprimé", !(await compteAuth(emailCollab)));
  const ficheRestante = await api("GET", `/rest/v1/collaborateurs?email=eq.${encodeURIComponent(emailCollab)}&select=id`);
  verifier("fiche collaborateur conservée", ficheRestante.length === 1);
  await admin.reload();
  verifier("état revenu à « Aucun accès »", (await ligne(admin, `Jetable2-${t}`).locator("text=Aucun accès").count()) === 1);
  await collab.goto(B + "/rh");
  verifier("la session du compte révoqué est coupée", collab.url().endsWith("/connexion"), collab.url());
} catch (e) {
  ko++;
  console.log("  [ÉCHEC] erreur inattendue :", e.message.split("\n")[0]);
} finally {
  await nav.close();
  // Nettoyage : comptes jetables de ce passage, puis leurs fiches (jamais sgi@gmx.fr ni une fiche réelle).
  for (const email of [emailAdmin, emailCollab]) {
    const u = await compteAuth(email);
    if (u) await api("DELETE", `/auth/v1/admin/users/${u.id}`);
    await api("DELETE", `/rest/v1/collaborateurs?email=eq.${encodeURIComponent(email)}`);
  }
  const restes = (await api("GET", `/rest/v1/collaborateurs?select=nom&email=like.*${encodeURIComponent(DOM)}`)) ?? [];
  const comptes = (await api("GET", "/auth/v1/admin/users?per_page=1000")).users.filter((u) => u.email.endsWith(DOM));
  restes.length || comptes.length ? ko++ : ok++;
  console.log(`  [${restes.length || comptes.length ? "ÉCHEC" : "OK "}] nettoyage : aucune fiche ni aucun compte jetable restant`
    + `  (${restes.length} fiche(s), ${comptes.length} compte(s))`);
  console.log(`\nBILAN : ${ok}/${ok + ko} contrôles réussis`);
}
