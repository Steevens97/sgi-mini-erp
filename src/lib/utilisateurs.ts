// Constantes et types partagés de l'écran Utilisateurs (fichier ordinaire :
// un fichier "use server" ne peut exporter que des fonctions asynchrones).
import type { Role } from "@/lib/navigation";

export const ROLES_ATTRIBUABLES: Role[] = ["collaborateur", "manager", "admin"];

// Comptes qu'aucune action de l'écran ne peut révoquer, rétrograder ni réinitialiser.
export const COMPTES_PROTEGES = ["sgi@gmx.fr"];

export function estCompteProtege(email: string | null | undefined): boolean {
  return !!email && COMPTES_PROTEGES.includes(email.toLowerCase());
}

// Indicateur posé dans app_metadata (modifiable uniquement avec la clé secrète).
export const INDICATEUR_CHANGEMENT_MDP = "doit_changer_mot_de_passe";

export type EtatAction = {
  statut: "succes" | "erreur" | null;
  message: string;
  // Présents une seule fois, juste après une création d'accès ou une réinitialisation.
  motDePasseProvisoire?: string;
  emailCompte?: string;
};

export const ETAT_INITIAL: EtatAction = { statut: null, message: "" };
