import { creerClientServeur } from "@/lib/supabase/serveur";

// Liste des fiches visibles : c'est la base (règles RLS) qui décide de ce que chacun voit.
export default async function PageRH() {
  const supabase = await creerClientServeur();
  const { data: fiches, error } = await supabase
    .from("collaborateurs")
    .select("id, prenom, nom, poste, email")
    .order("nom");

  return (
    <div>
      <h1 className="text-2xl font-semibold">RH</h1>
      <p className="mt-2 text-slate-600">Fiches collaborateurs visibles avec vos droits.</p>
      {error ? (
        <p role="alert" className="mt-4 rounded-md bg-red-50 px-3 py-2 text-sm text-red-700">
          Lecture impossible : {error.message}
        </p>
      ) : (
        <>
          <p className="mt-4 text-sm text-slate-500">{fiches.length} fiche(s) visible(s)</p>
          <ul className="mt-2 divide-y divide-slate-100 rounded-lg border border-slate-200 bg-white">
            {fiches.map((f) => (
              <li key={f.id} className="px-4 py-3 text-sm">
                <span className="font-medium">{[f.prenom, f.nom].filter(Boolean).join(" ")}</span>
                <span className="text-slate-500"> — {f.poste ?? "poste non renseigné"}</span>
                {f.email && <span className="text-slate-500"> — {f.email}</span>}
              </li>
            ))}
            {fiches.length === 0 && (
              <li className="px-4 py-3 text-sm text-slate-500">Aucune fiche visible.</li>
            )}
          </ul>
        </>
      )}
    </div>
  );
}
