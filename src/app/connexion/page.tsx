import { FormulaireConnexion } from "./formulaire-connexion";

export const metadata = { title: "Connexion — Mini-ERP SGI" };

export default function PageConnexion() {
  return (
    <main className="flex min-h-screen items-center justify-center px-4">
      <div className="w-full max-w-sm rounded-xl border border-slate-200 bg-white p-8 shadow-sm">
        <h1 className="text-xl font-semibold">Mini-ERP SGI</h1>
        <p className="mb-6 mt-1 text-sm text-slate-500">Connectez-vous pour continuer.</p>
        <FormulaireConnexion />
      </div>
    </main>
  );
}
