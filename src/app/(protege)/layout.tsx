import { MenuLateral } from "@/components/menu-lateral";
import { lireUtilisateurCourant } from "@/lib/session";

// Toutes les pages de ce groupe exigent une session (redirection sinon).
export default async function MiseEnPageProtegee({ children }: LayoutProps<"/">) {
  const utilisateur = await lireUtilisateurCourant();

  return (
    <div className="flex min-h-screen">
      <MenuLateral email={utilisateur.email} role={utilisateur.role} />
      <div className="flex-1">
        {utilisateur.problemeProfil && (
          <div role="alert" className="border-b border-red-300 bg-red-50 px-8 py-3 text-sm text-red-800">
            <strong>Profil illisible.</strong> {utilisateur.problemeProfil} L&apos;application ne
            peut pas déterminer vos droits : contactez un administrateur.
          </div>
        )}
        {!utilisateur.problemeProfil && !utilisateur.collaborateurId && (
          <div role="alert" className="border-b border-amber-300 bg-amber-50 px-8 py-3 text-sm text-amber-900">
            <strong>Compte non rattaché à une fiche collaborateur.</strong> Tant que ce
            rattachement n&apos;est pas fait, les écrans réservés à « ma fiche » resteront
            vides. Un administrateur peut le faire depuis l&apos;écran Utilisateurs.
          </div>
        )}
        <main className="px-8 py-8">{children}</main>
      </div>
    </div>
  );
}
