// Constantes et contrôles partagés du module RH (fichier ordinaire : un fichier "use server" ne peut
// exporter que des fonctions asynchrones). La base revérifie tout : ces contrôles servent à afficher
// un message clair AVANT l'envoi et à ne jamais proposer une combinaison que la base refuserait.

// Paramètres de gestion de SG Ingénierie — copie de public.rh_parametres() (migration 20261025100000).
// Ce ne sont pas des règles de droit du travail. Les modifier = nouvelle migration + ce fichier.
export const PARAMETRES_RH = {
  pasHeures: 0.25,
  fenetreJours: 31,
  seuilDerogationJour: 12,
  plafondAbsoluJour: 24,
} as const;

export const LIBELLES_STATUT_TEMPS: Record<string, string> = {
  brouillon: "Brouillon",
  soumis: "Soumis",
  valide: "Validé",
};
export const LIBELLES_STATUT_PROJET: Record<string, string> = {
  en_cours: "En cours (ouvert à la saisie)",
  termine: "Terminé",
  annule: "Annulé",
};
export const STATUTS_PROJET = ["en_cours", "termine", "annule"] as const;

export const LIBELLES_EVENEMENT: Record<string, string> = {
  anterieur_au_module_rh: "Antérieur au module RH (auteur et validation inconnus)",
  saisie: "Saisie",
  correction: "Correction",
  soumission: "Soumission",
  retrait: "Retrait par l'intéressé",
  renvoi: "Renvoi pour correction",
  validation: "Validation",
  reouverture: "Réouverture d'un temps validé",
  attestation_interesse: "Attestation de l'intéressé (pas une validation)",
  derogation: "Dérogation",
  facturation: "Facturation",
};

export type EvenementTemps = {
  action: string;
  le: string | null;
  auteur: string | null;
  auteur_nom: string | null;
  motif: string | null;
  validation_precedente?: { valide_par: string | null; valide_par_nom: string | null; valide_le: string | null };
};

// Date du jour à la Martinique (« AAAA-MM-JJ »), comme la base.
export function aujourdhuiMartinique(): string {
  return new Intl.DateTimeFormat("en-CA", { timeZone: "America/Martinique" }).format(new Date());
}
export function decalerJours(iso: string, jours: number): string {
  const d = new Date(`${iso}T12:00:00Z`);
  d.setUTCDate(d.getUTCDate() + jours);
  return d.toISOString().slice(0, 10);
}

// Durée : strictement positive, par pas de 0,25 h, au plus 24 h. Renvoie le nombre ou un message.
export function lireHeures(saisie: string | null): number | string {
  if (!saisie) return "La durée est obligatoire.";
  if (!/^[0-9]+([.,][0-9]{1,2})?$/.test(saisie)) return "Durée : nombre d'heures positif, par exemple 7,5.";
  const h = Number(saisie.replace(",", "."));
  if (h <= 0) return "Durée : zéro heure est refusé ; saisissez une durée strictement positive.";
  if (h > PARAMETRES_RH.plafondAbsoluJour) return `Durée : au plus ${PARAMETRES_RH.plafondAbsoluJour} h par ligne.`;
  if (Math.round(h * 4) !== h * 4) return "Durée : par pas de 0,25 h (0,25 ; 0,5 ; 0,75 ; 1…).";
  return h;
}

// Taux horaire : obligatoire, jamais attribué à la place de l'utilisateur (vide ≠ 0).
export function lireTaux(saisie: string | null): number | string {
  if (saisie === null) return "Le taux horaire est obligatoire : saisissez le taux confirmé (0 seulement si c'est le vrai taux).";
  if (!/^[0-9]+([.,][0-9]{1,2})?$/.test(saisie)) {
    return "Le taux horaire doit être un nombre positif ou 0, avec au plus 2 décimales (ex. 85 ou 85,50).";
  }
  const t = Number(saisie.replace(",", "."));
  if (t >= 1e8) return "Le taux horaire saisi est trop élevé.";
  return t;
}

// Messages de la base traduits quand ils viennent d'une contrainte (les messages des déclencheurs sont
// déjà en français et sont affichés tels quels).
const CONTRAINTES: Record<string, string> = {
  temps_heures_pas_quart_heure: "Durée : strictement positive, par pas de 0,25 h, au plus 24 h.",
  collaborateurs_pas_son_propre_manager: "Une personne ne peut pas être son propre manager.",
  collaborateurs_taux_positif: "Le taux horaire ne peut pas être négatif.",
  collaborateurs_sortie_apres_entree: "La date de sortie ne peut pas précéder la date d'entrée.",
  projets_statut_check: "Statut de projet inconnu.",
};
export function messageBase(message: string | null | undefined): string {
  const m = message ?? "Erreur inconnue.";
  for (const [nom, texte] of Object.entries(CONTRAINTES)) if (m.includes(nom)) return texte;
  if (/permission denied|row-level security/i.test(m)) return "Action non autorisée avec vos droits.";
  return m;
}

export function nomComplet(f: { prenom?: string | null; nom: string } | null | undefined): string {
  return f ? [f.prenom, f.nom].filter(Boolean).join(" ") : "—";
}

// Managers proposables pour une fiche : fiches non sorties, sauf elle-même et ses subordonnés
// (directs ou indirects) — la base refuserait ces rattachements (boucle).
export function managersEligibles<T extends { id: string; manager_id: string | null; date_sortie: string | null }>(
  fiches: T[], ficheId: string | null, aujourdhui: string,
): T[] {
  const exclus = new Set<string>();
  if (ficheId) {
    exclus.add(ficheId);
    let ajout = true;
    while (ajout) {
      ajout = false;
      for (const f of fiches) {
        if (f.manager_id && exclus.has(f.manager_id) && !exclus.has(f.id)) {
          exclus.add(f.id);
          ajout = true;
        }
      }
    }
  }
  return fiches.filter((f) => !exclus.has(f.id) && (!f.date_sortie || f.date_sortie >= aujourdhui));
}
