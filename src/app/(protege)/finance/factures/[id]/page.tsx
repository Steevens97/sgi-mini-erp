import Link from "next/link";
import { notFound } from "next/navigation";
import { exigerAdmin } from "@/lib/session";
import { creerClientAdmin } from "@/lib/supabase/admin";
import { aujourdhuiMartinique } from "@/lib/rh";
import { libelleTraitement } from "@/lib/tva";
import { CONFIRMATIONS_FACTURE, LIBELLES_EVENEMENT_FACTURE, LIBELLES_STATUT_FACTURE, MODES_REGLEMENT, type Calcul } from "@/lib/finance";
import { LIBELLES_CANAL, dateFr, euros } from "@/lib/format";
import { FormulaireAction } from "../../../commercial/composants";
import { FormulaireCorrectionReglement, FormulaireEnvoi, FormulaireReglement } from "../../composants";
import { reprendrePdf } from "../../actions";

type Evenement = { action: string; le: string; auteur_nom?: string; motif?: string; canal?: string; destinataire?: string;
                   date_reglement?: string; mode?: string; reference?: string; erreur?: string; precedent?: Record<string, string | null> };
const h = (n: number | string) => String(Number(n)).replace(".", ",");

export default async function PageFacture({ params, searchParams }: {
  params: Promise<{ id: string }>; searchParams: Promise<{ confirmation?: string }>;
}) {
  await exigerAdmin();
  const { id } = await params;
  const confirmation = CONFIRMATIONS_FACTURE[(await searchParams).confirmation ?? ""];
  // Clé secrète après exigerAdmin : la facture, son instantané et ses tarifs ne sont lisibles par aucun jeton.
  const { data: f } = await creerClientAdmin().from("factures")
    .select("id, numero, essai, statut, date_emission, date_echeance, total_ht, tva, total_ttc, pdf_statut, pdf_erreur, date_envoi, date_reglement, mode_reglement, reference_reglement, emise_par_nom, historique, instantane_emission")
    .eq("id", id).maybeSingle();
  if (!f) notFound();
  const inst = f.instantane_emission as unknown as Calcul & { periode: { debut: string; fin: string } };
  const jour = aujourdhuiMartinique();
  const historique = (f.historique ?? []) as Evenement[];
  return (
    <div className="space-y-5">
      <p className="text-sm"><Link href="/finance" className="underline">← Finance</Link></p>
      {confirmation && <p role="status" data-confirmation className="rounded-md border border-emerald-300 bg-emerald-50 p-3 text-sm text-emerald-800">{confirmation}</p>}
      <h1 className="text-2xl font-semibold" data-numero>Facture {f.numero} {f.essai && <span className="text-amber-800">(ESSAI — SANS VALEUR)</span>}</h1>
      <p className="text-sm">Statut : <strong data-statut>{LIBELLES_STATUT_FACTURE[f.statut] ?? f.statut}</strong> — émise le {dateFr(f.date_emission)} par {f.emise_par_nom} —
        échéance : {dateFr(f.date_echeance)}</p>
      <p className="text-sm">Client : <strong>{inst.client?.nom}</strong> — période du {dateFr(inst.periode.debut)} au {dateFr(inst.periode.fin)} —
        TVA : {libelleTraitement(inst.tva.regime, inst.tva.territoire, inst.tva.pays, inst.tva.taux)}</p>
      <p className="text-xs text-slate-500">Une facture émise est conservée telle quelle : son contenu et ses montants ne se modifient jamais,
        et aucune erreur ne se corrige par un changement de statut (aucun avoir dans cette version).</p>

      <table className="w-full rounded-lg border border-slate-200 bg-white text-sm">
        <thead className="bg-slate-50 text-left"><tr><th className="p-2">Projet et tarif contractuel</th><th className="p-2 text-right">Heures</th>
          <th className="p-2 text-right">Tarif HT / h</th><th className="p-2 text-right">Montant HT</th></tr></thead>
        <tbody>{inst.lignes.map((x) => (
          <tr key={`${x.projet_id}-${x.periode_id}`} className="border-t border-slate-100">
            <td className="p-2">{x.projet_nom} — à compter du {dateFr(x.date_effet)} (réf. {x.reference})
              {Number(x.ecart_arrondi) !== 0 && <span className="block text-xs text-amber-800">Somme de {x.nb_temps} temps arrondis au centime ;
                {" "}{h(x.heures)} h × {euros(x.tarif)} = {euros(x.montant_theorique)} ; écart d&apos;arrondi : {euros(x.ecart_arrondi)}.</span>}</td>
            <td className="p-2 text-right">{h(x.heures)}</td><td className="p-2 text-right">{euros(x.tarif)}</td><td className="p-2 text-right">{euros(x.montant_ht)}</td>
          </tr>))}
        </tbody>
        <tfoot className="border-t border-slate-200">
          <tr><td colSpan={3} className="p-2 text-right">Total HT</td><td className="p-2 text-right">{euros(f.total_ht)}</td></tr>
          <tr><td colSpan={3} className="p-2 text-right">TVA</td><td className="p-2 text-right">{euros(f.tva)}</td></tr>
          <tr><td colSpan={3} className="p-2 text-right font-semibold">Total TTC</td><td className="p-2 text-right font-semibold" data-total-ttc>{euros(f.total_ttc)}</td></tr>
        </tfoot>
      </table>

      <details className="rounded-lg border border-slate-200 bg-white p-3 text-sm" data-detail-admin>
        <summary className="cursor-pointer">Détail nominatif des {inst.temps.length} temps facturés (espace administrateur — non imprimé sur le PDF client)</summary>
        <ul className="mt-2 space-y-1">{inst.temps.map((x, i) => <li key={x.id}>T-{String(i + 1).padStart(2, "0")} — {dateFr(x.date)} — {x.intervenant} —
          {" "}{x.projet_nom} — {h(x.heures)} h × {euros(x.tarif)} = {euros(x.montant_ht)}</li>)}</ul>
      </details>

      <section className="space-y-2">
        <h2 className="font-semibold">PDF</h2>
        {f.pdf_statut === "disponible"
          ? <p className="text-sm"><a href={`/finance/factures/${f.id}/pdf`} className="underline" data-telecharger>Télécharger le PDF archivé</a>
              <span className="text-slate-500"> (vérifié par son empreinte à chaque téléchargement)</span></p>
          : <>
              <p className="text-sm text-amber-800">{f.pdf_statut === "echec" ? `Échec de la génération : ${f.pdf_erreur}. ` : "PDF non encore archivé. "}
                La reprise utilise le même numéro et le même instantané. L&apos;envoi reste impossible tant que le PDF n&apos;est pas disponible.</p>
              <FormulaireAction action={reprendrePdf} caches={{ facture_id: f.id }} libelle="Générer / reprendre le PDF" principal />
            </>}
      </section>

      {f.statut === "emise" && (
        <section className="space-y-2"><h2 className="font-semibold">Envoi</h2>
          <FormulaireEnvoi factureId={f.id} aujourdhui={jour} desactive={f.pdf_statut !== "disponible"} />
        </section>)}
      {f.statut === "envoyee" && (
        <section className="space-y-2"><h2 className="font-semibold">Règlement</h2>
          <FormulaireReglement factureId={f.id} totalTtc={euros(f.total_ttc)} aujourdhui={jour} />
        </section>)}
      {f.statut === "payee" && (
        <section className="space-y-2"><h2 className="font-semibold">Règlement</h2>
          <p className="text-sm">Règlement intégral déclaré le {dateFr(f.date_reglement)} —
            {" "}{MODES_REGLEMENT.find((m) => m.valeur === f.mode_reglement)?.libelle}{f.reference_reglement ? ` (${f.reference_reglement})` : ""}.</p>
          <FormulaireCorrectionReglement factureId={f.id} aujourdhui={jour} />
        </section>)}

      <section className="space-y-2">
        <h2 className="font-semibold">Historique</h2>
        <ol className="space-y-1 text-sm" data-historique>
          {historique.map((e, i) => (
            <li key={i}><strong>{LIBELLES_EVENEMENT_FACTURE[e.action] ?? e.action}</strong> — {dateFr(e.le)}{e.auteur_nom ? ` — ${e.auteur_nom}` : ""}
              {e.canal ? ` — ${LIBELLES_CANAL[e.canal] ?? e.canal}` : ""}{e.destinataire ? ` (${e.destinataire})` : ""}
              {e.date_reglement ? ` — réglée le ${dateFr(e.date_reglement)}` : ""}{e.motif ? ` — motif : ${e.motif}` : ""}
              {e.precedent ? ` — déclaration précédente : ${dateFr(e.precedent.date_reglement)}, ${e.precedent.mode ?? ""}` : ""}
              {e.erreur ? ` — ${e.erreur}` : ""}</li>))}
        </ol>
      </section>
    </div>
  );
}
