// PDF des factures (gabarit facture-v1), hors Next.js, à partir de l'INSTANTANÉ produit par la base d'ESSAI locale.
// Usage : tests-reels/simulation/rejouer.sh tests-reels/simulation/tests_finance.sql
//         node --experimental-strip-types tests-reels/tests_pdf_facture.mts
import { execFileSync } from "node:child_process";
import { inflateSync } from "node:zlib";
import { genererPdfFacture, montant, type InstantaneFacture } from "../src/lib/finance/pdf.ts";
import { empreinteSha256 } from "../src/lib/devis/archivage.ts";

let ok = 0, ko = 0;
const verifier = (libelle: string, cond: boolean, detail = "") => {
  cond ? ok++ : ko++;
  console.log(`  [${cond ? "OK " : "ÉCHEC"}] ${libelle}${detail ? `  (${detail})` : ""}`);
};
// Le texte des pages est compressé (FlateDecode) et écrit en hexadécimal : on décompresse chaque flux.
// Encodage WinAnsi des polices standard : Latin-1, plus « € », « — », « – », « … », « • » aux positions 0x80-0x97.
const WINANSI: Record<string, number> = { "€": 0x80, "…": 0x85, "•": 0x95, "–": 0x96, "—": 0x97 };
const hex = (s: string) => Buffer.from([...s].map((c) => WINANSI[c] ?? c.charCodeAt(0))).toString("hex").toUpperCase();
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

const sortie = execFileSync("psql", ["-h", "/var/tmp/pg-essai", "-p", "5499", "-U", "postgres", "-d", "essai", "-qAtc",
  "select instantane_emission from public.factures where not essai order by numero limit 1"], { encoding: "utf8" }).trim();
if (!sortie) throw new Error("Aucune facture dans la base d'essai : lancez d'abord tests_finance.sql");
const inst = JSON.parse(sortie) as InstantaneFacture;
const date = new Date("2026-10-24T12:00:00Z");

const pdf = await genererPdfFacture(inst, { filigrane: null, dateDocument: date });
verifier("PDF généré (en-tête %PDF)", Buffer.from(pdf.subarray(0, 5)).toString() === "%PDF-", `${pdf.length} octets`);
verifier("numéro imprimé", contient(pdf, `FACTURE ${inst.numero}`), inst.numero ?? "");
for (const [libelle, valeur] of [["total HT", inst.totaux.total_ht], ["TVA", inst.totaux.tva], ["total TTC", inst.totaux.total_ttc]] as const) {
  verifier(`${libelle} imprimé = instantané (${montant(valeur)})`, contient(pdf, montant(valeur)));
}
for (const l of inst.lignes) {
  verifier(`ligne « ${l.projet_nom} » à ${montant(l.tarif)} : montant ${montant(l.montant_ht)} imprimé`, contient(pdf, montant(l.montant_ht)));
}
const avecEcart = inst.lignes.find((l) => Number(l.ecart_arrondi) !== 0);
verifier("écart d'arrondi expliqué sans changer le montant",
  !!avecEcart && contient(pdf, `écart d'arrondi : ${montant(avecEcart.ecart_arrondi)}`) && contient(pdf, montant(avecEcart.montant_theorique)),
  avecEcart ? `${montant(avecEcart.montant_ht)} facturé, ${montant(avecEcart.montant_theorique)} théorique` : "aucune ligne avec écart");
verifier("somme des lignes imprimées = total HT de l'instantané",
  Math.round(inst.lignes.reduce((a, l) => a + Number(l.montant_ht), 0) * 100) === Math.round(Number(inst.totaux.total_ht) * 100));
verifier("détail des temps : chaque montant de temps imprimé", inst.temps.every((t) => contient(pdf, montant(t.montant_ht))));
const noms = [...new Set(inst.temps.map((t) => (t as { intervenant?: string }).intervenant ?? ""))].filter(Boolean);
verifier("PDF client : aucun nom d'intervenant imprimé (l'instantané les garde pour l'espace admin)",
  noms.length > 0 && noms.every((n) => !contient(pdf, n) && !n.split(" ").filter((m) => m.length > 2).some((m) => contient(pdf, m))), noms.join(", "));
verifier("PDF client : références non nominatives T-01 à T-" + String(inst.temps.length).padStart(2, "0"),
  inst.temps.every((_, i) => contient(pdf, `T-${String(i + 1).padStart(2, "0")}`)));
verifier("conditions de paiement imprimées (textes de l'instantané)",
  contient(pdf, `Pénalités de retard : ${inst.conditions.penalites_retard}`) && contient(pdf, `Escompte : ${inst.conditions.escompte}`));
verifier("échéance imprimée", contient(pdf, `Échéance : ${inst.date_echeance!.split("-").reverse().join("/")}`));
verifier("aucun coût interne ni mot « taux_horaire » dans le PDF", !contenuPages(pdf).includes(hex("TAUX_HORAIRE")));
const pdf2 = await genererPdfFacture(inst, { filigrane: null, dateDocument: date });
verifier("même instantané → même fichier (empreinte identique)", (await empreinteSha256(pdf)) === (await empreinteSha256(pdf2)));
const essai = await genererPdfFacture({ ...inst, essai: true }, { filigrane: "ESSAI — SANS VALEUR", dateDocument: date });
verifier("facture d'essai : filigrane « ESSAI — SANS VALEUR »", contient(essai, "ESSAI — SANS VALEUR"));
const apercu = await genererPdfFacture({ ...inst, numero: null }, { filigrane: "APERÇU — NON ÉMISE", dateDocument: date });
verifier("aperçu : sans numéro, filigrane « APERÇU — NON ÉMISE »", contient(apercu, "APERÇU — NON ÉMISE") && !contient(apercu, `FACTURE ${inst.numero}`));
console.log(`\nBILAN : ${ok}/${ok + ko} contrôles réussis`);
