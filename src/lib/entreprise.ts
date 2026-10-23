// Coordonnées de SG Ingénierie imprimées sur les devis (copiées dans l'instantané à l'émission).
// À COMPLÉTER par l'utilisateur : aucune valeur n'est inventée. Tant qu'un champ indispensable est
// vide, l'émission est refusée par l'application ET par la base (controle_emetteur).

export type CoordonneesEmetteur = {
  raison_sociale: string;
  forme_juridique: string;
  capital_social: string; // indispensable pour SARL, EURL, SAS, SASU, SA, SNC, SELARL, SELAS
  adresse: string;
  code_postal: string;
  ville: string;
  siret: string; // 14 chiffres
  immatriculation: string; // ex. « RCS Fort-de-France 123 456 789 » — texte exact à fournir
  tva_intracom: string;
  validite_jours: string; // durée de validité de l'offre, en jours
  assurance_assureur: string;
  assurance_contrat: string;
  assurance_couverture: string; // couverture géographique
  telephone: string;
  email: string;
  conditions_paiement: string;
};

export type ChampEmetteur = {
  cle: keyof CoordonneesEmetteur;
  libelle: string;
  indispensable: boolean;
  aide: string;
};

// Liste présentée à l'utilisateur ; « indispensable » = bloque l'émission (même liste qu'en base).
export const CHAMPS_EMETTEUR: ChampEmetteur[] = [
  { cle: "raison_sociale", libelle: "Raison sociale", indispensable: true, aide: "Dénomination exacte (Kbis)" },
  { cle: "forme_juridique", libelle: "Forme juridique", indispensable: true, aide: "SAS, SARL, EURL…" },
  { cle: "capital_social", libelle: "Capital social", indispensable: false, aide: "Indispensable pour une société (SAS, SARL…)" },
  { cle: "adresse", libelle: "Adresse du siège", indispensable: true, aide: "Numéro et voie" },
  { cle: "code_postal", libelle: "Code postal", indispensable: true, aide: "" },
  { cle: "ville", libelle: "Ville", indispensable: true, aide: "" },
  { cle: "siret", libelle: "SIRET", indispensable: true, aide: "14 chiffres" },
  { cle: "immatriculation", libelle: "Immatriculation (RCS)", indispensable: true, aide: "Texte exact, ex. « RCS Fort-de-France … »" },
  { cle: "tva_intracom", libelle: "N° de TVA intracommunautaire", indispensable: true, aide: "FR + 11 caractères" },
  { cle: "validite_jours", libelle: "Durée de validité des devis (jours)", indispensable: true, aide: "Nombre entier" },
  { cle: "assurance_assureur", libelle: "Assureur", indispensable: false, aide: "Exigé seulement pour les missions où l'assurance est obligatoire (voir OBLIGATIONS_ASSURANCE)" },
  { cle: "assurance_contrat", libelle: "N° de contrat d'assurance", indispensable: false, aide: "Idem" },
  { cle: "assurance_couverture", libelle: "Couverture géographique de l'assurance", indispensable: false, aide: "Idem" },
  { cle: "telephone", libelle: "Téléphone", indispensable: false, aide: "" },
  { cle: "email", libelle: "Email", indispensable: false, aide: "" },
  { cle: "conditions_paiement", libelle: "Conditions de paiement", indispensable: false, aide: "Texte exact à fournir" },
];

const FORMES_AVEC_CAPITAL = ["SARL", "EURL", "SAS", "SASU", "SA", "SNC", "SELARL", "SELAS"];

// VALEURS RÉELLES — vides tant que l'utilisateur ne les a pas fournies.
export const COORDONNEES_SG_INGENIERIE: CoordonneesEmetteur = {
  raison_sociale: "",
  forme_juridique: "",
  capital_social: "",
  adresse: "",
  code_postal: "",
  ville: "",
  siret: "",
  immatriculation: "",
  tva_intracom: "",
  validite_jours: "",
  assurance_assureur: "",
  assurance_contrat: "",
  assurance_couverture: "",
  telephone: "",
  email: "",
  conditions_paiement: "",
};

// DÉMONSTRATION — réservées aux devis d'essai (jamais utilisées pour un devis réel).
export const COORDONNEES_DEMO: CoordonneesEmetteur = {
  raison_sociale: "[DÉMO] SG Ingénierie",
  forme_juridique: "SAS",
  capital_social: "[DÉMO]",
  adresse: "[DÉMO] adresse",
  code_postal: "97200",
  ville: "Fort-de-France",
  siret: "00000000000000",
  immatriculation: "[DÉMO] immatriculation",
  tva_intracom: "[DÉMO]",
  validite_jours: "30",
  assurance_assureur: "[DÉMO]",
  assurance_contrat: "[DÉMO]",
  assurance_couverture: "[DÉMO]",
  telephone: "",
  email: "",
  conditions_paiement: "",
};

// SIMULATION LOCALE — uniquement quand l'application parle à la passerelle de test sur la machine
// de développement (adresse 127.0.0.1) avec SIMULATION_LOCALE=1. Impossible avec Supabase.
const COORDONNEES_SIMULATION: CoordonneesEmetteur = {
  ...COORDONNEES_DEMO,
  raison_sociale: "SIMULATION LOCALE — SANS VALEUR",
  capital_social: "SIMULATION",
  adresse: "SIMULATION",
  immatriculation: "SIMULATION",
  tva_intracom: "SIMULATION",
  assurance_assureur: "SIMULATION",
  assurance_contrat: "SIMULATION",
  assurance_couverture: "SIMULATION",
};

// Coordonnées utilisées pour un devis réel.
export function coordonneesEmetteur(): CoordonneesEmetteur {
  return enSimulation() ? COORDONNEES_SIMULATION : COORDONNEES_SG_INGENIERIE;
}

export function champsEmetteurManquants(c: CoordonneesEmetteur): string[] {
  const manquants = CHAMPS_EMETTEUR.filter((champ) => champ.indispensable && !c[champ.cle].trim()).map(
    (champ) => champ.libelle,
  );
  if (FORMES_AVEC_CAPITAL.includes(c.forme_juridique.trim().toUpperCase()) && !c.capital_social.trim()) {
    manquants.push("Capital social");
  }
  if (c.siret.trim() && !/^[0-9]{14}$/.test(c.siret.replace(/\s/g, ""))) manquants.push("SIRET (14 chiffres)");
  if (c.validite_jours.trim() && !/^[1-9][0-9]*$/.test(c.validite_jours.trim())) {
    manquants.push("Durée de validité (nombre de jours)");
  }
  return manquants;
}

// Types de mission de SG Ingénierie et obligation d'assurance à l'émission.
export type TypeMission = "conseil" | "amo" | "moex" | "opc" | "donnees" | "drone" | "autre";
export type ObligationAssurance = "obligatoire" | "non_requise" | "a_confirmer";

export const TYPES_MISSION: { valeur: TypeMission; libelle: string }[] = [
  { valeur: "conseil", libelle: "Conseil" },
  { valeur: "amo", libelle: "Assistance à maîtrise d'ouvrage (AMO)" },
  { valeur: "moex", libelle: "Maîtrise d'œuvre d'exécution (MOEx)" },
  { valeur: "opc", libelle: "Ordonnancement, pilotage et coordination (OPC)" },
  { valeur: "donnees", libelle: "Données" },
  { valeur: "drone", libelle: "Drone" },
  { valeur: "autre", libelle: "Autre" },
];

// Texte affiché à l'écran pour toute mission : l'étiquette de mission ne vaut jamais validation de
// l'assurance (seuls la mission réelle et le contrat d'assurance font foi).
export const MENTION_ASSURANCE = "couverture à vérifier selon la mission et le contrat";

// À VALIDER par l'utilisateur avec son assureur. « a_confirmer » BLOQUE l'émission pour la mission.
// MOEx : assurance décennale obligatoire (C. assur. L241-1 ; C. civ. 1792-1) — imposé aussi en base.
// Les autres missions dépendent de leur contenu exact : aucune obligation n'est supposée ici.
export const OBLIGATIONS_ASSURANCE: Record<TypeMission, ObligationAssurance> = {
  conseil: "a_confirmer",
  amo: "a_confirmer",
  moex: "obligatoire",
  opc: "a_confirmer",
  donnees: "a_confirmer",
  drone: "a_confirmer",
  autre: "a_confirmer",
};

const OBLIGATIONS_SIMULATION: Record<TypeMission, ObligationAssurance> = {
  conseil: "non_requise", amo: "non_requise", moex: "obligatoire", opc: "non_requise",
  donnees: "non_requise", drone: "non_requise", autre: "non_requise",
};

function enSimulation(): boolean {
  return (process.env.NEXT_PUBLIC_SUPABASE_URL ?? "").startsWith("http://127.0.0.1:") && process.env.SIMULATION_LOCALE === "1";
}

// Ce qui empêche d'émettre un devis réel pour cette mission (vide = émission possible).
export function blocagesEmission(type: TypeMission | null): string[] {
  const c = coordonneesEmetteur();
  const blocages = champsEmetteurManquants(c).map((x) => `coordonnées : ${x}`);
  if (!type) return [...blocages, "type de mission non renseigné"];
  const obligation = (enSimulation() ? OBLIGATIONS_SIMULATION : OBLIGATIONS_ASSURANCE)[type];
  if (obligation === "a_confirmer") {
    blocages.push(`assurance : ${MENTION_ASSURANCE} (obligation non confirmée par l'assureur)`);
  }
  if (obligation === "obligatoire") {
    for (const [cle, libelle] of [["assurance_assureur", "assureur"], ["assurance_contrat", "n° de contrat"],
      ["assurance_couverture", "couverture géographique"]] as const) {
      if (!c[cle].trim()) blocages.push(`assurance : ${MENTION_ASSURANCE} — ${libelle} non renseigné`);
    }
  }
  return blocages;
}

// Coordonnées transmises à la base (copiées dans l'instantané) pour un devis réel.
export function emetteurPourMission(type: TypeMission): Record<string, string> {
  const c = coordonneesEmetteur();
  const obligation = (enSimulation() ? OBLIGATIONS_SIMULATION : OBLIGATIONS_ASSURANCE)[type];
  const { assurance_assureur, assurance_contrat, assurance_couverture, ...reste } = c;
  return obligation === "obligatoire"
    ? { ...reste, obligation_assurance: obligation, assurance_assureur, assurance_contrat, assurance_couverture }
    : { ...reste, obligation_assurance: obligation };
}

// Version du gabarit PDF : chaque version reste dans le code, inchangée, pour les devis émis avec.
export const GABARIT_DEVIS = "devis-v1";
