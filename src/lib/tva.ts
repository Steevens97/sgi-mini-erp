// Traitement fiscal des devis et factures : listes, taux proposés et PROPOSITION de traitement.
// La proposition n'est jamais appliquée seule : l'utilisateur confirme ; la base contrôle la
// cohérence (controle_traitement_tva). Sources vérifiées le 23/10/2026 (voir CLAUDE.md).

export type Regime = "taxable" | "autoliquidation" | "exoneration" | "non_applicable";
export type Territoire = "MQ" | "GP" | "GF" | "FR" | "UE" | "AUTRE";
export type NatureMission = "prestation_intellectuelle" | "prestation_immeuble" | "travaux_immobiliers" | "autre";
export type StatutClient = "assujetti_france" | "assujetti_ue" | "non_assujetti" | "hors_ue";

export const REGIMES: { valeur: Regime; libelle: string }[] = [
  { valeur: "taxable", libelle: "TVA facturée" },
  { valeur: "autoliquidation", libelle: "Autoliquidation (TVA due par le client)" },
  { valeur: "exoneration", libelle: "Exonération" },
  { valeur: "non_applicable", libelle: "TVA non applicable" },
];

export const TERRITOIRES: { valeur: Territoire; libelle: string }[] = [
  { valeur: "MQ", libelle: "Martinique" },
  { valeur: "GP", libelle: "Guadeloupe" },
  { valeur: "GF", libelle: "Guyane" },
  { valeur: "FR", libelle: "France métropolitaine" },
  { valeur: "UE", libelle: "Autre pays de l'Union européenne" },
  { valeur: "AUTRE", libelle: "Autre territoire" },
];

export const PAYS_UE = ["AT", "BE", "BG", "CY", "CZ", "DE", "DK", "EE", "ES", "FI", "GR", "HR", "HU", "IE", "IT",
  "LT", "LU", "LV", "MT", "NL", "PL", "PT", "RO", "SE", "SI", "SK"];

export const NATURES: { valeur: NatureMission; libelle: string }[] = [
  { valeur: "prestation_intellectuelle", libelle: "Prestation intellectuelle non rattachée à un immeuble" },
  { valeur: "prestation_immeuble", libelle: "Prestation se rattachant à un immeuble identifié" },
  { valeur: "travaux_immobiliers", libelle: "Travaux immobiliers" },
  { valeur: "autre", libelle: "Autre" },
];

export const STATUTS_CLIENT: { valeur: StatutClient; libelle: string }[] = [
  { valeur: "assujetti_france", libelle: "Entreprise établie en France (y c. DOM)" },
  { valeur: "assujetti_ue", libelle: "Entreprise d'un autre pays de l'UE (n° TVA)" },
  { valeur: "non_assujetti", libelle: "Particulier ou organisme non assujetti" },
  { valeur: "hors_ue", libelle: "Entreprise hors Union européenne" },
];

// Taux normaux (aucune justification) et taux réduits proposés (justification obligatoire).
export const TAUX_PAR_TERRITOIRE: Partial<Record<Territoire, { normal: number; reduits: number[] }>> = {
  MQ: { normal: 8.5, reduits: [2.1] },
  GP: { normal: 8.5, reduits: [2.1] },
  FR: { normal: 20, reduits: [10, 5.5, 2.1] },
};

// Seules mentions pré-remplies : leur texte est fixé par les sources officielles. Toute autre
// mention (exonération, hors champ…) doit être saisie et validée par l'utilisateur.
export const MENTIONS_SOURCEES = {
  autoliquidation: "Autoliquidation", // CGI ann. II art. 242 nonies A, 13°
  guyane: "TVA non applicable – art. 294 du CGI", // à mettre à jour lors du passage au CIBS
};

export type Criteres = {
  nature_mission?: NatureMission;
  statut_client?: StatutClient;
  lieu_client?: string; // territoire ou pays du client (MQ, GP, GF, FR, code pays)
  lieu_immeuble?: string;
  numero_tva_client?: string;
  justification_taux?: string;
};

export type Proposition = {
  regime: Regime | null;
  territoire: Territoire | null;
  pays: string | null;
  taux: number | null;
  mention: string;
  aConfirmer: boolean;
  explication: string;
};

function territoireDe(lieu: string | undefined): { territoire: Territoire | null; pays: string | null } {
  if (!lieu) return { territoire: null, pays: null };
  if (["MQ", "GP", "GF", "FR"].includes(lieu)) return { territoire: lieu as Territoire, pays: null };
  if (PAYS_UE.includes(lieu)) return { territoire: "UE", pays: lieu };
  return { territoire: "AUTRE", pays: lieu };
}

// Prestataire établi en Martinique. Le lieu de taxation dépend de la nature de la mission, du
// statut du client et, le cas échéant, du lieu de l'immeuble — jamais de la seule adresse.
export function proposerTraitement(c: Criteres): Proposition {
  const vide: Proposition = { regime: null, territoire: null, pays: null, taux: null, mention: "", aConfirmer: true,
    explication: "Renseignez la nature de la mission et le statut du client." };
  if (!c.nature_mission || !c.statut_client) return vide;

  if (c.nature_mission === "prestation_immeuble" || c.nature_mission === "travaux_immobiliers") {
    const { territoire, pays } = territoireDe(c.lieu_immeuble);
    if (!territoire) return { ...vide, explication: "Indiquez le lieu de l'immeuble : il détermine le lieu de taxation (CGI art. 259 A, 2°)." };
    const base = c.nature_mission === "travaux_immobiliers"
      ? " En sous-traitance de travaux de construction, l'autoliquidation peut s'appliquer : à confirmer."
      : "";
    if (territoire === "GF") return { regime: "non_applicable", territoire, pays, taux: null, mention: MENTIONS_SOURCEES.guyane,
      aConfirmer: true, explication: "Immeuble en Guyane : TVA non applicable (CGI art. 294)." + base };
    const t = TAUX_PAR_TERRITOIRE[territoire];
    if (t) return { regime: "taxable", territoire, pays, taux: t.normal, mention: "", aConfirmer: c.nature_mission === "travaux_immobiliers",
      explication: `Immeuble situé ${territoire === "FR" ? "en métropole" : "dans ce département"} : taux normal du lieu de l'immeuble.` + base };
    return { regime: null, territoire, pays, taux: null, mention: "", aConfirmer: true,
      explication: "Immeuble hors France : TVA du pays de l'immeuble, régime à confirmer avec votre expert-comptable." };
  }

  switch (c.statut_client) {
    case "assujetti_ue":
      return { regime: "autoliquidation", territoire: "UE", pays: territoireDe(c.lieu_client).pays, taux: null,
        mention: MENTIONS_SOURCEES.autoliquidation, aConfirmer: !c.numero_tva_client,
        explication: "Client assujetti d'un autre État membre : taxation chez le client (CGI art. 259, 1°), autoliquidation. N° de TVA du client obligatoire." };
    case "hors_ue":
      return { regime: "non_applicable", territoire: "AUTRE", pays: territoireDe(c.lieu_client).pays, taux: null, mention: "",
        aConfirmer: true, explication: "Client assujetti hors UE : en principe hors du champ de la TVA française (CGI art. 259, 1°). Mention à saisir et à confirmer." };
    case "assujetti_france": {
      const { territoire } = territoireDe(c.lieu_client ?? "MQ");
      if (territoire === "GF") return { regime: "non_applicable", territoire, pays: null, taux: null,
        mention: MENTIONS_SOURCEES.guyane, aConfirmer: true, explication: "Client établi en Guyane : TVA non applicable (CGI art. 294). À confirmer." };
      if (territoire === "FR") return { regime: "taxable", territoire, pays: null, taux: 20, mention: "", aConfirmer: true,
        explication: "Client établi en métropole : taux métropolitain ; le prestataire établi dans un DOM reste redevable (BOI-TVA-GEO-20-40). À confirmer." };
      return { regime: "taxable", territoire: territoire === "GP" ? "GP" : "MQ", pays: null, taux: 8.5, mention: "", aConfirmer: false,
        explication: "Client établi aux Antilles : taux normal de 8,5 % (CGI art. 296)." };
    }
    default:
      return { regime: "taxable", territoire: "MQ", pays: null, taux: 8.5, mention: "", aConfirmer: true,
        explication: "Client non assujetti : en principe taxation au lieu du prestataire (Martinique, 8,5 %). Certaines prestations dérogent : à confirmer." };
  }
}

export function libelleTraitement(regime: string | null, territoire: string | null, pays: string | null, taux: number | null): string {
  if (!regime) return "Traitement fiscal non renseigné";
  const lieu = TERRITOIRES.find((t) => t.valeur === territoire)?.libelle ?? territoire ?? "";
  const r = REGIMES.find((x) => x.valeur === regime)?.libelle ?? regime;
  return `${r}${taux !== null && regime === "taxable" ? ` ${String(taux).replace(".", ",")} %` : ""} — ${lieu}${pays ? ` (${pays})` : ""}`;
}
