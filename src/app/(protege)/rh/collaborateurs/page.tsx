import Link from "next/link";
import { lireUtilisateurCourant } from "@/lib/session";
import { creerClientServeur } from "@/lib/supabase/serveur";
import { aujourdhuiMartinique, managersEligibles, nomComplet } from "@/lib/rh";
import { dateFr } from "@/lib/format";
import { FormulaireFiche } from "./formulaire";

// Liste lue avec la session : la base décide (chacun sa fiche, manager et admin toutes).
// Colonnes listées explicitement : le taux horaire n'est jamais lu ici.
export default async function PageCollaborateurs() {
  const moi = await lireUtilisateurCourant();
  const supabase = await creerClientServeur();
  const { data: fiches, error } = await supabase
    .from("collaborateurs")
    .select("id, nom, prenom, email, poste, date_entree, manager_id, date_sortie")
    .order("nom");
  const liste = fiches ?? [];
  const parId = new Map(liste.map((f) => [f.id, f]));
  const aujourdhui = aujourdhuiMartinique();

  return (
    <div className="space-y-6">
      <div>
        <Link href="/rh" className="text-sm text-slate-600 underline">← RH</Link>
        <h1 className="mt-2 text-2xl font-semibold">Collaborateurs</h1>
        <p className="text-sm text-slate-600">Le taux horaire n&apos;apparaît que sur l&apos;écran de modification réservé à l&apos;administrateur.</p>
      </div>
      {error && <p role="alert" className="rounded-md bg-red-50 px-3 py-2 text-sm text-red-700">Lecture impossible : {error.message}</p>}
      <table className="w-full rounded-lg border border-slate-200 bg-white text-sm">
        <thead className="bg-slate-50 text-left">
          <tr><th className="px-3 py-2">Nom</th><th>Poste</th><th>Manager</th><th>Entrée</th><th>Sortie</th><th></th></tr>
        </thead>
        <tbody>
          {liste.map((f) => (
            <tr key={f.id} className="border-t border-slate-100">
              <td className="px-3 py-2 font-medium">{nomComplet(f)}</td>
              <td>{f.poste ?? "—"}</td>
              <td>{f.manager_id ? nomComplet(parId.get(f.manager_id)) : "—"}</td>
              <td>{dateFr(f.date_entree)}</td>
              <td>{f.date_sortie ? dateFr(f.date_sortie) : "—"}</td>
              <td className="pr-3 text-right"><Link href={`/rh/collaborateurs/${f.id}`} className="underline">{moi.role === "admin" ? "Modifier" : "Voir"}</Link></td>
            </tr>
          ))}
          {liste.length === 0 && <tr><td colSpan={6} className="px-3 py-3 text-slate-500">Aucune fiche visible avec vos droits.</td></tr>}
        </tbody>
      </table>
      {moi.role === "admin" && (
        <section>
          <h2 className="mb-2 font-semibold">Nouvelle fiche</h2>
          <FormulaireFiche
            managers={managersEligibles(liste, null, aujourdhui).map((m) => ({ id: m.id, libelle: nomComplet(m) }))}
          />
        </section>
      )}
    </div>
  );
}
