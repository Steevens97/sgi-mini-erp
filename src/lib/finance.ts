// Constantes et types partagés du module Finance (fichier ordinaire : un fichier "use server" ne peut
// exporter que des fonctions asynchrones). La base revérifie tout : ces textes servent à l'affichage.

export const MODES_FACTURATION = [
  { valeur: "temps_passe", libelle: "Au temps passé (facturable dans cette version)" },
  { valeur: "forfait", libelle: "Forfait (non facturé dans cette version)" },
  { valeur: "non_facturable", libelle: "Non facturable" },
] as const;

export function libelleMode(mode: string | null): string {
  return MODES_FACTURATION.find((m) => m.valeur === mode)?.libelle ?? "À définir (non facturable)";
}

export const MODES_REGLEMENT = [
  { valeur: "virement", libelle: "Virement" },
  { valeur: "cheque", libelle: "Chèque" },
  { valeur: "especes", libelle: "Espèces" },
  { valeur: "carte", libelle: "Carte" },
  { valeur: "autre", libelle: "Autre" },
] as const;

export const LIBELLES_STATUT_FACTURE: Record<string, string> = {
  emise: "Émise", envoyee: "Envoyée (déclarée)", payee: "Réglée (déclarée)", brouillon: "Brouillon",
};

export const LIBELLES_EVENEMENT_FACTURE: Record<string, string> = {
  emission: "Émission",
  pdf_archive: "PDF archivé",
  pdf_echec: "Échec de génération du PDF",
  envoi_declare: "Envoi déclaré",
  reglement_integral: "Règlement intégral déclaré",
  reglement_corrige: "Déclaration de règlement corrigée",
  reglement_annule: "Déclaration de règlement annulée",
};

// Limites de cette première version, affichées sur les écrans Finance.
export const LIMITES_FINANCE = [
  "Facturation au temps passé uniquement (projets explicitement « au temps passé ») ; forfaits et situations d'avancement : plus tard.",
  "Aucun avoir : une facture émise est conservée telle quelle, aucune erreur ne se corrige par un changement de statut.",
  "Règlement intégral uniquement : les paiements partiels ne sont pas gérés.",
  "Aucun email ni relance automatique, aucun suivi bancaire : l'envoi et le règlement sont seulement déclarés.",
];

// Confirmations affichées en haut de la fiche facture après une action (texte fixe, jamais repris de l'adresse).
export const CONFIRMATIONS_FACTURE: Record<string, string> = {
  pdf: "PDF archivé et disponible.",
  envoi: "Envoi déclaré. Aucun email n'a été envoyé par l'application.",
  reglement: "Règlement intégral enregistré.",
  correction: "Déclaration de règlement corrigée. La facture émise (numéro, contenu, montants) n'est pas modifiée ; l'ancienne déclaration reste dans l'historique.",
};

export const MENTION_PAIEMENT_PARTIEL =
  "Les paiements partiels ne sont pas gérés dans cette version : n'enregistrez un règlement que si la totalité de la facture a été reçue.";

// Documentation PROVISOIRE (24/10/2026) : textes officiels complets non vérifiés (sites DGFiP et BOFiP inaccessibles
// depuis l'environnement de développement). À confirmer avant toute émission réelle.
export const FACTURATION_ELECTRONIQUE_PROVISOIRE =
  "Facturation électronique (information provisoire, à confirmer avec votre expert-comptable ou la DGFiP) : cette version " +
  "produit des factures PDF ; elle ne produit ni facture électronique structurée transmise par une plateforme agréée, " +
  "ni e-reporting. Les obligations dépendent de chaque opération (client, lieu, assujettissement) : elle n'est pas " +
  "présentée comme adaptée à l'émission réelle tant que ces obligations n'ont pas été vérifiées sur les textes officiels.";

export type TempsCalcule = {
  id: string; date: string; intervenant: string; projet_id: string; projet_nom: string; heures: number;
  periode_id: string; date_effet: string; reference: string; tarif: number; montant_ht: number;
};
export type LigneCalculee = {
  projet_id: string; projet_nom: string; periode_id: string; date_effet: string; reference: string; tarif: number;
  nb_temps: number; heures: number; montant_ht: number; montant_theorique: number; ecart_arrondi: number;
};
export type Calcul = {
  client: { id: string; nom: string; adresse: string | null; email: string | null; telephone: string | null } | null;
  mois: string; periode_debut: string; periode_fin: string; essai: boolean;
  projets: { id: string; nom: string; devis_numero: string | null }[];
  lignes: LigneCalculee[]; temps: TempsCalcule[];
  totaux: { heures: number; total_ht: number; tva: number; total_ttc: number };
  tva: { regime: string | null; territoire: string | null; pays: string | null; taux: number | null; mention: string | null;
         criteres: Record<string, string> | null };
  blocages: string[]; empreinte: string;
};

export type PeriodeTarif = {
  type: "periode" | "correction"; id: string; remplace?: string; tarif: number; date_effet: string; reference: string;
  motif?: string; par_nom: string; le: string; temps_concernes: number; heures_concernees: number;
};

// Périodes en vigueur (non remplacées) : même règle que la base (finance_periodes_actives).
export function periodesActives(historique: PeriodeTarif[]): PeriodeTarif[] {
  const remplacees = new Set(historique.map((e) => e.remplace).filter(Boolean));
  return historique.filter((e) => (e.type === "periode" || e.type === "correction") && !remplacees.has(e.id))
    .sort((a, b) => a.date_effet.localeCompare(b.date_effet));
}

export function tarifApplicable(historique: PeriodeTarif[], jour: string): PeriodeTarif | null {
  return periodesActives(historique).filter((p) => p.date_effet <= jour).at(-1) ?? null;
}

// Saisie d'un tarif : nombre strictement positif, 2 décimales au plus (la base revérifie).
export function lireTarif(saisie: string | null): number | string {
  const t = (saisie ?? "").replace(/\s/g, "").replace(",", ".");
  if (!t) return "Le tarif horaire de vente est obligatoire.";
  if (!/^\d+(\.\d{1,2})?$/.test(t)) return "Tarif : un nombre avec 2 décimales au plus (ex. 85,50).";
  const v = Number(t);
  if (!(v > 0)) return "Tarif refusé : le tarif horaire de vente doit être strictement positif.";
  return v;
}

export function moisPrecedent(aujourdhui: string): string {
  const [a, m] = aujourdhui.split("-").map(Number);
  return m === 1 ? `${a - 1}-12` : `${a}-${String(m - 1).padStart(2, "0")}`;
}

// Paramètres d'un aperçu ou d'une émission, lus d'un formulaire (FormData) ou de l'adresse (searchParams).
export type ParametresFacture = { client: string; mois: string; projets: string[]; tva: Record<string, unknown> };
type Source = { get(nom: string): string | null; getAll(nom: string): string[] };

export function lireParametresFacture(s: Source): ParametresFacture {
  const v = (nom: string) => (s.get(nom) ?? "").trim();
  const criteres: Record<string, string> = {};
  for (const cle of ["nature_mission", "statut_client", "lieu_client", "lieu_immeuble", "numero_tva_client", "justification_taux"]) {
    if (v(cle)) criteres[cle] = cle.startsWith("lieu") ? v(cle).toUpperCase() : v(cle);
  }
  const regime = v("regime_tva");
  return {
    client: v("client_id"),
    mois: /^\d{4}-\d{2}$/.test(v("mois")) ? `${v("mois")}-01` : "",
    projets: [...new Set(s.getAll("projet_id").map((x) => x.trim()).filter(Boolean))].sort(),
    tva: {
      regime: regime || null,
      territoire: v("territoire_tva") || null,
      pays: ["UE", "AUTRE"].includes(v("territoire_tva")) ? v("pays_tva").toUpperCase() || null : null,
      taux: regime === "taxable" && v("taux_tva") ? Number(v("taux_tva").replace(",", ".")) : null,
      mention: v("mention_tva") || null,
      criteres,
    },
  };
}

export function sourceDepuisRecherche(p: Record<string, string | string[] | undefined>): Source {
  return {
    get: (nom) => { const x = p[nom]; return Array.isArray(x) ? (x[0] ?? null) : (x ?? null); },
    getAll: (nom) => { const x = p[nom]; return Array.isArray(x) ? x : x ? [x] : []; },
  };
}
