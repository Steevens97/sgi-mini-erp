import Link from "next/link";
import { randomUUID } from "node:crypto";
import { exigerAdmin } from "@/lib/session";
import { creerClientAdmin } from "@/lib/supabase/admin";
import { aujourdhuiMartinique } from "@/lib/rh";
import { blocagesEmissionFacture } from "@/lib/entreprise";
import { NATURES, REGIMES, STATUTS_CLIENT, TERRITOIRES, libelleTraitement, proposerTraitement, type Criteres } from "@/lib/tva";
import { lireParametresFacture, libelleMode, moisPrecedent, sourceDepuisRecherche, type Calcul } from "@/lib/finance";
import { dateFr, euros } from "@/lib/format";
import { champ } from "../../commercial/composants";
import { FormulaireEmission } from "../composants";
import { BandeauxFinance } from "../bandeaux";

const l = "block text-sm font-medium text-slate-700";
const h = (n: number | string) => String(Number(n)).replace(".", ",");

// Étapes en lecture seule (aucune écriture) : choix → aperçu calculé par la base. Seul « Émettre » écrit.
export default async function PageNouvelleFacture({ searchParams }: { searchParams: Promise<Record<string, string | string[] | undefined>> }) {
  await exigerAdmin();
  const sp = await searchParams;
  const src = sourceDepuisRecherche(sp);
  const p = lireParametresFacture(src);
  const admin = creerClientAdmin();
  const jour = aujourdhuiMartinique();
  const mois = src.get("mois") || moisPrecedent(jour);

  const { data: clients } = await admin.from("clients").select("id, nom").order("nom");
  const { data: projets } = p.client
    ? await admin.from("projets").select("id, nom, statut, mode_facturation, devis(numero, regime_tva, territoire_tva, pays_tva, taux_tva, mention_tva, criteres_tva)")
        .eq("client_id", p.client).order("nom")
    : { data: [] };
  type Devis = { numero: string; regime_tva: string | null; territoire_tva: string | null; pays_tva: string | null; taux_tva: number | null;
                 mention_tva: string | null; criteres_tva: Criteres | null } | null;
  // Traitement fiscal : repris d'un devis DÉJÀ confirmé d'un projet choisi ; sinon rien n'est prérempli
  // (la proposition s'affiche, l'utilisateur choisit).
  const devisChoisi = (projets ?? []).filter((x) => p.projets.includes(x.id)).map((x) => x.devis as unknown as Devis).find((d) => d?.regime_tva);
  const tvaSaisie = src.get("regime_tva") !== null;
  const t = {
    regime: tvaSaisie ? src.get("regime_tva") ?? "" : devisChoisi?.regime_tva ?? "",
    territoire: tvaSaisie ? src.get("territoire_tva") ?? "" : devisChoisi?.territoire_tva ?? "MQ",
    pays: tvaSaisie ? src.get("pays_tva") ?? "" : devisChoisi?.pays_tva ?? "",
    taux: tvaSaisie ? src.get("taux_tva") ?? "" : devisChoisi?.taux_tva !== undefined && devisChoisi?.taux_tva !== null ? String(devisChoisi.taux_tva) : "",
    mention: tvaSaisie ? src.get("mention_tva") ?? "" : devisChoisi?.mention_tva ?? "",
  };
  const criteres: Criteres = tvaSaisie ? (p.tva.criteres as Criteres) : devisChoisi?.criteres_tva ?? {};
  const proposition = proposerTraitement(criteres);

  let calc: Calcul | null = null;
  if (src.get("apercu") === "1" && p.client && p.mois) {
    const { data, error } = await admin.rpc("finance_calculer", { p_client: p.client, p_mois: p.mois, p_projets: p.projets, p_tva: p.tva });
    calc = error ? null : (data as Calcul);
  }
  const blocagesReels = calc && !calc.essai ? blocagesEmissionFacture() : [];
  const query = new URLSearchParams();
  for (const [k, v] of Object.entries(sp)) for (const x of Array.isArray(v) ? v : v ? [v] : []) query.append(k, x);
  const cles: [string, string][] = calc ? [
    ["cle_emission", randomUUID()], ["empreinte", calc.empreinte], ["essai", calc.essai ? "oui" : "non"],
    ...[...query.entries()].filter(([k]) => k !== "apercu"),
  ] : [];

  return (
    <div className="space-y-5">
      <p className="text-sm"><Link href="/finance" className="underline">← Finance</Link></p>
      <h1 className="text-2xl font-semibold">Nouvelle facture (temps passé)</h1>
      <BandeauxFinance />

      <form method="get" className="space-y-4 rounded-lg border border-slate-200 bg-white p-4">
        <div className="grid gap-3 sm:grid-cols-2">
          <label className={l}>Client *
            <select name="client_id" defaultValue={p.client} required className={champ}>
              <option value="">— choisir —</option>
              {(clients ?? []).map((c) => <option key={c.id} value={c.id}>{c.nom}</option>)}
            </select></label>
          <label className={l}>Mois facturé *<input type="month" name="mois" defaultValue={mois} max={jour.slice(0, 7)} required className={champ} /></label>
        </div>
        {p.client && (
          <fieldset>
            <legend className={l}>Projets à inclure (temps validés et non facturés du mois)</legend>
            {(projets ?? []).length === 0 && <p className="text-sm text-slate-500">Aucun projet pour ce client.</p>}
            {(projets ?? []).map((x) => (
              <label key={x.id} className="mt-1 flex items-center gap-2 text-sm">
                <input type="checkbox" name="projet_id" value={x.id} defaultChecked={p.projets.includes(x.id)} />
                {x.nom} <span className="text-slate-500">— {libelleMode(x.mode_facturation)}</span>
              </label>
            ))}
          </fieldset>
        )}
        {p.client && (
          <fieldset className="grid gap-3 sm:grid-cols-2">
            <legend className={`${l} sm:col-span-2`}>Traitement de TVA {devisChoisi && !tvaSaisie && <span className="font-normal text-slate-500">
              (repris du devis {devisChoisi.numero} — vérifiez-le)</span>}</legend>
            <label className={l}>Nature de la mission
              <select name="nature_mission" defaultValue={criteres.nature_mission ?? ""} className={champ}>
                <option value="">— choisir —</option>{NATURES.map((n) => <option key={n.valeur} value={n.valeur}>{n.libelle}</option>)}
              </select></label>
            <label className={l}>Statut du client
              <select name="statut_client" defaultValue={criteres.statut_client ?? ""} className={champ}>
                <option value="">— choisir —</option>{STATUTS_CLIENT.map((n) => <option key={n.valeur} value={n.valeur}>{n.libelle}</option>)}
              </select></label>
            <label className={l}>Lieu du client (MQ, GP, GF, FR ou code pays)<input name="lieu_client" maxLength={2} defaultValue={criteres.lieu_client ?? ""} className={champ} /></label>
            <label className={l}>Lieu de l&apos;immeuble<input name="lieu_immeuble" maxLength={2} defaultValue={criteres.lieu_immeuble ?? ""} className={champ} /></label>
            <label className={l}>N° de TVA du client<input name="numero_tva_client" defaultValue={criteres.numero_tva_client ?? ""} className={champ} /></label>
            <label className={l}>Justification d&apos;un taux non normal<input name="justification_taux" defaultValue={criteres.justification_taux ?? ""} className={champ} /></label>
            <p className="rounded-md border border-slate-200 bg-slate-50 p-2 text-sm sm:col-span-2">Proposition {proposition.aConfirmer ? "(à confirmer)" : ""} : {proposition.explication}
              {proposition.regime && ` → ${libelleTraitement(proposition.regime, proposition.territoire, proposition.pays, proposition.taux)}`}
              <span className="block text-xs text-slate-500">La proposition n&apos;est jamais appliquée seule : choisissez le traitement ci-dessous.</span></p>
            <label className={l}>Régime *
              <select name="regime_tva" defaultValue={t.regime} className={champ}>
                <option value="">— choisir —</option>{REGIMES.map((r) => <option key={r.valeur} value={r.valeur}>{r.libelle}</option>)}
              </select></label>
            <label className={l}>Territoire fiscal *
              <select name="territoire_tva" defaultValue={t.territoire} className={champ}>
                {TERRITOIRES.map((x) => <option key={x.valeur} value={x.valeur}>{x.libelle}</option>)}
              </select></label>
            <label className={l}>Pays (UE ou autre territoire)<input name="pays_tva" maxLength={2} defaultValue={t.pays} className={champ} /></label>
            <label className={l}>Taux (%) (TVA facturée)<input name="taux_tva" inputMode="decimal" defaultValue={t.taux} className={champ} /></label>
            <label className={`${l} sm:col-span-2`}>Mention imprimée<input name="mention_tva" defaultValue={t.mention} className={champ} /></label>
          </fieldset>
        )}
        <input type="hidden" name="apercu" value={p.client ? "1" : ""} />
        <button type="submit" className="rounded-md border border-slate-300 bg-white px-3 py-1.5 text-sm hover:bg-slate-50">
          {p.client ? "Afficher l'aperçu" : "Choisir ce client"}</button>
      </form>

      {calc && (
        <section className="space-y-3" data-apercu>
          <h2 className="text-lg font-semibold">Aperçu {calc.essai && <span className="text-amber-800">(facture d&apos;ESSAI)</span>} — aucun numéro, rien n&apos;est réservé</h2>
          {calc.blocages.length > 0 && (
            <div role="alert" className="rounded-md border border-red-300 bg-red-50 p-3 text-sm text-red-900">
              <p className="font-medium">Émission impossible :</p>
              <ul className="list-disc pl-5">{calc.blocages.map((b) => <li key={b}>{b}</li>)}</ul>
            </div>
          )}
          <p className="text-sm">Client : <strong>{calc.client?.nom}</strong> — période du {dateFr(calc.periode_debut)} au {dateFr(calc.periode_fin)} —
            TVA : {libelleTraitement(calc.tva.regime, calc.tva.territoire, calc.tva.pays, calc.tva.taux)}</p>
          <table className="w-full rounded-lg border border-slate-200 bg-white text-sm" data-lignes>
            <thead className="bg-slate-50 text-left"><tr><th className="p-2">Projet et tarif contractuel</th><th className="p-2 text-right">Heures</th>
              <th className="p-2 text-right">Tarif HT / h</th><th className="p-2 text-right">Montant HT</th></tr></thead>
            <tbody>
              {calc.lignes.map((x) => (
                <tr key={`${x.projet_id}-${x.periode_id}`} className="border-t border-slate-100">
                  <td className="p-2">{x.projet_nom} — à compter du {dateFr(x.date_effet)} (réf. {x.reference})
                    {Number(x.ecart_arrondi) !== 0 && <span className="block text-xs text-amber-800" data-ecart>
                      Somme de {x.nb_temps} temps arrondis chacun au centime ; {h(x.heures)} h × {euros(x.tarif)} = {euros(x.montant_theorique)} ;
                      écart d&apos;arrondi : {Number(x.ecart_arrondi) > 0 ? "+" : ""}{euros(x.ecart_arrondi)}. Le montant facturé reste la somme des temps.</span>}</td>
                  <td className="p-2 text-right">{h(x.heures)}</td><td className="p-2 text-right">{euros(x.tarif)}</td>
                  <td className="p-2 text-right">{euros(x.montant_ht)}</td>
                </tr>
              ))}
            </tbody>
            <tfoot className="border-t border-slate-200">
              <tr><td colSpan={3} className="p-2 text-right">Total HT</td><td className="p-2 text-right" data-total-ht>{euros(calc.totaux.total_ht)}</td></tr>
              <tr><td colSpan={3} className="p-2 text-right">TVA</td><td className="p-2 text-right">{euros(calc.totaux.tva)}</td></tr>
              <tr><td colSpan={3} className="p-2 text-right font-semibold">Total TTC</td><td className="p-2 text-right font-semibold" data-total-ttc>{euros(calc.totaux.total_ttc)}</td></tr>
            </tfoot>
          </table>
          <details className="rounded-lg border border-slate-200 bg-white p-3 text-sm">
            <summary className="cursor-pointer">Détail nominatif des {calc.temps.length} temps facturés (espace administrateur — le PDF client n&apos;imprime pas les noms)</summary>
            <ul className="mt-2 space-y-1">{calc.temps.map((x) => <li key={x.id}>{dateFr(x.date)} — {x.intervenant} — {x.projet_nom} —
              {" "}{h(x.heures)} h × {euros(x.tarif)} = {euros(x.montant_ht)}</li>)}</ul>
          </details>
          {calc.blocages.length === 0 && (
            <>
              <p className="text-sm"><a href={`/finance/nouvelle/pdf?${query.toString()}`} target="_blank" className="underline">Voir l&apos;aperçu PDF (non émis)</a></p>
              {blocagesReels.length > 0 && (
                <p role="alert" className="text-sm text-amber-800">Émission réelle bloquée : {blocagesReels.join(" ; ")}.</p>)}
              <FormulaireEmission caches={cles} desactive={blocagesReels.length > 0}
                libelle={calc.essai ? "Émettre la facture d'essai" : "Émettre la facture"} />
              <p className="text-xs text-slate-500">À l&apos;émission, la base revérifie tout : si un temps ou un tarif a changé depuis cet aperçu,
                rien n&apos;est émis et un aperçu actualisé est demandé. Un nouvel envoi du même formulaire retrouve la même facture.</p>
            </>
          )}
        </section>
      )}
    </div>
  );
}
