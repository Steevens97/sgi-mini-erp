import Link from "next/link";
import { connection } from "next/server";
import { unCompteExisteDeja } from "./comptes";
import { FormulaireInscription } from "./formulaire-inscription";

// PAGE TEMPORAIRE : sert une seule fois à créer le compte administrateur,
// puis elle est supprimée du code.
export const metadata = { title: "Premier compte — Mini-ERP SGI" };

export default async function PageInscription() {
  // Revérifie à chaque visite (sinon la page serait figée au moment de la construction).
  await connection();
  const fermee = await unCompteExisteDeja();

  return (
    <main className="flex min-h-screen items-center justify-center px-4">
      <div className="w-full max-w-sm rounded-xl border border-slate-200 bg-white p-8 shadow-sm">
        <h1 className="text-xl font-semibold">Création du premier compte</h1>
        {fermee ? (
          <>
            <p className="mt-3 rounded-md bg-amber-50 px-3 py-2 text-sm text-amber-900">
              L&apos;inscription est fermée : un compte existe déjà.
            </p>
            <Link href="/connexion" className="mt-4 inline-block text-sm text-slate-700 underline">
              Aller à la connexion
            </Link>
          </>
        ) : (
          <>
            <p className="mb-6 mt-1 text-sm text-slate-500">
              Ce compte sera administrateur. Cette page ne sert qu&apos;une fois.
            </p>
            <FormulaireInscription />
          </>
        )}
      </div>
    </main>
  );
}
