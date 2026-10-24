import Link from "next/link";
import { exigerAdmin } from "@/lib/session";
import { creerClientServeur } from "@/lib/supabase/serveur";
import { nomComplet } from "@/lib/rh";
import { CONFIRMATIONS_ABSENCES, nombreFr, type EvenementAbsences } from "@/lib/absences";
import { FormulaireAction, champ } from "../../commercial/composants";
import { ajusterSolde } from "../actions";
import { HistoriqueAbsences } from "../historique";

// Administrateur : vue globale des soldes et ajustements motivés (jamais sur sa propre fiche). La valeur affichée est
// renvoyée avec l'ajustement : si le solde a changé entre-temps (validation simultanée), la base refuse.
export default async function PageSoldes({ searchParams }: { searchParams: Promise<{ confirmation?: string }> }) {
  const confirmation = CONFIRMATIONS_ABSENCES[(await searchParams).confirmation ?? ""];
  const moi = await exigerAdmin();
  const supabase = await creerClientServeur();
  const { data } = await supabase.from("absences_soldes")
    .select("id, nom, prenom, date_sortie, solde_conges, solde_rtt, droits_rtt_renseignes, historique_soldes").order("nom");
  const soldes = (data ?? []) as { id: string; nom: string; prenom: string | null; date_sortie: string | null; solde_conges: number;
    solde_rtt: number; droits_rtt_renseignes: boolean; historique_soldes: EvenementAbsences[] }[];
  return (
    <div className="space-y-6">
      {confirmation && <p role="status" data-confirmation className="rounded-md border border-emerald-300 bg-emerald-50 p-3 text-sm text-emerald-800">{confirmation}</p>}
      <div>
        <Link href="/absences" className="text-sm text-slate-600 underline">← Absences</Link>
        <h1 className="mt-2 text-2xl font-semibold">Soldes et ajustements</h1>
        <p className="mt-1 text-sm text-slate-600">
          Aucune acquisition automatique : chaque ajustement est saisi ici avec un motif et reste dans l&apos;historique.
          RTT « droits non renseignés » : aucune valeur n&apos;a encore été renseignée (ce n&apos;est pas une absence de droits).
          Vous ne pouvez pas ajuster votre propre solde.
        </p>
      </div>
      <table className="w-full rounded-lg border border-slate-200 bg-white text-sm [&_td]:pr-3 [&_th]:pr-3">
        <thead className="bg-slate-50 text-left"><tr><th className="px-3 py-2">Collaborateur</th><th>Congés payés</th><th>RTT</th><th>Ajustement</th></tr></thead>
        <tbody>
          {soldes.map((s) => (
            <tr key={s.id} className="border-t border-slate-100 align-top" data-fiche={s.id}>
              <td className="px-3 py-2">{nomComplet(s)}{s.date_sortie && <span className="block text-xs text-slate-500">sortie le {s.date_sortie.split("-").reverse().join("/")}</span>}</td>
              <td>{nombreFr(s.solde_conges)} j</td>
              <td>{s.droits_rtt_renseignes ? `${nombreFr(s.solde_rtt)} j` : <span className="text-amber-800">droits non renseignés</span>}</td>
              <td className="space-y-1 py-2 pr-3">
                {s.id === moi.collaborateurId ? (
                  <p className="text-xs text-slate-600">Votre propre fiche : ajustement par un autre administrateur uniquement.</p>
                ) : (
                  <FormulaireAction action={ajusterSolde} caches={{ collaborateur_id: s.id, ancien_cp: String(s.solde_conges), ancien_rtt: String(s.solde_rtt) }}
                    libelle="Ajuster" className="flex flex-wrap items-end gap-1">
                    <select name="type" aria-label="Solde à ajuster" className={`${champ} mt-0 w-36`}>
                      <option value="conges_payes">Congés payés</option>
                      <option value="rtt">RTT</option>
                    </select>
                    <input name="nouveau" required type="number" min="0" step="0.01" aria-label="Nouveau solde" placeholder="nouveau solde" className={`${champ} mt-0 w-32`} />
                    <input name="motif" required aria-label="Motif" placeholder="motif (obligatoire)" className={`${champ} mt-0 w-56`} />
                  </FormulaireAction>
                )}
                <HistoriqueAbsences evenements={s.historique_soldes} soldes titre="Historique des soldes" />
              </td>
            </tr>
          ))}
        </tbody>
      </table>
    </div>
  );
}
