// Fiche collaborateur : taux obligatoire (base d'ESSAI locale uniquement).
// Usage : depuis scratchpad/essais (Playwright), après pile_locale.sh start et un build sur 127.0.0.1:54321.
import { chromium } from "playwright";
import { execFileSync } from "node:child_process";
const B = "http://127.0.0.1:3200";
const sql = (q) => execFileSync("psql", ["-h", "/var/tmp/pg-essai", "-p", "5499", "-U", "postgres", "-d", "essai", "-qAtX", "-c", q]).toString().trim();
let ok = 0, ko = 0;
const verifier = (l, c, d = "") => { c ? ok++ : ko++; console.log(`  [${c ? "OK " : "ÉCHEC"}] ${l}${d ? `  (${d})` : ""}`); };
const nav = await chromium.launch({ executablePath: "/opt/pw-browsers/chromium-1194/chrome-linux/chrome" });
const p = await (await nav.newContext()).newPage();
await p.goto(B + "/connexion"); await p.fill("#email", "sgi@gmx.fr"); await p.fill("#mot_de_passe", "Essai-Admin-2026!");
await p.click("button[type=submit]"); await p.waitForURL((u) => !u.pathname.startsWith("/connexion"));
await p.goto(B + "/utilisateurs");
const form = p.locator("form", { has: p.locator("button:has-text('Créer la fiche')") });
const champ = form.locator("[name=taux_horaire]");
verifier("champ taux : vide au départ (aucune valeur proposée)", (await champ.inputValue()) === "");
verifier("champ taux : marqué obligatoire", (await champ.getAttribute("required")) !== null);
const avant = sql("select count(*) from public.collaborateurs");
const essai = async (nom, taux, attendu) => {
  await form.locator("[name=nom]").fill(nom);
  await champ.evaluate((e) => e.removeAttribute("required")); // contournement volontaire du navigateur
  await champ.evaluate((e, v) => { e.type = "text"; e.value = v; }, taux);
  await form.locator("button:has-text('Créer la fiche')").click();
  await p.waitForSelector(`text=${attendu}`, { timeout: 20000 });
};
await essai("Taux-Vide", "", "Le taux horaire est obligatoire");
verifier("taux vide (contrôle du navigateur contourné) : message clair, aucune fiche créée", sql("select count(*) from public.collaborateurs") === avant);
await p.reload();
await essai("Taux-Trois-Decimales", "85,505", "au plus 2 décimales");
verifier("taux à 3 décimales : refusé avec un message, aucune fiche créée", sql("select count(*) from public.collaborateurs") === avant);
await p.reload();
await essai("Taux-Zero-Explicite", "0", "Fiche créée");
verifier("taux 0 saisi volontairement : accepté", sql("select taux_horaire from public.collaborateurs where nom = 'Taux-Zero-Explicite'") === "0.00");
await p.reload();
await essai("Taux-Normal", "85,50", "Fiche créée");
verifier("taux 85,50 : enregistré tel quel", sql("select taux_horaire from public.collaborateurs where nom = 'Taux-Normal'") === "85.50");
verifier("aucune erreur SQL brute affichée", !(await p.content()).match(/violates|null value|SQLSTATE|23502/));
sql("delete from public.collaborateurs where nom in ('Taux-Zero-Explicite', 'Taux-Normal')");
await nav.close();
console.log(`\nBILAN : ${ok}/${ok + ko} contrôles réussis`);
