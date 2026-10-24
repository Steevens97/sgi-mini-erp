import Link from "next/link";
import { exigerAdmin } from "@/lib/session";
import { creerClientAdmin } from "@/lib/supabase/admin";
import { LIBELLES_STATUT_FACTURE } from "@/lib/finance";
import { BandeauxFinance } from "./bandeaux";
import { dateFr, euros } from "@/lib/format";

export default async function PageFinance() {
  await exigerAdmin();
  // Lecture avec la clé secrète, après exigerAdmin : aucun jeton utilisateur n'a de droit sur les factures.
  const { data: factures } = await creerClientAdmin().from("factures")
    .select("id, numero, essai, date_emission, periode_debut, periode_fin, total_ttc, statut, pdf_statut, clients(nom)")
    .order("date_emission", { ascending: false }).order("numero", { ascending: false });
  return (
    <div className="space-y-6">
      <div className="flex flex-wrap items-center justify-between gap-3">
        <h1 className="text-2xl font-semibold">Finance</h1>
        <div className="flex gap-2">
          <Link href="/finance/projets" className="rounded-md border border-slate-300 bg-white px-3 py-1.5 text-sm hover:bg-slate-50">
            Tarifs et modes des projets</Link>
          <Link href="/finance/nouvelle" className="rounded-md bg-slate-900 px-3 py-1.5 text-sm font-medium text-white hover:bg-slate-700">
            Nouvelle facture</Link>
        </div>
      </div>
      <BandeauxFinance />
      <table className="w-full rounded-lg border border-slate-200 bg-white text-sm">
        <thead className="bg-slate-50 text-left"><tr>
          <th className="p-2">Numéro</th><th className="p-2">Client</th><th className="p-2">Période</th>
          <th className="p-2 text-right">Total TTC</th><th className="p-2">Statut</th><th className="p-2">PDF</th></tr></thead>
        <tbody>
          {(factures ?? []).map((f) => (
            <tr key={f.id} data-facture={f.numero} className="border-t border-slate-100">
              <td className="p-2"><Link href={`/finance/factures/${f.id}`} className="font-medium underline">{f.numero}</Link>
                {f.essai && <span className="ml-2 rounded bg-amber-100 px-1 text-xs text-amber-900">ESSAI</span>}</td>
              <td className="p-2">{(f.clients as unknown as { nom: string } | null)?.nom}</td>
              <td className="p-2">{dateFr(f.periode_debut)} → {dateFr(f.periode_fin)}</td>
              <td className="p-2 text-right">{euros(f.total_ttc)}</td>
              <td className="p-2">{LIBELLES_STATUT_FACTURE[f.statut] ?? f.statut}</td>
              <td className="p-2">{f.pdf_statut === "disponible" ? "Archivé" : f.pdf_statut === "echec" ? "Échec (à reprendre)" : "À générer"}</td>
            </tr>
          ))}
          {!factures?.length && <tr><td colSpan={6} className="p-3 text-slate-500">Aucune facture.</td></tr>}
        </tbody>
      </table>
    </div>
  );
}
