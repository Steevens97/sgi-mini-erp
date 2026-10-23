// Génération du PDF d'un devis à partir de son INSTANTANÉ (figé à l'émission) — jamais à partir des
// données courantes. Gabarit « devis-v1 » : ne jamais le modifier une fois des devis émis avec ;
// une nouvelle mise en page = nouvelle version de gabarit.
// Fichier sans dépendance serveur : il est testé hors Next.js (tests-reels/tests_pdf.mjs).
import { PDFDocument, StandardFonts, rgb, degrees, type PDFFont, type PDFPage } from "pdf-lib";

export type InstantaneDevis = {
  essai?: boolean;
  gabarit?: string;
  numero: string | null;
  date_emission: string | null;
  emetteur: Record<string, string>;
  destinataire: {
    prospect: Record<string, string | null>;
    client?: Record<string, string | null> | null;
  };
  lignes: { designation: string; quantite: number; prix_unitaire: number; montant_ht: number }[];
  totaux: { total_ht: number; tva: number; total_ttc: number };
  tva: { regime: string | null; territoire: string | null; pays: string | null; taux: number | null; mention: string | null };
  remplace?: string | null;
  avenant_de?: string | null;
};

export type OptionsPdf = {
  filigrane: string | null; // « BROUILLON — NON ÉMIS », « ESSAI — SANS VALEUR » ou aucun
  dateDocument: Date; // métadonnées fixes (date d'émission) : même entrée → même fichier
};

// Les polices standard PDF (WinAnsi) n'ont pas les espaces fines insécables, etc.
function propre(texte: string | null | undefined): string {
  return String(texte ?? "")
    .replace(/[   ]/g, " ")
    .replace(/[‘’]/g, "'")
    .replace(/[“”]/g, '"')
    .replace(/[^\x20-\x7E -ÿ€—–…•\n]/g, "?");
}

export function montant(n: number): string {
  const signe = n < 0 ? "-" : "";
  const [entier, dec] = Math.abs(n).toFixed(2).split(".");
  return `${signe}${entier.replace(/\B(?=(\d{3})+(?!\d))/g, " ")},${dec} €`;
}

function nombre(n: number): string {
  return String(n).replace(".", ",");
}

const NOMS_PAYS: Record<string, string> = { MQ: "Martinique", GP: "Guadeloupe", GF: "Guyane", RE: "La Réunion",
  YT: "Mayotte", FR: "France" };

function dateFr(iso: string | null): string {
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

export async function genererPdfDevis(inst: InstantaneDevis, options: OptionsPdf): Promise<Uint8Array> {
  const doc = await PDFDocument.create({ updateMetadata: false });
  doc.setTitle(propre(inst.numero ? `Devis ${inst.numero}` : "Devis brouillon"));
  doc.setAuthor(propre(inst.emetteur.raison_sociale));
  doc.setProducer("Mini-ERP SGI (gabarit devis-v1)");
  doc.setCreator("Mini-ERP SGI");
  doc.setCreationDate(options.dateDocument);
  doc.setModificationDate(options.dateDocument);

  const normal = await doc.embedFont(StandardFonts.Helvetica);
  const gras = await doc.embedFont(StandardFonts.HelveticaBold);
  const gris = rgb(0.35, 0.35, 0.4);
  const marge = 48;
  let page: PDFPage = doc.addPage([595.28, 841.89]);
  let y = 800;

  const ecrire = (t: string, x: number, taille = 9, police = normal, couleur = rgb(0, 0, 0)) =>
    page.drawText(propre(t), { x, y, size: taille, font: police, color: couleur });
  const nouvellePage = () => {
    page = doc.addPage([595.28, 841.89]);
    y = 800;
  };

  // En-tête : émetteur (gauche) et destinataire (droite)
  const e = inst.emetteur;
  ecrire(e.raison_sociale ?? "", marge, 13, gras);
  y -= 15;
  for (const l of [e.adresse, `${e.code_postal ?? ""} ${e.ville ?? ""}`, e.telephone, e.email].filter(Boolean)) {
    ecrire(l as string, marge, 9, normal, gris);
    y -= 11;
  }
  const p = inst.destinataire.prospect;
  let yDest = 785;
  const xDest = 330;
  for (const [l, police] of [
    [p.societe || p.nom, gras], [p.societe ? p.nom : null, normal], [p.adresse, normal],
    [`${p.code_postal ?? ""} ${p.ville ?? ""}`.trim(), normal], [p.pays ? (NOMS_PAYS[p.pays] ?? p.pays) : null, normal],
  ] as [string | null, PDFFont][]) {
    if (!l) continue;
    page.drawText(propre(l), { x: xDest, y: yDest, size: 10, font: police });
    yDest -= 12;
  }
  y = Math.min(y, yDest) - 24;

  // Titre
  const titre = inst.avenant_de
    ? `AVENANT ${inst.numero ?? ""} au devis ${inst.avenant_de}`
    : `DEVIS ${inst.numero ?? "(brouillon)"}`;
  ecrire(titre, marge, 15, gras);
  y -= 16;
  ecrire(`Date : ${dateFr(inst.date_emission)}${e.validite_jours ? `   —   Validité : ${e.validite_jours} jours` : ""}`, marge, 9, normal, gris);
  y -= 12;
  if (inst.remplace) {
    ecrire(`Annule et remplace le devis ${inst.remplace}`, marge, 9, gras);
    y -= 12;
  }
  if (inst.totaux.total_ht < 0) {
    ecrire("Moins-value : cet avenant réduit le montant de la mission.", marge, 9, gras);
    y -= 12;
  }
  y -= 10;

  // Tableau des lignes
  const colonnes = { designation: marge, quantite: 340, prix: 400, montant: 480 };
  const entete = () => {
    page.drawRectangle({ x: marge - 4, y: y - 4, width: 595.28 - 2 * marge + 8, height: 16, color: rgb(0.93, 0.94, 0.96) });
    ecrire("Désignation", colonnes.designation, 9, gras);
    ecrire("Qté", colonnes.quantite, 9, gras);
    ecrire("P.U. HT", colonnes.prix, 9, gras);
    ecrire("Montant HT", colonnes.montant, 9, gras);
    y -= 18;
  };
  entete();
  for (const ligne of inst.lignes) {
    const texte = couper(ligne.designation, normal, 9, colonnes.quantite - colonnes.designation - 10);
    if (y - texte.length * 11 < 150) {
      nouvellePage();
      entete();
    }
    ecrire(nombre(ligne.quantite), colonnes.quantite, 9);
    ecrire(montant(ligne.prix_unitaire), colonnes.prix, 9);
    ecrire(montant(ligne.montant_ht), colonnes.montant, 9);
    for (const t of texte) {
      ecrire(t, colonnes.designation, 9);
      y -= 11;
    }
    y -= 4;
  }

  // Totaux et traitement fiscal
  if (y < 190) nouvellePage();
  y -= 8;
  const t = inst.tva;
  const lignesTotaux: [string, string][] = [["Total HT", montant(inst.totaux.total_ht)]];
  if (t.regime === "taxable") lignesTotaux.push([`TVA ${nombre(t.taux ?? 0)} %`, montant(inst.totaux.tva)]);
  else lignesTotaux.push(["TVA", "—"]);
  lignesTotaux.push(["Total TTC", montant(inst.totaux.total_ttc)]);
  for (const [libelle, valeur] of lignesTotaux) {
    ecrire(libelle, 380, 10, libelle.startsWith("Total TTC") ? gras : normal);
    ecrire(valeur, colonnes.montant, 10, libelle.startsWith("Total TTC") ? gras : normal);
    y -= 14;
  }
  if (t.mention) {
    y -= 4;
    for (const l of couper(t.mention, gras, 9, 595.28 - 2 * marge)) {
      ecrire(l, marge, 9, gras);
      y -= 11;
    }
  }
  if (e.conditions_paiement) {
    y -= 6;
    for (const l of couper(`Conditions de paiement : ${e.conditions_paiement}`, normal, 8, 595.28 - 2 * marge)) {
      ecrire(l, marge, 8, normal, gris);
      y -= 10;
    }
  }

  // Pied de page légal et filigrane, sur chaque page
  const pied = [
    [e.raison_sociale, e.forme_juridique, e.capital_social ? `capital ${e.capital_social}` : null].filter(Boolean).join(" — "),
    [`Siège : ${e.adresse ?? ""} ${e.code_postal ?? ""} ${e.ville ?? ""}`, `SIRET ${e.siret ?? ""}`, e.immatriculation].join(" — "),
    [`TVA intracom. ${e.tva_intracom ?? ""}`,
      // Assurance imprimée seulement si elle est obligatoire pour la mission (jamais inventée).
      e.obligation_assurance === "obligatoire"
        ? `Assurance : ${e.assurance_assureur ?? ""}, contrat ${e.assurance_contrat ?? ""}, couverture ${e.assurance_couverture ?? ""}`
        : null].filter(Boolean).join(" — "),
  ];
  const pages = doc.getPages();
  pages.forEach((pg, i) => {
    pied.forEach((l, k) => {
      const texte = propre(l);
      const taille = 7;
      pg.drawText(texte, { x: (595.28 - normal.widthOfTextAtSize(texte, taille)) / 2, y: 42 - k * 9, size: taille, font: normal, color: gris });
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
