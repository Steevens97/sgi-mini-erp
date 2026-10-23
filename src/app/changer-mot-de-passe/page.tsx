import Link from "next/link";
import { redirect } from "next/navigation";
import { creerClientServeur } from "@/lib/supabase/serveur";
import { INDICATEUR_CHANGEMENT_MDP } from "@/lib/utilisateurs";
import { seDeconnecter } from "@/app/connexion/actions";
import { FormulaireChangementMotDePasse } from "./formulaire";

export const metadata = { title: "Mot de passe — Mini-ERP SGI" };

export default async function PageChangerMotDePasse() {
  const supabase = await creerClientServeur();
  const {
    data: { user },
  } = await supabase.auth.getUser();
  if (!user) redirect("/connexion");
  const obligatoire = user.app_metadata?.[INDICATEUR_CHANGEMENT_MDP] === true;

  return (
    <main className="flex min-h-screen items-center justify-center px-4">
      <div className="w-full max-w-sm rounded-xl border border-slate-200 bg-white p-8 shadow-sm">
        <h1 className="text-xl font-semibold">
          {obligatoire ? "Choisissez votre mot de passe" : "Changer mon mot de passe"}
        </h1>
        <p className="mb-6 mt-1 text-sm text-slate-500">
          {obligatoire
            ? `Compte ${user.email} : le mot de passe provisoire doit être remplacé avant d'accéder à l'application.`
            : `Compte ${user.email}.`}
        </p>
        <FormulaireChangementMotDePasse />
        <div className="mt-4 flex justify-between text-sm">
          {!obligatoire ? (
            <Link href="/" className="text-slate-700 underline">
              Retour
            </Link>
          ) : (
            <span />
          )}
          <form action={seDeconnecter}>
            <button type="submit" className="text-slate-700 underline">
              Se déconnecter
            </button>
          </form>
        </div>
      </div>
    </main>
  );
}
