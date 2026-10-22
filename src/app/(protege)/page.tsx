import { lireUtilisateurCourant } from "@/lib/session";
import { LIBELLES_ROLES } from "@/lib/navigation";

export default async function PageAccueil() {
  const utilisateur = await lireUtilisateurCourant();

  return (
    <div>
      <h1 className="text-2xl font-semibold">Accueil</h1>
      <p className="mt-2 text-slate-600">
        Bienvenue{utilisateur.nom ? `, ${utilisateur.nom}` : ""}. Vous êtes connecté en tant
        que {utilisateur.role ? LIBELLES_ROLES[utilisateur.role].toLowerCase() : "rôle inconnu"}.
      </p>
    </div>
  );
}
