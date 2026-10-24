// Génération du PDF d'une facture à partir de son INSTANTANÉ (figé à l'émission) — jamais à partir des données
// courantes. Gabarit « facture-v1 » : ne jamais le modifier une fois des factures émises avec ; une nouvelle mise
// en page = nouvelle version de gabarit. Les montants imprimés sont ceux de l'instantané (aucun recalcul).
// Fichier sans dépendance serveur : testé hors Next.js (tests-reels/tests_pdf_facture.mts).
import { PDFDocument, StandardFonts, rgb, degrees, type PDFFont, type PDFPage } from "pdf-lib";

export type InstantaneFacture = {
  essai?: boolean;
  gabarit?: string;
  numero: string | null;
  date_emission: string | null;
  date_echeance: string | null;
  periode: { mois: string; debut: string; fin: string };
  emetteur: Record<string, string>;
  conditions: Record<string, string>;
  client: { nom: string; adresse: string | null } | null;
  lignes: { projet_nom: string; date_effet: string; reference: string; tarif: number; nb_temps: number; heures: number;
            montant_ht: number; montant_theorique: number; ecart_arrondi: number }[];
  // L'instantané garde l'intervenant (espace admin) ; le PDF client ne l'imprime pas.
  temps: { date: string; intervenant?: string; projet_nom: string; heures: number; tarif: number; montant_ht: number }[];
  totaux: { heures: number; total_ht: number; tva: number; total_ttc: number };
  tva: { regime: string | null; taux: number | null; mention: string | null };
};

export type OptionsPdf = {
  filigrane: string | null; // « APERÇU — NON ÉMISE », « ESSAI — SANS VALEUR » ou aucun
  dateDocument: Date; // métadonnées fixes : même entrée → même fichier
};

function propre(texte: string | null | undefined): string {
  return String(texte ?? "")
    .replace(/[   ]/g, " ")
    .replace(/[‘’]/g, "'")
    .replace(/[“”]/g, '"')
    .replace(/[^\x20-\x7E -ÿ€—–…•\n]/g, "?");
}

export function montant(n: number | string): string {
  const v = Number(n);
  const signe = v < 0 ? "-" : "";
  const [entier, dec] = Math.abs(v).toFixed(2).split(".");
  return `${signe}${entier.replace(/\B(?=(\d{3})+(?!\d))/g, " ")},${dec} €`;
}

function nombre(n: number | string): string {
  return String(Number(n)).replace(".", ",");
}

function dateFr(iso: string | null | undefined): string {
  if (!iso) return "—";
  const [a, m, j] = iso.slice(0, 10).split("-");
  return `${j}/${m}/${a}`;
}

function couper(texte: string, police: PDFFont, taille: number, largeur: number): string[] {
  const lignes: string[] = [];
  for (const paragraphe of propre(texte).split("\n")) {
    let courante = "";
    for (const mot of paragraphe.split(" ")) {
      const essai = courante ? `${courante} ${mot}` : mot;
      if (police.widthOfTextAtSize(essai, taille) > largeur && courante) {
        lignes.push(courante);
        courante = mot;
      } else courante = essai;
    }
    lignes.push(courante);
  }
  return lignes;
}

export async function genererPdfFacture(inst: InstantaneFacture, options: OptionsPdf): Promise<Uint8Array> {
  const doc = await PDFDocument.create({ updateMetadata: false });
  doc.setTitle(propre(inst.numero ? `Facture ${inst.numero}` : "Aperçu de facture"));
  doc.setAuthor(propre(inst.emetteur.raison_sociale));
  doc.setProducer("Mini-ERP SGI (gabarit facture-v1)");
  doc.setCreator("Mini-ERP SGI");
  doc.setCreationDate(options.dateDocument);
  doc.setModificationDate(options.dateDocument);

  const normal = await doc.embedFont(StandardFonts.Helvetica);
  const gras = await doc.embedFont(StandardFonts.HelveticaBold);
  const gris = rgb(0.35, 0.35, 0.4);
  const marge = 48;
  const largeur = 595.28 - 2 * marge;
  let page: PDFPage = doc.addPage([595.28, 841.89]);
  let y = 800;
  const ecrire = (t: string, x: number, taille = 9, police = normal, couleur = rgb(0, 0, 0)) =>
    page.drawText(propre(t), { x, y, size: taille, font: police, color: couleur });
  const aDroite = (t: string, xDroite: number, taille = 9, police = normal) =>
    page.drawText(propre(t), { x: xDroite - police.widthOfTextAtSize(propre(t), taille), y, size: taille, font: police });
  const place = (hauteur: number) => {
    if (y - hauteur < 110) {
      page = doc.addPage([595.28, 841.89]);
      y = 800;
      return true;
    }
    return false;
  };

  // En-tête : émetteur (gauche) et client (droite)
  const e = inst.emetteur;
  ecrire(e.raison_sociale ?? "", marge, 13, gras);
  y -= 15;
  for (const l of [e.adresse, `${e.code_postal ?? ""} ${e.ville ?? ""}`, e.telephone, e.email].filter((x) => x && x.trim())) {
    ecrire(l as string, marge, 9, normal, gris);
    y -= 11;
  }
  let yClient = 785;
  page.drawText(propre(inst.client?.nom ?? ""), { x: 330, y: yClient, size: 10, font: gras });
  for (const l of couper(inst.client?.adresse ?? "", normal, 10, 215)) {
    yClient -= 12;
    page.drawText(l, { x: 330, y: yClient, size: 10, font: normal });
  }
  y = Math.min(y, yClient) - 26;

  ecrire(inst.numero ? `FACTURE ${inst.numero}` : "APERÇU DE FACTURE (non émise, sans numéro)", marge, 15, gras);
  y -= 16;
  ecrire(`Date d'émission : ${dateFr(inst.date_emission)}   —   Échéance : ${dateFr(inst.date_echeance)}`, marge, 9, normal, gris);
  y -= 12;
  ecrire(`Prestations au temps passé du ${dateFr(inst.periode.debut)} au ${dateFr(inst.periode.fin)}`, marge, 9, normal, gris);
  y -= 22;

  // Lignes : un projet × une période tarifaire. Montant = somme des montants de chaque temps arrondis au centime.
  const col = { designation: marge, heures: 330, tarif: 420, montant: 547 };
  const entete = () => {
    page.drawRectangle({ x: marge - 4, y: y - 4, width: largeur + 8, height: 16, color: rgb(0.93, 0.94, 0.96) });
    ecrire("Désignation", col.designation, 9, gras);
    aDroite("Heures", col.heures + 30, 9, gras);
    aDroite("Tarif HT / h", col.tarif + 40, 9, gras);
    aDroite("Montant HT", col.montant, 9, gras);
    y -= 18;
  };
  entete();
  for (const l of inst.lignes) {
    const designation = couper(`${l.projet_nom} — tarif contractuel à compter du ${dateFr(l.date_effet)} (réf. ${l.reference})`,
      normal, 9, col.heures - col.designation - 20);
    const ecart = Number(l.ecart_arrondi) !== 0;
    if (place(designation.length * 11 + (ecart ? 22 : 0) + 6)) entete();
    aDroite(nombre(l.heures), col.heures + 30);
    aDroite(montant(l.tarif), col.tarif + 40);
    aDroite(montant(l.montant_ht), col.montant);
    for (const t of designation) {
      ecrire(t, col.designation);
      y -= 11;
    }
    if (ecart) {
      for (const t of couper(`Somme de ${l.nb_temps} temps arrondis chacun au centime ; ${nombre(l.heures)} h × ${montant(l.tarif)} = `
        + `${montant(l.montant_theorique)} ; écart d'arrondi : ${Number(l.ecart_arrondi) > 0 ? "+" : ""}${montant(l.ecart_arrondi)}.`,
      normal, 7.5, largeur)) {
        ecrire(t, col.designation + 8, 7.5, normal, gris);
        y -= 10;
      }
    }
    y -= 4;
  }

  // Totaux et TVA
  place(90);
  y -= 6;
  const t = inst.tva;
  const totaux: [string, string, PDFFont][] = [["Total HT", montant(inst.totaux.total_ht), normal]];
  totaux.push(t.regime === "taxable" ? [`TVA ${nombre(t.taux ?? 0)} %`, montant(inst.totaux.tva), normal] : ["TVA", "—", normal]);
  totaux.push(["Total TTC", montant(inst.totaux.total_ttc), gras]);
  for (const [libelle, valeur, police] of totaux) {
    ecrire(libelle, 380, 10, police);
    aDroite(valeur, col.montant, 10, police);
    y -= 14;
  }
  if (t.mention) {
    y -= 2;
    for (const l of couper(t.mention, gras, 9, largeur)) {
      ecrire(l, marge, 9, gras);
      y -= 11;
    }
  }

  // Conditions de paiement (textes fournis par l'utilisateur, figés dans l'instantané)
  const c = inst.conditions;
  place(70);
  y -= 8;
  for (const l of [
    `Échéance : ${dateFr(inst.date_echeance)} (paiement à ${c.delai_paiement_jours ?? "—"} jours).`,
    `Pénalités de retard : ${c.penalites_retard ?? ""}`,
    `Indemnité forfaitaire pour frais de recouvrement : ${c.indemnite_recouvrement ?? ""}`,
    `Escompte : ${c.escompte ?? ""}`,
  ]) {
    for (const x of couper(l, normal, 8, largeur)) {
      ecrire(x, marge, 8, normal, gris);
      y -= 10;
    }
  }

  // Annexe CLIENT : détail des temps facturés, SANS nom d'intervenant (décision de l'utilisateur, 24/10/2026) :
  // référence non nominative, date, projet, durée × tarif, montant de chaque temps arrondi au centime.
  // Le détail nominatif reste dans l'espace administrateur (instantané de la facture).
  if (inst.temps.length) {
    if (!place(70)) y -= 14;
    ecrire("Détail des temps facturés", marge, 10, gras);
    y -= 12;
    ecrire("Chaque ligne est un temps facturé ; montant = durée × tarif, arrondi au centime.", marge, 7.5, normal, gris);
    y -= 13;
    const c2 = { ref: marge, date: 100, projet: 165, heures: 420, montant: 547 };
    inst.temps.forEach((tp, i) => {
      place(12);
      ecrire(`T-${String(i + 1).padStart(2, "0")}`, c2.ref, 8);
      ecrire(dateFr(tp.date), c2.date, 8);
      ecrire(couper(tp.projet_nom, normal, 8, 205)[0] ?? "", c2.projet, 8);
      aDroite(`${nombre(tp.heures)} h × ${montant(tp.tarif)}`, c2.heures + 50, 8);
      aDroite(montant(tp.montant_ht), c2.montant, 8);
      y -= 11;
    });
  }

  // Pied de page légal et filigrane, sur chaque page
  const pied = [
    [e.raison_sociale, e.forme_juridique, e.capital_social ? `capital ${e.capital_social}` : null].filter(Boolean).join(" — "),
    [`Siège : ${e.adresse ?? ""} ${e.code_postal ?? ""} ${e.ville ?? ""}`, `SIRET ${e.siret ?? ""}`, e.immatriculation].join(" — "),
    `TVA intracom. ${e.tva_intracom ?? ""}`,
  ];
  const pages = doc.getPages();
  pages.forEach((pg, i) => {
    pied.forEach((l, k) => {
      const texte = propre(l);
      pg.drawText(texte, { x: (595.28 - normal.widthOfTextAtSize(texte, 7)) / 2, y: 42 - k * 9, size: 7, font: normal, color: gris });
    });
    pg.drawText(`${i + 1}/${pages.length}`, { x: 595.28 - marge, y: 18, size: 7, font: normal, color: gris });
    if (options.filigrane) {
      pg.drawText(propre(options.filigrane), {
        x: 90, y: 260, size: 44, font: gras, color: rgb(0.85, 0.2, 0.2), opacity: 0.18, rotate: degrees(35),
      });
    }
  });
  return doc.save({ useObjectStreams: false });
}
