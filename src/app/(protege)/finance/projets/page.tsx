import Link from "next/link";
import { exigerAdmin } from "@/lib/session";
import { creerClientAdmin } from "@/lib/supabase/admin";
import { aujourdhuiMartinique } from "@/lib/rh";
import { libelleMode, tarifApplicable, type PeriodeTarif } from "@/lib/finance";
import { dateFr, euros } from "@/lib/format";

export default async function PageTarifsProjets() {
  await exigerAdmin();
  // Tarifs : lus avec la clé secrète après exigerAdmin, affichés à l'administrateur seulement.
  const { data: projets } = await creerClientAdmin().from("projets")
    .select("id, nom, statut, mode_facturation, tarif_vente_ht, tarif_date_effet, tarif_historique, clients(nom)")
    .order("nom");
  const jour = aujourdhuiMartinique();
  return (
    <div className="space-y-4">
      <p className="text-sm"><Link href="/finance" className="underline">← Finance</Link></p>
      <h1 className="text-2xl font-semibold">Tarifs et modes de facturation des projets</h1>
      <p className="text-sm text-slate-600">Tarif horaire de VENTE confirmé par projet, à date d&apos;effet, identique pour tous les
        intervenants du projet. Il est distinct du coût interne des collaborateurs, qui n&apos;est jamais utilisé pour facturer.</p>
      <table className="w-full rounded-lg border border-slate-200 bg-white text-sm">
        <thead className="bg-slate-50 text-left"><tr>
          <th className="p-2">Projet</th><th className="p-2">Client</th><th className="p-2">Mode</th>
          <th className="p-2">Dernier tarif confirmé</th><th className="p-2">Applicable aujourd&apos;hui</th></tr></thead>
        <tbody>
          {(projets ?? []).map((p) => {
            const applicable = tarifApplicable((p.tarif_historique ?? []) as PeriodeTarif[], jour);
            const futur = p.tarif_date_effet && p.tarif_date_effet > jour;
            return (
              <tr key={p.id} data-projet={p.nom} className="border-t border-slate-100">
                <td className="p-2"><Link href={`/finance/projets/${p.id}`} className="font-medium underline">{p.nom}</Link></td>
                <td className="p-2">{(p.clients as unknown as { nom: string } | null)?.nom ?? "—"}</td>
                <td className="p-2">{libelleMode(p.mode_facturation)}</td>
                <td className="p-2">{p.tarif_vente_ht === null ? "Aucun" : (
                  <>{euros(p.tarif_vente_ht)} HT / h à compter du {dateFr(p.tarif_date_effet)}
                    {futur && <span className="ml-1 text-amber-800">(pas encore applicable)</span>}</>)}</td>
                <td className="p-2">{applicable ? `${euros(applicable.tarif)} HT / h` : "Aucun"}</td>
              </tr>
            );
          })}
        </tbody>
      </table>
    </div>
  );
}
