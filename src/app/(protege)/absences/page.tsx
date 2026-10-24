import Link from "next/link";
import { lireUtilisateurCourant } from "@/lib/session";
import { creerClientServeur } from "@/lib/supabase/serveur";
import { aujourdhuiMartinique, decalerJours, nomComplet } from "@/lib/rh";
import { CONFIRMATIONS_ABSENCES, LIBELLES_STATUT_CONGE, LIBELLES_TYPE_ABSENCE, nombreFr, periodeFr, type EvenementAbsences } from "@/lib/absences";
import { dateFr } from "@/lib/format";
import { FormulaireAction, champ } from "../commercial/composants";
import { deciderConge } from "./actions";
import { FormulaireConge, type SoldeAffiche } from "./composants";
import { HistoriqueAbsences } from "./historique";

type Conge = {
  id: string; collaborateur_id: string; type: string; date_debut: string; date_fin: string; debut_apres_midi: boolean;
  fin_midi: boolean; nb_jours: number; motif: string | null; motif_retroactif: string | null; statut: string;
  demande_par_nom: string | null; decide_par_nom: string | null; decide_le: string | null; motif_decision: string | null;
  solde_preleve: number | null; historique: EvenementAbsences[]; essai: boolean;
};
type Solde = { id: string; nom: string; prenom: string | null; manager_id: string | null; solde_conges: number; solde_rtt: number;
  droits_rtt_renseignes: boolean; historique_soldes: EvenementAbsences[] };

// Tout est lu avec la session de l'utilisateur : la base ne renvoie que ce qu'il a le droit de voir (ses congés et
// ses soldes ; manager : son équipe directe ; admin : tout). Personne ne décide de ses propres congés.
export default async function PageAbsences({ searchParams }: { searchParams: Promise<{ confirmation?: string }> }) {
  const confirmation = CONFIRMATIONS_ABSENCES[(await searchParams).confirmation ?? ""];
  const moi = await lireUtilisateurCourant();
  const supabase = await creerClientServeur();
  const aujourdhui = aujourdhuiMartinique();
  const [{ data: soldesLus }, { data: congesLus }, { data: fiches }] = await Promise.all([
    supabase.from("absences_soldes").select("id, nom, prenom, manager_id, solde_conges, solde_rtt, droits_rtt_renseignes, historique_soldes").order("nom"),
    supabase.from("conges").select("id, collaborateur_id, type, date_debut, date_fin, debut_apres_midi, fin_midi, nb_jours, motif, motif_retroactif, statut, demande_par_nom, decide_par_nom, decide_le, motif_decision, solde_preleve, historique, essai")
      .order("date_debut", { ascending: false }),
    supabase.from("collaborateurs").select("id, nom, prenom, manager_id, date_sortie").order("nom"),
  ]);
  const soldes = (soldesLus ?? []) as Solde[];
  const conges = (congesLus ?? []) as Conge[];
  const parFiche = new Map((fiches ?? []).map((f) => [f.id, f]));
  const parSolde = new Map(soldes.map((s) => [s.id, s]));
  const estAdmin = moi.role === "admin";

  // Temps déjà saisis sur les périodes affichées (alerte seulement, jamais de modification automatique).
  const plusAncien = conges.reduce((m, c) => (c.date_debut < m ? c.date_debut : m), decalerJours(aujourdhui, -62));
  const { data: tempsLus } = await supabase.from("temps").select("collaborateur_id, date_saisie, heures").gte("date_saisie", plusAncien);
  const temps: Record<string, Record<string, number>> = {};
  for (const t of tempsLus ?? []) {
    temps[t.collaborateur_id] ??= {};
    temps[t.collaborateur_id][t.date_saisie] = (temps[t.collaborateur_id][t.date_saisie] ?? 0) + Number(t.heures);
  }
  const alerteTemps = (c: Conge) => Object.entries(temps[c.collaborateur_id] ?? {}).filter(([d]) => d >= c.date_debut && d <= c.date_fin).sort();

  const ficheChoix = estAdmin
    ? (fiches ?? []).filter((f) => !f.date_sortie || f.date_sortie >= aujourdhui).map((f) => ({ id: f.id, libelle: nomComplet(f) }))
    : (fiches ?? []).filter((f) => f.id === moi.collaborateurId).map((f) => ({ id: f.id, libelle: nomComplet(f) }));
  const soldesFormulaire: Record<string, SoldeAffiche> = Object.fromEntries(
    soldes.map((s) => [s.id, { cp: Number(s.solde_conges), rtt: Number(s.solde_rtt), rttRenseignes: s.droits_rtt_renseignes }]));
  const peutDecider = (c: Conge) => c.collaborateur_id !== moi.collaborateurId
    && (estAdmin || (moi.role === "manager" && !!moi.collaborateurId && parFiche.get(c.collaborateur_id)?.manager_id === moi.collaborateurId));
  const mesConges = conges.filter((c) => c.collaborateur_id === moi.collaborateurId);
  const aDecider = conges.filter((c) => c.statut === "demandee" && peutDecider(c)).reverse();
  const autres = conges.filter((c) => c.collaborateur_id !== moi.collaborateurId && !(c.statut === "demandee" && peutDecider(c)));
  const mien = moi.collaborateurId ? parSolde.get(moi.collaborateurId) : undefined;

  const cellules = (c: Conge, avecNom: boolean) => (
    <>
      {avecNom && <td className="px-3 py-2">{nomComplet(parFiche.get(c.collaborateur_id))}{c.essai && <span className="ml-1 text-xs text-amber-700">[ESSAI]</span>}</td>}
      <td className={avecNom ? "" : "px-3 py-2"}>{LIBELLES_TYPE_ABSENCE[c.type]}</td>
      <td>{periodeFr(c)}</td>
      <td>{nombreFr(c.nb_jours)}</td>
      <td>
        {LIBELLES_STATUT_CONGE[c.statut]}
        {c.statut === "validee" && <span className="block text-xs text-slate-600">prélevé : {nombreFr(c.solde_preleve)} j</span>}
        {c.decide_par_nom && <span className="block text-xs text-slate-600">par {c.decide_par_nom}, {dateFr(c.decide_le)}</span>}
        {c.motif_decision && <span className="block text-xs text-slate-600">motif : {c.motif_decision}</span>}
      </td>
    </>
  );
  const alerte = (c: Conge) => {
    const a = alerteTemps(c);
    return a.length ? (
      <p role="alert" className="text-xs text-amber-800">
        Temps saisis sur cette période : {a.map(([d, h]) => `${d.split("-").reverse().join("/")} (${nombreFr(h)} h)`).join(", ")}. Aucun changement automatique.
      </p>
    ) : null;
  };

  return (
    <div className="space-y-8">
      {confirmation && <p role="status" data-confirmation className="rounded-md border border-emerald-300 bg-emerald-50 p-3 text-sm text-emerald-800">{confirmation}</p>}
      <div>
        <h1 className="text-2xl font-semibold">Absences</h1>
        <p className="mt-1 text-sm text-slate-600">
          Nombre de jours saisi par demi-journée (aucun calendrier des jours fériés dans cette version). Congés payés et RTT
          sont prélevés une seule fois, à la validation, jamais au-delà du solde ; « sans solde » ne prélève rien. Personne ne
          décide de ses propres congés. Un congé validé ne peut pas être annulé dans cette version.
        </p>
        {estAdmin && <Link href="/absences/soldes" className="mt-2 inline-block text-sm underline">Soldes et ajustements (administrateur) →</Link>}
      </div>

      <section>
        <h2 className="mb-2 font-semibold">Mes soldes</h2>
        {mien ? (
          <div className="flex flex-wrap gap-4 rounded-lg border border-slate-200 bg-white p-4 text-sm" data-mes-soldes>
            <p>Congés payés : <strong>{nombreFr(mien.solde_conges)} jour(s)</strong></p>
            <p>RTT : {mien.droits_rtt_renseignes ? <strong>{nombreFr(mien.solde_rtt)} jour(s)</strong>
              : <strong className="text-amber-800">droits non renseignés</strong>}
              {!mien.droits_rtt_renseignes && <span className="block text-xs text-slate-600">Cela ne signifie pas que vous n&apos;avez aucun droit : ils n&apos;ont pas encore été renseignés par l&apos;administrateur.</span>}
            </p>
            <div className="w-full"><HistoriqueAbsences evenements={mien.historique_soldes} soldes titre="Historique de mes soldes" /></div>
          </div>
        ) : (
          <p role="alert" className="text-sm text-amber-800">Aucun solde à afficher : votre compte n&apos;est rattaché à aucune fiche collaborateur.</p>
        )}
      </section>

      <section>
        <h2 className="mb-2 font-semibold">Nouvelle demande</h2>
        <FormulaireConge fiches={ficheChoix} estAdmin={estAdmin} aujourdhui={aujourdhui} temps={temps} soldes={soldesFormulaire} />
      </section>

      <section>
        <h2 className="mb-2 font-semibold">Mes demandes ({mesConges.length})</h2>
        <table className="w-full rounded-lg border border-slate-200 bg-white text-sm [&_td]:pr-3 [&_th]:pr-3">
          <thead className="bg-slate-50 text-left"><tr><th className="px-3 py-2">Type</th><th>Période</th><th>Jours</th><th>Statut</th><th>Détails</th></tr></thead>
          <tbody>
            {mesConges.map((c) => (
              <tr key={c.id} className="border-t border-slate-100 align-top" data-conge={c.id}>
                {cellules(c, false)}
                <td className="py-2 pr-3">{alerte(c)}<HistoriqueAbsences evenements={c.historique} /></td>
              </tr>
            ))}
            {!mesConges.length && <tr><td colSpan={5} className="px-3 py-3 text-slate-500">Aucune demande.</td></tr>}
          </tbody>
        </table>
      </section>

      {(estAdmin || moi.role === "manager") && (
        <section>
          <h2 className="mb-2 font-semibold">À décider ({aDecider.length})</h2>
          <p className="mb-2 text-sm text-slate-600">
            {estAdmin ? "Administrateur : demandes de tous les autres collaborateurs." : "Manager : demandes de votre équipe directe."} Vos propres demandes n&apos;y figurent jamais.
          </p>
          <table className="w-full rounded-lg border border-slate-200 bg-white text-sm [&_td]:pr-3 [&_th]:pr-3">
            <thead className="bg-slate-50 text-left"><tr><th className="px-3 py-2">Collaborateur</th><th>Type</th><th>Période</th><th>Jours</th><th>Statut</th><th>Décision</th></tr></thead>
            <tbody>
              {aDecider.map((c) => {
                const s = parSolde.get(c.collaborateur_id);
                const dispo = c.type === "conges_payes" ? s?.solde_conges : c.type === "rtt" ? s?.solde_rtt : null;
                return (
                  <tr key={c.id} className="border-t border-slate-100 align-top" data-conge={c.id}>
                    {cellules(c, true)}
                    <td className="space-y-1 py-2 pr-3">
                      {c.type !== "sans_solde" && s && (
                        <p className={`text-xs ${Number(dispo) < Number(c.nb_jours) ? "text-red-700" : "text-slate-600"}`}>
                          Solde {LIBELLES_TYPE_ABSENCE[c.type]} : {c.type === "rtt" && !s.droits_rtt_renseignes ? "droits non renseignés" : `${nombreFr(dispo)} j`}
                          {Number(dispo) < Number(c.nb_jours) ? " — insuffisant : la validation sera refusée." : ""}
                        </p>
                      )}
                      {c.motif && <p className="text-xs text-slate-600">Commentaire : {c.motif}</p>}
                      {alerte(c)}
                      <FormulaireAction action={deciderConge} caches={{ conge_id: c.id, decision: "valider" }} libelle="Valider" principal />
                      <FormulaireAction action={deciderConge} caches={{ conge_id: c.id, decision: "refuser" }} libelle="Refuser" className="flex gap-1">
                        <input name="motif" required placeholder="motif du refus" className={`${champ} mt-0 w-40`} />
                      </FormulaireAction>
                      <HistoriqueAbsences evenements={c.historique} />
                    </td>
                  </tr>
                );
              })}
              {!aDecider.length && <tr><td colSpan={6} className="px-3 py-3 text-slate-500">Aucune demande à décider.</td></tr>}
            </tbody>
          </table>
        </section>
      )}

      {autres.length > 0 && (
        <section>
          <h2 className="mb-2 font-semibold">{estAdmin ? "Autres demandes" : "Demandes de mon équipe"} ({autres.length})</h2>
          <table className="w-full rounded-lg border border-slate-200 bg-white text-sm [&_td]:pr-3 [&_th]:pr-3">
            <thead className="bg-slate-50 text-left"><tr><th className="px-3 py-2">Collaborateur</th><th>Type</th><th>Période</th><th>Jours</th><th>Statut</th><th>Détails</th></tr></thead>
            <tbody>
              {autres.map((c) => (
                <tr key={c.id} className="border-t border-slate-100 align-top" data-conge={c.id}>
                  {cellules(c, true)}
                  <td className="py-2 pr-3">{alerte(c)}<HistoriqueAbsences evenements={c.historique} /></td>
                </tr>
              ))}
            </tbody>
          </table>
        </section>
      )}
    </div>
  );
}
