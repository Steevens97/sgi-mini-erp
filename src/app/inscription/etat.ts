// Type partagé entre le formulaire et l'action d'inscription.
// Le nom et l'email sont renvoyés pour être réaffichés après une erreur.
export type EtatInscription = { erreur: string | null; nom: string; email: string };
