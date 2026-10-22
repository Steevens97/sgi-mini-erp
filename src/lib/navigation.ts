// Constantes partagées (fichier ordinaire : un fichier "use server" ne peut
// exporter que des fonctions asynchrones).

export type Role = "admin" | "manager" | "collaborateur";

export const LIBELLES_ROLES: Record<Role, string> = {
  admin: "Administrateur",
  manager: "Manager",
  collaborateur: "Collaborateur",
};

export type EntreeMenu = {
  libelle: string;
  chemin: string;
  adminSeulement: boolean;
};

// Ordre imposé : Accueil, Commercial, RH, Finance, Absences, Utilisateurs.
export const ENTREES_MENU: EntreeMenu[] = [
  { libelle: "Accueil", chemin: "/", adminSeulement: false },
  { libelle: "Commercial", chemin: "/commercial", adminSeulement: false },
  { libelle: "RH", chemin: "/rh", adminSeulement: false },
  { libelle: "Finance", chemin: "/finance", adminSeulement: true },
  { libelle: "Absences", chemin: "/absences", adminSeulement: false },
  { libelle: "Utilisateurs", chemin: "/utilisateurs", adminSeulement: true },
];

// Pages accessibles sans être connecté.
export const PAGES_PUBLIQUES = ["/connexion"];
