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
  { cle: "assurance_assureur", libelle: "Assureur (responsabilité professionnelle / décennale)", indispensable: true, aide: "À confirmer avec votre assureur" },
  { cle: "assurance_contrat", libelle: "N° de contrat d'assurance", indispensable: true, aide: "" },
  { cle: "assurance_couverture", libelle: "Couverture géographique de l'assurance", indispensable: true, aide: "" },
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
  const local = (process.env.NEXT_PUBLIC_SUPABASE_URL ?? "").startsWith("http://127.0.0.1:");
  return local && process.env.SIMULATION_LOCALE === "1" ? COORDONNEES_SIMULATION : COORDONNEES_SG_INGENIERIE;
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

// Version du gabarit PDF : chaque version reste dans le code, inchangée, pour les devis émis avec.
export const GABARIT_DEVIS = "devis-v1";
