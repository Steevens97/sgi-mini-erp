// Tests du PDF et de l'archivage, hors Next.js, stockage et base SIMULÉS.
// Usage : node --experimental-strip-types tests-reels/tests_pdf_archivage.mts
import { genererPdfDevis, type InstantaneDevis } from "../src/lib/devis/pdf.ts";
import { archiverPdfDevis, empreinteSha256, lireArchiveVerifiee, type BaseDevis, type StockageDevis } from "../src/lib/devis/archivage.ts";

let ok = 0, ko = 0;
const verifier = (libelle: string, cond: boolean, detail = "") => {
  cond ? ok++ : ko++;
  console.log(`  [${cond ? "OK " : "ÉCHEC"}] ${libelle}${detail ? `  (${detail})` : ""}`);
};
import { inflateSync } from "node:zlib";
// Le texte des pages est compressé (FlateDecode) et écrit en hexadécimal : on décompresse chaque flux.
const hex = (s: string) => Buffer.from(s, "latin1").toString("hex").toUpperCase();
function contenuPages(pdf: Uint8Array): string {
  const brut = Buffer.from(pdf);
  const morceaux: string[] = [];
  let i = 0;
  for (;;) {
    const debut = brut.indexOf("stream\n", i);
    if (debut < 0) break;
    const fin = brut.indexOf("\nendstream", debut);
    const flux = brut.subarray(debut + 7, fin);
    try { morceaux.push(inflateSync(flux).toString("latin1")); } catch { morceaux.push(flux.toString("latin1")); }
    i = fin + 10;
  }
  return morceaux.join("\n").toUpperCase();
}
const contient = (pdf: Uint8Array, texte: string) => contenuPages(pdf).includes(hex(texte));

const instantane: InstantaneDevis = {
  essai: false, gabarit: "devis-v1", numero: "DEV-2026-0001", date_emission: "2026-10-23",
  emetteur: { raison_sociale: "[DÉMO] SG Ingénierie", forme_juridique: "SAS", capital_social: "[DÉMO]",
    adresse: "[DÉMO] adresse", code_postal: "97200", ville: "Fort-de-France", siret: "00000000000000",
    immatriculation: "[DÉMO]", tva_intracom: "[DÉMO]", validite_jours: "30", assurance_assureur: "[DÉMO]",
    assurance_contrat: "[DÉMO]", assurance_couverture: "[DÉMO]" },
  destinataire: { prospect: { nom: "Mme Client", societe: "BTP Caraïbes", adresse: "12 rue des Essais",
    code_postal: "97200", ville: "Fort-de-France", pays: "MQ" } },
  lignes: Array.from({ length: 45 }, (_, i) => ({ designation: `Ligne ${i + 1} — étude « structure » avec un texte long qui doit passer à la ligne sans casser`, quantite: 1.5, prix_unitaire: 1234.5, montant_ht: 1851.75 })),
  totaux: { total_ht: 83328.75, tva: 7082.94, total_ttc: 90411.69 },
  tva: { regime: "taxable", territoire: "MQ", pays: null, taux: 8.5, mention: null },
};
const date = new Date("2026-10-23T14:00:00Z");

console.log("== PDF");
const a = await genererPdfDevis(instantane, { filigrane: null, dateDocument: date });
const b = await genererPdfDevis(instantane, { filigrane: null, dateDocument: date });
verifier("même instantané → même fichier, octet pour octet", (await empreinteSha256(a)) === (await empreinteSha256(b)), `${a.length} octets`);
verifier("plusieurs pages pour 45 lignes", Buffer.from(a).toString("latin1").split("/Type /Page\n").length - 1 >= 2 || Buffer.from(a).toString("latin1").match(/\/Type \/Page[^s]/g)!.length >= 2);
verifier("numéro imprimé", contient(a, "DEVIS DEV-2026-0001"));
const brouillon = await genererPdfDevis({ ...instantane, numero: null }, { filigrane: "BROUILLON — NON ÉMIS", dateDocument: date });
verifier("brouillon : filigrane « BROUILLON — NON ÉMIS », sans numéro", contient(brouillon, "BROUILLON") && !contient(brouillon, "DEV-2026"));
const essai = await genererPdfDevis({ ...instantane, essai: true }, { filigrane: "ESSAI — SANS VALEUR", dateDocument: date });
verifier("devis d'essai : filigrane « ESSAI — SANS VALEUR »", contient(essai, "ESSAI"));
const avenant = await genererPdfDevis({ ...instantane, avenant_de: "DEV-2026-0001", numero: "DEV-2026-0009",
  totaux: { total_ht: -1500, tva: -127.5, total_ttc: -1627.5 }, lignes: [{ designation: "Suppression", quantite: -1, prix_unitaire: 1500, montant_ht: -1500 }] },
  { filigrane: null, dateDocument: date });
verifier("avenant négatif : « Moins-value » et référence au devis initial", contient(avenant, "Moins-value") && contient(avenant, "au devis DEV-2026-0001"));
const remplacant = await genererPdfDevis({ ...instantane, numero: "DEV-2026-0002", remplace: "DEV-2026-0001" }, { filigrane: null, dateDocument: date });
verifier("nouvelle version : « Annule et remplace le devis … »", contient(remplacant, "Annule et remplace le devis DEV-2026-0001"));

console.log("== Archivage (stockage et base simulés)");
function simulation() {
  const fichiers = new Map<string, Uint8Array>();
  const etat = { statut: "a_generer", empreinte: "", appelsEnregistrer: 0, echecs: [] as string[], panneEnregistrement: 0, panneStockage: 0 };
  const stockage: StockageDevis = {
    async deposer(chemin, contenu) {
      await new Promise((r) => setTimeout(r, 5));
      if (etat.panneStockage > 0) { etat.panneStockage--; throw new Error("stockage indisponible"); }
      if (fichiers.has(chemin)) return "existe";
      fichiers.set(chemin, contenu);
      return "depose";
    },
    async lire(chemin) { return fichiers.get(chemin) ?? null; },
  };
  const base: BaseDevis = {
    async enregistrer(_id, _chemin, empreinte, taille) {
      etat.appelsEnregistrer++;
      if (etat.panneEnregistrement > 0) { etat.panneEnregistrement--; throw new Error("enregistrement de l'état interrompu"); }
      if (![..._chemin].length || taille <= 0) throw new Error("taille");
      // comme enregistrer_pdf_devis : même empreinte = sans effet ; autre empreinte = refus
      if (etat.statut === "disponible" && etat.empreinte !== empreinte) throw new Error("Un PDF différent est déjà archivé");
      etat.statut = "disponible"; etat.empreinte = empreinte;
    },
    async signalerEchec(_id, message) { if (etat.statut !== "disponible") { etat.statut = "echec"; etat.echecs.push(message); } },
  };
  return { fichiers, etat, stockage, base };
}
const devis = { id: "d1", numero: "DEV-2026-0001" };
const generer = () => genererPdfDevis(instantane, { filigrane: null, dateDocument: date });

{
  const s = simulation();
  const r = await archiverPdfDevis(devis, generer, s.stockage, s.base);
  verifier("cas normal : déposé puis déclaré disponible", r.statut === "disponible" && s.etat.statut === "disponible" && s.fichiers.size === 1);
}
{
  const s = simulation();
  s.etat.panneEnregistrement = 1;
  const r1 = await archiverPdfDevis(devis, generer, s.stockage, s.base);
  verifier("fichier stocké mais enregistrement en échec : non déclaré disponible", r1.statut === "echec" && s.etat.statut === "echec" && s.fichiers.size === 1, s.etat.echecs[0]);
  const stocke = await empreinteSha256(s.fichiers.get("d1/DEV-2026-0001.pdf")!);
  const r2 = await archiverPdfDevis(devis, async () => { throw new Error("ne doit pas régénérer"); }, s.stockage, s.base);
  verifier("reprise : le fichier déjà stocké est repris (pas de nouvelle génération), même empreinte", r2.statut === "disponible" && r2.repris && s.etat.empreinte === stocke);
}
{
  const s = simulation();
  let n = 0;
  const genererDifferent = async () => { n++; const pdf = await genererPdfDevis(instantane, { filigrane: null, dateDocument: new Date(date.getTime() + n * 1000) }); return pdf; };
  const [r1, r2] = await Promise.all([
    archiverPdfDevis(devis, genererDifferent, s.stockage, s.base),
    archiverPdfDevis(devis, genererDifferent, s.stockage, s.base),
  ]);
  const stocke = await empreinteSha256(s.fichiers.get("d1/DEV-2026-0001.pdf")!);
  verifier("deux générations simultanées (fichiers différents) : un seul fichier, une seule empreinte déclarée",
    r1.statut === "disponible" && r2.statut === "disponible" && s.fichiers.size === 1 && s.etat.empreinte === stocke
    && (r1 as { empreinte: string }).empreinte === (r2 as { empreinte: string }).empreinte, `${n} générations, ${s.etat.appelsEnregistrer} enregistrements`);
}
{
  const s = simulation();
  s.etat.panneStockage = 1;
  const r1 = await archiverPdfDevis(devis, generer, s.stockage, s.base);
  verifier("stockage indisponible : échec signalé, rien de déclaré", r1.statut === "echec" && s.etat.statut === "echec" && s.fichiers.size === 0);
  const r2 = await archiverPdfDevis(devis, generer, s.stockage, s.base);
  verifier("reprise après panne du stockage : disponible", r2.statut === "disponible" && s.etat.statut === "disponible");
}
{
  const s = simulation();
  await archiverPdfDevis(devis, generer, s.stockage, s.base);
  const bon = await lireArchiveVerifiee(s.stockage, "d1/DEV-2026-0001.pdf", s.etat.empreinte).then(() => true, () => false);
  const altere = s.fichiers.get("d1/DEV-2026-0001.pdf")!.slice(); altere[altere.length - 10] ^= 1;
  s.fichiers.set("d1/DEV-2026-0001.pdf", altere);
  const refuse = await lireArchiveVerifiee(s.stockage, "d1/DEV-2026-0001.pdf", s.etat.empreinte).then(() => false, (e) => String(e).includes("altéré"));
  verifier("téléchargement : archive vérifiée ; fichier altéré refusé", bon && refuse);
}
console.log(`\nBILAN : ${ok}/${ok + ko} contrôles réussis`);
