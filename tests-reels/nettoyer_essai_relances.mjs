// Nettoyage COMPLET après le premier essai de relance (à lancer seulement sur accord, après l'essai).
// Ordre : essais Finance (facture d'essai, ses relances et événements, compteur d'essai) → essais RH (temps) → fiche
// jetable → essais Commercial (prospect, devis, client, projet, compteur) → fichiers PDF (factures, devis).
// Lit le fichier d'état écrit par preparer_facture_essai_relances.mjs ; ne touche à rien d'autre.
// Usage : NODE_USE_ENV_PROXY=1 NODE_EXTRA_CA_CERTS=/root/.ccr/ca-bundle.crt node nettoyer_essai_relances.mjs <etat.json>
import { readFileSync } from "node:fs";

const etat = JSON.parse(readFileSync(process.argv[2], "utf8"));
const U = process.env.NEXT_PUBLIC_SUPABASE_URL, S = process.env.SUPABASE_SERVICE_ROLE_KEY;
let ok = 0, ko = 0;
const verifier = (l, c, d = "") => { c ? ok++ : ko++; console.log(`  [${c ? "OK " : "ÉCHEC"}] ${l}${d ? `  (${d})` : ""}`); };
async function api(m, p, c) {
  const r = await fetch(U + p, { method: m, headers: { apikey: S, Authorization: `Bearer ${S}`, "Content-Type": "application/json", Prefer: "return=representation" },
    body: c === undefined ? undefined : JSON.stringify(c) });
  const t = await r.text(); let d = null; try { d = t ? JSON.parse(t) : null; } catch { d = t; }
  return { s: r.status, d };
}
const rpc = (f, a = {}) => api("POST", `/rest/v1/rpc/${f}`, a);

const nf = await rpc("supprimer_essais_finance");
verifier("essais Finance supprimés (facture, relances, événements, compteur d'essai)", nf.s === 200, JSON.stringify(nf.d));
for (const chemin of nf.d?.pdf_chemins ?? []) await api("DELETE", "/storage/v1/object/factures", { prefixes: [chemin] });
const nt = await rpc("supprimer_essais_rh");
verifier("temps d'essai supprimés", nt.s === 200, `${JSON.stringify(nt.d)}`);
for (const id of etat.fiches) {
  const r = await api("DELETE", `/rest/v1/collaborateurs?id=eq.${id}`);
  verifier(`fiche jetable ${id.slice(0, 8)}… supprimée`, r.s < 400 && r.d?.length === 1, r.d?.message ?? "");
}
const nc = await rpc("supprimer_essais_commercial");
verifier("essais Commercial supprimés (prospect, devis, client, projet)", nc.s === 200, JSON.stringify(nc.d));
for (const chemin of nc.d?.pdf_chemins ?? []) await api("DELETE", "/storage/v1/object/devis", { prefixes: [chemin] });

console.log("== Contrôle : aucun reste");
const compte = async (p) => (await api("GET", p)).d?.length ?? -1;
const fichiers = async (b) => (await api("POST", `/storage/v1/object/list/${b}`, { prefix: "", limit: 1000 })).d?.length ?? -1;
const restes = {
  factures: await compte("/rest/v1/factures?select=id"), relances: await compte("/rest/v1/relances?select=id"),
  evenements: await compte("/rest/v1/relances_evenements?select=evenement_id"), compteurs: await compte("/rest/v1/compteurs?select=cle"),
  temps_essai: await compte(`/rest/v1/temps?select=id&projet_id=eq.${etat.projet}`),
  fiches_jetables: await compte("/rest/v1/collaborateurs?select=id&email=like.*exemple.invalid"),
  clients_essai: await compte("/rest/v1/clients?select=id&nom=like.*ESSAI*"), projets_essai: await compte("/rest/v1/projets?select=id&nom=like.*ESSAI*"),
  prospects_essai: await compte("/rest/v1/prospects?select=id&essai=is.true"), devis_essai: await compte("/rest/v1/devis?select=id&essai=is.true"),
  comptes_jetables: (await api("GET", "/auth/v1/admin/users?per_page=1000")).d.users.filter((u) => u.email.endsWith("@exemple.invalid")).length,
  fichiers_factures: await fichiers("factures"), fichiers_devis: await fichiers("devis"),
};
verifier("aucun reste (factures, relances, événements, compteurs, essais, comptes, fichiers)", Object.values(restes).every((n) => n === 0), JSON.stringify(restes));
console.log(`\nBILAN : ${ok}/${ok + ko} contrôles réussis`);
