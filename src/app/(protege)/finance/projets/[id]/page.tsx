import Link from "next/link";
import { notFound } from "next/navigation";
import { exigerAdmin } from "@/lib/session";
import { creerClientAdmin } from "@/lib/supabase/admin";
import { aujourdhuiMartinique, LIBELLES_STATUT_TEMPS } from "@/lib/rh";
import { libelleMode, periodesActives, tarifApplicable, type PeriodeTarif } from "@/lib/finance";
import { dateFr, euros } from "@/lib/format";
import { champ } from "../../../commercial/composants";
import { FormulaireMode, FormulaireTarif } from "../../composants";

type Concernes = {
  nb: number; heures: number; empreinte: string; deja_factures: number;
  liste: { id: string; date: string; heures: number; statut: string; collaborateur: string }[];
};
const l = "block text-sm font-medium text-slate-700";

export default async function PageTarifProjet({ params, searchParams }: {
  params: Promise<{ id: string }>;
  searchParams: Promise<Record<string, string | undefined>>;
}) {
  await exigerAdmin();
  const { id } = await params;
  const sp = await searchParams;
  const admin = creerClientAdmin();
  const { data: p } = await admin.from("projets")
    .select("id, nom, mode_facturation, tarif_vente_ht, tarif_date_effet, tarif_reference, tarif_historique, clients(nom)")
    .eq("id", id).maybeSingle();
  if (!p) notFound();
  const historique = (p.tarif_historique ?? []) as PeriodeTarif[];
  const actives = periodesActives(historique);
  const derniere = actives.at(-1) ?? null;
  const remplacees = new Set(historique.map((e) => e.remplace).filter(Boolean));
  const jour = aujourdhuiMartinique();
  const applicable = tarifApplicable(historique, jour);
  const { count: factures } = await admin.from("temps").select("id", { count: "exact", head: true })
    .eq("projet_id", id).not("facture_id", "is", null);

  // Étape de vérification : liste des temps NON facturés que le tarif toucherait (à partir de sa date d'effet).
  const correction = sp.correction === "1" && derniere;
  const dateEffet = correction ? derniere.date_effet : sp.date_effet;
  let concernes: Concernes | null = null;
  if (dateEffet && /^\d{4}-\d{2}-\d{2}$/.test(dateEffet)) {
    const { data } = await admin.rpc("finance_temps_concernes", { p_projet: id, p_date_effet: dateEffet });
    concernes = data as Concernes;
  }

  return (
    <div className="space-y-5">
      <p className="text-sm"><Link href="/finance/projets" className="underline">← Tarifs et modes des projets</Link></p>
      <h1 className="text-2xl font-semibold">{p.nom}</h1>
      <p className="text-sm text-slate-600">Client : {(p.clients as unknown as { nom: string } | null)?.nom ?? "—"}</p>

      <section className="space-y-2">
        <h2 className="font-semibold">Mode de facturation : {libelleMode(p.mode_facturation)}</h2>
        {(factures ?? 0) > 0 ? <p className="text-sm text-slate-600">Figé : des temps de ce projet sont déjà facturés.</p> : (
          <FormulaireMode projetId={p.id} mode={p.mode_facturation} />
        )}
      </section>

      <section className="space-y-2">
        <h2 className="font-semibold">Tarif horaire de vente</h2>
        <p className="text-sm" data-dernier-tarif>
          {derniere
            ? <>Dernier tarif confirmé : <strong>{euros(derniere.tarif)} HT / h</strong> à compter du {dateFr(derniere.date_effet)} (réf. {derniere.reference})
                {derniere.date_effet > jour && <span className="ml-1 text-amber-800">— pas encore applicable</span>}</>
            : "Aucun tarif confirmé : projet non facturable."}
        </p>
        <p className="text-sm" data-tarif-applicable>
          Applicable aujourd&apos;hui ({dateFr(jour)}) : {applicable ? `${euros(applicable.tarif)} HT / h` : "aucun"}.
          Chaque temps est facturé au tarif contractuel en vigueur à sa date travaillée.</p>
        <table className="w-full rounded-lg border border-slate-200 bg-white text-sm">
          <thead className="bg-slate-50 text-left"><tr><th className="p-2">Événement</th><th className="p-2">Tarif</th>
            <th className="p-2">À compter du</th><th className="p-2">Référence</th><th className="p-2">Par</th><th className="p-2">État</th></tr></thead>
          <tbody>
            {historique.map((e) => (
              <tr key={e.id} className="border-t border-slate-100">
                <td className="p-2">{e.type === "correction" ? `Correction (motif : ${e.motif})` : "Confirmation"}
                  <span className="block text-xs text-slate-500">{e.temps_concernes} temps non facturé(s) concerné(s) à la confirmation</span></td>
                <td className="p-2">{euros(e.tarif)} HT / h</td><td className="p-2">{dateFr(e.date_effet)}</td>
                <td className="p-2">{e.reference}</td><td className="p-2">{e.par_nom}, le {dateFr(e.le)}</td>
                <td className="p-2">{remplacees.has(e.id) ? "Remplacé par une correction (conservé, non appliqué)" : "En vigueur"}</td>
              </tr>
            ))}
            {!historique.length && <tr><td colSpan={6} className="p-2 text-slate-500">Aucun événement.</td></tr>}
          </tbody>
        </table>
      </section>

      <section className="space-y-2">
        <h2 className="font-semibold">{correction ? "Corriger le dernier tarif (erreur de saisie)" : "Confirmer un nouveau tarif"}</h2>
        {!concernes ? (
          <form method="get" className="flex flex-wrap items-end gap-3 rounded-lg border border-slate-200 bg-white p-4">
            <label className={l}>Date d&apos;effet *<input type="date" name="date_effet" required className={champ} /></label>
            <button type="submit" className="rounded-md border border-slate-300 bg-white px-3 py-1.5 text-sm">Vérifier les temps concernés</button>
            {derniere && (factures ?? 0) === 0 && (
              <Link href={`?correction=1`} className="text-sm underline">Corriger plutôt le dernier tarif</Link>)}
          </form>
        ) : (
          <>
            <p className="text-sm">
              {correction ? "Période corrigée" : "Nouveau tarif"} à compter du <strong>{dateFr(dateEffet)}</strong>.{" "}
              {concernes.deja_factures > 0 && <span className="text-red-700">{concernes.deja_factures} temps déjà facturé(s) à partir de cette date :
                la base refusera (aucun changement rétroactif d&apos;un temps facturé). </span>}
              Temps non facturés concernés : <strong>{concernes.nb}</strong> ({String(concernes.heures).replace(".", ",")} h).
            </p>
            {concernes.nb > 0 && (
              <ul className="list-disc pl-5 text-sm" data-temps-concernes>
                {concernes.liste.map((t) => <li key={t.id}>{dateFr(t.date)} — {t.collaborateur} — {String(t.heures).replace(".", ",")} h
                  ({LIBELLES_STATUT_TEMPS[t.statut] ?? t.statut})</li>)}
              </ul>
            )}
            <FormulaireTarif projetId={p.id} empreinte={concernes.empreinte} nbTemps={concernes.nb} dateEffet={dateEffet!}
              dateEffetFr={dateFr(dateEffet)} correction={correction ? { periodeId: derniere.id, reference: derniere.reference } : null} />
            <Link href={`/finance/projets/${p.id}`} className="text-sm underline">Annuler</Link>
          </>
        )}
      </section>
    </div>
  );
}
