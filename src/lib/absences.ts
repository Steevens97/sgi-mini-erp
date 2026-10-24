// Constantes et contrôles partagés du module Absences et notes de frais (fichier ordinaire : un fichier
// "use server" ne peut exporter que des fonctions asynchrones). La base revérifie tout (migration
// 20261028100000) : ces contrôles servent à afficher un message clair AVANT l'envoi.

export const TYPES_ABSENCE = ["conges_payes", "rtt", "sans_solde"] as const;
export type TypeAbsence = (typeof TYPES_ABSENCE)[number];
export const LIBELLES_TYPE_ABSENCE: Record<string, string> = {
  conges_payes: "Congés payés",
  rtt: "RTT",
  sans_solde: "Sans solde",
};
export const LIBELLES_STATUT_CONGE: Record<string, string> = {
  demandee: "Demandée",
  validee: "Validée",
  refusee: "Refusée",
};

export const CATEGORIES_FRAIS = ["deplacement", "repas", "hebergement", "carburant", "fournitures", "autre"] as const;
export const LIBELLES_CATEGORIE_FRAIS: Record<string, string> = {
  deplacement: "Déplacement",
  repas: "Repas",
  hebergement: "Hébergement",
  carburant: "Carburant",
  fournitures: "Fournitures",
  autre: "Autre (précision obligatoire)",
};
export const LIBELLES_STATUT_NOTE: Record<string, string> = {
  soumise: "Soumise",
  validee: "Validée",
  refusee: "Refusée",
  remboursee: "Remboursée (déclarée)",
};

export const LIBELLES_EVENEMENT_ABSENCES: Record<string, string> = {
  demande: "Demande",
  validation: "Validation",
  refus: "Refus",
  soumission: "Dépôt de la note",
  modification: "Modification (note soumise)",
  remboursement_declare: "Remboursement déclaré",
  remboursement_corrige: "Déclaration de remboursement corrigée",
  remboursement_annule: "Déclaration de remboursement annulée",
  initial: "Solde initial",
  ajustement: "Ajustement motivé",
  prelevement: "Prélèvement à la validation",
};

export type EvenementAbsences = {
  action: string;
  le: string | null;
  auteur: string | null;
  auteur_nom: string | null;
  motif: string | null;
  type?: string;
  avant?: unknown;
  apres?: unknown;
  jours?: number;
  rembourse_le?: string | null;
  reference?: string | null;
};

// Limites des justificatifs : identiques au bucket (10 Mo, PDF/JPEG/PNG) et à la base.
export const TAILLE_MAX_JUSTIFICATIF = 10 * 1024 * 1024;
export const TYPES_JUSTIFICATIF: Record<string, string> = {
  "application/pdf": "pdf",
  "image/jpeg": "jpg",
  "image/png": "png",
};

// Signature réelle du contenu (les premiers octets), jamais le type ni le nom déclarés par le navigateur.
const SIGNATURES: Record<string, number[]> = {
  "application/pdf": [0x25, 0x50, 0x44, 0x46, 0x2d], // %PDF-
  "image/jpeg": [0xff, 0xd8, 0xff],
  "image/png": [0x89, 0x50, 0x4e, 0x47, 0x0d, 0x0a, 0x1a, 0x0a],
};
export function signatureConforme(type: string, octets: Uint8Array): boolean {
  const s = SIGNATURES[type];
  return !!s && octets.length >= s.length && s.every((b, i) => octets[i] === b);
}
export function typeSelonSignature(octets: Uint8Array): string | null {
  return Object.keys(SIGNATURES).find((t) => signatureConforme(t, octets)) ?? null;
}

// Chemin d'un justificatif : <fiche>/<identifiant aléatoire>.<extension>, comme l'exige la base.
const UUID = "[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}";
export function cheminConforme(chemin: string, collaborateurId: string, type: string): boolean {
  const ext = TYPES_JUSTIFICATIF[type];
  return !!ext && new RegExp(`^${collaborateurId}/${UUID}\\.${ext}$`).test(chemin);
}

// Demi-journées (même calcul que la base) : nombre maximal de jours d'une période.
export function joursMaximum(debut: string, fin: string, apresMidi: boolean, finMidi: boolean): number | null {
  if (!debut || !fin || fin < debut) return null;
  const jours = Math.round((Date.parse(`${fin}T12:00:00Z`) - Date.parse(`${debut}T12:00:00Z`)) / 86400000);
  const demi = jours * 2 + 2 - (apresMidi ? 1 : 0) - (finMidi ? 1 : 0);
  return demi > 0 ? demi / 2 : null;
}

// Estimation INDICATIVE : jours du lundi au vendredi (jours fériés non déduits : aucun calendrier dans
// cette version). Elle ne remplace jamais le nombre saisi, qui seul est enregistré.
export function estimationJoursOuvres(debut: string, fin: string, apresMidi: boolean, finMidi: boolean): number | null {
  if (!joursMaximum(debut, fin, apresMidi, finMidi)) return null;
  let total = 0;
  for (let d = new Date(`${debut}T12:00:00Z`); d.toISOString().slice(0, 10) <= fin; d.setUTCDate(d.getUTCDate() + 1)) {
    const iso = d.toISOString().slice(0, 10);
    if (d.getUTCDay() === 0 || d.getUTCDay() === 6) continue;
    total += 1;
    if (iso === debut && apresMidi) total -= 0.5;
    if (iso === fin && finMidi) total -= 0.5;
  }
  return total;
}

// Contrôle de saisie d'une demande. Renvoie un message (refus) ou null.
export function controlerDemande(v: { debut: string; fin: string; apresMidi: boolean; finMidi: boolean; jours: string }): string | null {
  if (!v.debut || !v.fin) return "Dates de début et de fin obligatoires.";
  if (v.fin < v.debut) return "La date de fin précède la date de début.";
  if (v.debut === v.fin && v.apresMidi && v.finMidi) {
    return "Demi-journées incohérentes : une absence d'un seul jour ne peut pas commencer l'après-midi et finir à midi.";
  }
  if (!/^[0-9]+([.,][0-9]+)?$/.test(v.jours)) return "Nombre de jours : nombre positif, par demi-journée (ex. 1,5).";
  const n = Number(v.jours.replace(",", "."));
  if (n <= 0) return "Le nombre de jours doit être strictement positif.";
  if (Math.round(n * 2) !== n * 2) return "Le nombre de jours se saisit par demi-journée (pas de 0,5).";
  const max = joursMaximum(v.debut, v.fin, v.apresMidi, v.finMidi);
  if (max !== null && n > max) {
    return `Le nombre de jours (${nombreFr(n)}) dépasse la période demandée (${nombreFr(max)} jour(s) au plus, demi-journées comprises).`;
  }
  return null;
}

// Montant TTC : strictement positif, 2 décimales au plus (la colonne arrondirait en silence).
export function lireMontant(saisie: string | null): number | string {
  if (!saisie) return "Le montant TTC est obligatoire.";
  if (!/^[0-9]+([.,][0-9]{1,2})?$/.test(saisie)) return "Montant TTC : nombre positif, au plus 2 décimales (ex. 42,50).";
  const m = Number(saisie.replace(",", "."));
  if (m <= 0) return "Le montant TTC doit être strictement positif.";
  if (m >= 1e8) return "Le montant saisi est trop élevé.";
  return m;
}

// Solde saisi par l'administrateur : positif ou nul, 2 décimales au plus.
export function lireSolde(saisie: string | null): number | string {
  if (saisie === null || saisie === "") return "Le nouveau solde est obligatoire (0 si c'est la vraie valeur).";
  if (!/^[0-9]+([.,][0-9]{1,2})?$/.test(saisie)) return "Solde : nombre de jours positif ou nul, au plus 2 décimales.";
  const s = Number(saisie.replace(",", "."));
  if (s >= 10000) return "Solde : moins de 10 000 jours.";
  return s;
}

export const nombreFr = (n: number | string | null | undefined) =>
  n === null || n === undefined ? "—" : String(Number(n)).replace(".", ",");

export function periodeFr(c: { date_debut: string; date_fin: string; debut_apres_midi: boolean; fin_midi: boolean }): string {
  const f = (iso: string) => iso.split("-").reverse().join("/");
  const debut = `${f(c.date_debut)}${c.debut_apres_midi ? " (après-midi)" : ""}`;
  const fin = `${f(c.date_fin)}${c.fin_midi ? " (midi)" : ""}`;
  return c.date_debut === c.date_fin && !c.debut_apres_midi && !c.fin_midi ? f(c.date_debut)
    : c.date_debut === c.date_fin ? `${f(c.date_debut)} ${c.debut_apres_midi ? "après-midi" : "matin"}`
    : `du ${debut} au ${fin}`;
}

// Messages de contraintes de la base traduits (les messages des déclencheurs sont déjà en français).
const CONTRAINTES: Record<string, string> = {
  conges_periode_coherente: "Période incohérente (demi-journées ou dates).",
  conges_nb_jours_demi_journees: "Nombre de jours : strictement positif, par demi-journée, dans la limite de la période.",
  collaborateurs_soldes_positifs: "Solde insuffisant : un solde ne peut pas devenir négatif.",
  notes_de_frais_justificatif_unique: "Justificatif déjà rattaché à une autre note de frais.",
  notes_de_frais_categorie_prevue: "Catégorie inconnue ou précision manquante pour « autre ».",
  notes_de_frais_objet_renseigne: "L'objet de la dépense est obligatoire (300 caractères au plus).",
  notes_de_frais_montant_positif: "Le montant TTC doit être strictement positif.",
};
export function messageBaseAbsences(message: string | null | undefined): string {
  const m = message ?? "Erreur inconnue.";
  for (const [nom, texte] of Object.entries(CONTRAINTES)) if (m.includes(nom)) return texte;
  if (/permission denied|row-level security/i.test(m)) return "Action non autorisée avec vos droits.";
  return m;
}

// Confirmations affichées en haut de page après une décision : la ligne concernée change de section (elle quitte
// « À décider »), le message du formulaire disparaîtrait avec elle. Code transmis dans l'adresse, texte fixe.
export const CONFIRMATIONS_ABSENCES: Record<string, string> = {
  conge_valide: "Demande validée ; le solde est prélevé une seule fois.",
  conge_refuse: "Demande refusée (motif enregistré) ; ses dates sont libérées.",
  conge_deja: "Décision déjà enregistrée : rien n'a été modifié (aucun second prélèvement).",
  solde: "Solde ajusté ; l'ancienne valeur, la nouvelle et le motif sont dans l'historique.",
  note_validee: "Note validée : son contenu et son justificatif sont désormais figés.",
  note_refusee: "Note refusée (motif enregistré).",
  note_deja: "Décision déjà enregistrée : rien n'a été modifié.",
  remboursement: "Remboursement déclaré (aucun virement n'est effectué par l'application).",
  remboursement_deja: "Remboursement déjà déclaré avec ces valeurs : rien n'a été modifié.",
  correction: "Déclaration de remboursement corrigée ; les valeurs précédentes restent dans l'historique.",
  annulation: "Déclaration annulée : la note redevient « validée » ; l'historique garde les valeurs précédentes.",
};
