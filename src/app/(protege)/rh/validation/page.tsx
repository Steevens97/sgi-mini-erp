import Link from "next/link";
import { redirect } from "next/navigation";
import { lireUtilisateurCourant } from "@/lib/session";
import { creerClientServeur } from "@/lib/supabase/serveur";
import { nomComplet, type EvenementTemps } from "@/lib/rh";
import { dateFr } from "@/lib/format";
import { FormulaireAction, champ } from "../../commercial/composants";
import { changerStatutTemps } from "../actions";
import { Historique } from "../historique";

// Ne sont proposés que les temps que la personne peut réellement valider (la base revérifie) :
// manager → équipe directe (manager_id = sa fiche) ; admin → tous les autres. Jamais ses propres temps.
export default async function PageValidation() {
  const moi = await lireUtilisateurCourant();
  if (moi.role !== "admin" && moi.role !== "manager") redirect("/rh");
  const supabase = await creerClientServeur();
  const [{ data: fiches }, { data: projets }, { data: temps }] = await Promise.all([
    supabase.from("collaborateurs").select("id, nom, prenom, manager_id"),
    supabase.from("projets").select("id, nom"),
    supabase.from("temps")
      .select("id, collaborateur_id, projet_id, date_saisie, heures, commentaire, statut, facture_id, saisi_par_nom, valide_par_nom, valide_le, historique")
      .in("statut", ["soumis", "valide"]).order("date_saisie"),
  ]);
  const parId = new Map((fiches ?? []).map((f) => [f.id, f]));
  const nomProjet = new Map((projets ?? []).map((p) => [p.id, p.nom]));
  const peutValider = (collaborateurId: string) =>
    collaborateurId !== moi.collaborateurId &&
    (moi.role === "admin" || (!!moi.collaborateurId && parId.get(collaborateurId)?.manager_id === moi.collaborateurId));
  const aValider = (temps ?? []).filter((t) => t.statut === "soumis" && peutValider(t.collaborateur_id));
  const mesSoumis = (temps ?? []).filter((t) => t.statut === "soumis" && t.collaborateur_id === moi.collaborateurId);
  const valides = moi.role === "admin" ? (temps ?? []).filter((t) => t.statut === "valide" && !t.facture_id) : [];

  const ligne = (t: (typeof aValider)[number]) => (
    <>
      <td className="px-3 py-2">{nomComplet(parId.get(t.collaborateur_id))}</td>
      <td>{dateFr(t.date_saisie)}</td>
      <td>{nomProjet.get(t.projet_id) ?? "—"}{t.commentaire ? <span className="block text-xs text-slate-500">{t.commentaire}</span> : null}</td>
      <td>{String(t.heures).replace(".", ",")}</td>
      <td>{t.saisi_par_nom ?? <span className="text-slate-500">inconnu</span>}</td>
    </>
  );
  return (
    <div className="space-y-6">
      <div>
        <Link href="/rh" className="text-sm text-slate-600 underline">← RH</Link>
        <h1 className="mt-2 text-2xl font-semibold">Validation des temps</h1>
        <p className="text-sm text-slate-600">
          {moi.role === "admin" ? "Administrateur : temps soumis de tous les autres collaborateurs." : "Manager : temps soumis de votre équipe directe."}{" "}
          Personne ne valide ses propres temps.
        </p>
      </div>
      <section>
        <h2 className="mb-2 font-semibold">À valider ({aValider.length})</h2>
        <table className="w-full rounded-lg border border-slate-200 bg-white text-sm">
          <thead className="bg-slate-50 text-left"><tr><th className="px-3 py-2">Collaborateur</th><th>Date</th><th>Projet</th><th>Heures</th><th>Saisi par</th><th>Décision</th></tr></thead>
          <tbody>
            {aValider.map((t) => (
              <tr key={t.id} className="border-t border-slate-100 align-top" data-temps={t.id}>
                {ligne(t)}
                <td className="space-y-1 py-2 pr-3">
                  <FormulaireAction action={changerStatutTemps} caches={{ temps_id: t.id, action: "valider" }} libelle="Valider" principal />
                  <FormulaireAction action={changerStatutTemps} caches={{ temps_id: t.id, action: "renvoyer" }} libelle="Renvoyer" className="flex gap-1">
                    <input name="motif" required placeholder="motif du renvoi" className={`${champ} mt-0 w-40`} />
                  </FormulaireAction>
                  <Historique evenements={t.historique as EvenementTemps[]} />
                </td>
              </tr>
            ))}
            {!aValider.length && <tr><td colSpan={6} className="px-3 py-3 text-slate-500">Aucun temps à valider.</td></tr>}
          </tbody>
        </table>
      </section>
      {mesSoumis.length > 0 && (
        <p role="note" className="rounded-md bg-slate-50 px-3 py-2 text-sm text-slate-700">
          Vos propres temps soumis ({mesSoumis.length}) ne figurent pas ici : ils sont validés par votre responsable
          {moi.role === "admin" ? " — sans responsable désigné, ils restent « soumis » (l'attestation éventuelle n'est pas une validation)" : " ou par l'administrateur"}.
        </p>
      )}
      {moi.role === "admin" && (
        <section>
          <h2 className="mb-2 font-semibold">Temps validés non facturés ({valides.length})</h2>
          <table className="w-full rounded-lg border border-slate-200 bg-white text-sm">
            <thead className="bg-slate-50 text-left"><tr><th className="px-3 py-2">Collaborateur</th><th>Date</th><th>Projet</th><th>Heures</th><th>Saisi par</th><th>Validation</th></tr></thead>
            <tbody>
              {valides.map((t) => (
                <tr key={t.id} className="border-t border-slate-100 align-top" data-temps={t.id}>
                  {ligne(t)}
                  <td className="space-y-1 py-2 pr-3">
                    <span className="block text-xs">{t.valide_par_nom ? `par ${t.valide_par_nom}, ${dateFr(t.valide_le)}` : "validation antérieure (inconnue)"}</span>
                    <FormulaireAction action={changerStatutTemps} caches={{ temps_id: t.id, action: "rouvrir" }} libelle="Rouvrir" className="flex gap-1">
                      <input name="motif" required placeholder="motif de correction" className={`${champ} mt-0 w-40`} />
                    </FormulaireAction>
                    <Historique evenements={t.historique as EvenementTemps[]} />
                  </td>
                </tr>
              ))}
            </tbody>
          </table>
        </section>
      )}
    </div>
  );
}
