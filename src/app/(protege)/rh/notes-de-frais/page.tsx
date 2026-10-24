import Link from "next/link";
import { lireUtilisateurCourant } from "@/lib/session";
import { creerClientServeur } from "@/lib/supabase/serveur";
import { aujourdhuiMartinique, nomComplet } from "@/lib/rh";
import { CONFIRMATIONS_ABSENCES, LIBELLES_CATEGORIE_FRAIS, LIBELLES_STATUT_NOTE, type EvenementAbsences } from "@/lib/absences";
import { dateFr, euros } from "@/lib/format";
import { FormulaireAction, champ } from "../../commercial/composants";
import { HistoriqueAbsences } from "../../absences/historique";
import { corrigerRemboursement, declarerRemboursement, deciderNote, nettoyerDepots } from "./actions";
import { FormulaireNote } from "./composants";

type Note = {
  id: string; collaborateur_id: string; date_depense: string; montant: number; categorie: string; categorie_precision: string | null;
  objet: string; statut: string; justificatif_type: string; justificatif_taille: number; soumise_par_nom: string | null;
  soumise_le: string | null; decide_par_nom: string | null; decide_le: string | null; motif_decision: string | null;
  rembourse_le: string | null; reference_remboursement: string | null; rembourse_declare_par_nom: string | null;
  historique: EvenementAbsences[]; essai: boolean;
};

// Lecture avec la session de l'utilisateur : ses notes ; manager : son équipe directe ; admin : tout.
// Le justificatif ne s'ouvre que par le lien « Consulter » (contrôle des droits et de l'empreinte à chaque ouverture).
export default async function PageNotesDeFrais({ searchParams }: { searchParams: Promise<{ confirmation?: string }> }) {
  const confirmation = CONFIRMATIONS_ABSENCES[(await searchParams).confirmation ?? ""];
  const moi = await lireUtilisateurCourant();
  const supabase = await creerClientServeur();
  const aujourdhui = aujourdhuiMartinique();
  const [{ data: notesLues }, { data: fiches }] = await Promise.all([
    supabase.from("notes_de_frais").select("id, collaborateur_id, date_depense, montant, categorie, categorie_precision, objet, statut, justificatif_type, justificatif_taille, soumise_par_nom, soumise_le, decide_par_nom, decide_le, motif_decision, rembourse_le, reference_remboursement, rembourse_declare_par_nom, historique, essai")
      .order("date_depense", { ascending: false }),
    supabase.from("collaborateurs").select("id, nom, prenom, manager_id, date_sortie").order("nom"),
  ]);
  const notes = (notesLues ?? []) as Note[];
  const parFiche = new Map((fiches ?? []).map((f) => [f.id, f]));
  const estAdmin = moi.role === "admin";
  const choix = (estAdmin ? (fiches ?? []) : (fiches ?? []).filter((f) => f.id === moi.collaborateurId))
    .map((f) => ({ id: f.id, libelle: nomComplet(f) }));
  const peutDecider = (n: Note) => n.collaborateur_id !== moi.collaborateurId
    && (estAdmin || (moi.role === "manager" && !!moi.collaborateurId && parFiche.get(n.collaborateur_id)?.manager_id === moi.collaborateurId));
  const mesNotes = notes.filter((n) => n.collaborateur_id === moi.collaborateurId);
  const aDecider = notes.filter((n) => n.statut === "soumise" && peutDecider(n));
  const aRembourser = estAdmin ? notes.filter((n) => n.statut === "validee" && n.collaborateur_id !== moi.collaborateurId) : [];
  const remboursees = estAdmin ? notes.filter((n) => n.statut === "remboursee") : [];
  const autres = notes.filter((n) => n.collaborateur_id !== moi.collaborateurId && !aDecider.includes(n) && !aRembourser.includes(n) && !remboursees.includes(n));

  const anciens = (n: Note) => n.historique.filter((e) => e.action === "modification" && (e.avant as { justificatif_url?: string })?.justificatif_url);
  const cellules = (n: Note, avecNom: boolean) => (
    <>
      {avecNom && <td className="px-3 py-2">{nomComplet(parFiche.get(n.collaborateur_id))}{n.essai && <span className="ml-1 text-xs text-amber-700">[ESSAI]</span>}</td>}
      <td className={avecNom ? "" : "px-3 py-2"}>{dateFr(n.date_depense)}</td>
      <td>{LIBELLES_CATEGORIE_FRAIS[n.categorie]?.replace(" (précision obligatoire)", "")}{n.categorie_precision ? ` — ${n.categorie_precision}` : ""}
        <span className="block text-xs text-slate-600">{n.objet}</span></td>
      <td className="whitespace-nowrap">{euros(n.montant)} TTC</td>
      <td>
        {LIBELLES_STATUT_NOTE[n.statut]}
        {n.decide_par_nom && <span className="block text-xs text-slate-600">par {n.decide_par_nom}, {dateFr(n.decide_le)}</span>}
        {n.motif_decision && <span className="block text-xs text-slate-600">motif : {n.motif_decision}</span>}
        {n.statut === "remboursee" && <span className="block text-xs text-slate-600">le {dateFr(n.rembourse_le)}{n.reference_remboursement ? `, réf. ${n.reference_remboursement}` : ""} (déclaré par {n.rembourse_declare_par_nom})</span>}
      </td>
      <td className="text-xs">
        <a href={`/rh/notes-de-frais/${n.id}/justificatif`} target="_blank" rel="noopener" className="underline">Consulter le justificatif</a>
        {anciens(n).map((_, i) => (
          <a key={i} href={`/rh/notes-de-frais/${n.id}/justificatif?ancien=${i}`} target="_blank" rel="noopener" className="block text-slate-500 underline">ancien justificatif {i + 1}</a>
        ))}
      </td>
    </>
  );
  const entete = (avecNom: boolean, derniere: string) => (
    <thead className="bg-slate-50 text-left"><tr>{avecNom && <th className="px-3 py-2">Collaborateur</th>}<th className={avecNom ? "" : "px-3 py-2"}>Date</th><th>Catégorie / objet</th><th>Montant</th><th>Statut</th><th>Justificatif</th><th>{derniere}</th></tr></thead>
  );

  return (
    <div className="space-y-8">
      {confirmation && <p role="status" data-confirmation className="rounded-md border border-emerald-300 bg-emerald-50 p-3 text-sm text-emerald-800">{confirmation}</p>}
      <div>
        <Link href="/rh" className="text-sm text-slate-600 underline">← RH</Link>
        <h1 className="mt-2 text-2xl font-semibold">Notes de frais</h1>
        <p className="mt-1 text-sm text-slate-600">
          Montant TTC, justificatif obligatoire (PDF, JPEG ou PNG, 10 Mo au plus). Une note validée, refusée ou remboursée ne se
          modifie plus. Personne ne décide de ses propres notes. Le remboursement est une déclaration de l&apos;administrateur :
          aucun virement n&apos;est effectué par l&apos;application.
        </p>
      </div>

      <section>
        <h2 className="mb-2 font-semibold">Nouvelle note</h2>
        <FormulaireNote fiches={choix} estAdmin={estAdmin} aujourdhui={aujourdhui} />
      </section>

      <section>
        <h2 className="mb-2 font-semibold">Mes notes ({mesNotes.length})</h2>
        <table className="w-full rounded-lg border border-slate-200 bg-white text-sm [&_td]:pr-3 [&_th]:pr-3">
          {entete(false, "Détails")}
          <tbody>
            {mesNotes.map((n) => (
              <tr key={n.id} className="border-t border-slate-100 align-top" data-note={n.id}>
                {cellules(n, false)}
                <td className="space-y-1 py-2 pr-3">
                  {n.statut === "soumise" && (
                    <details><summary className="cursor-pointer text-xs underline">Modifier</summary>
                      <FormulaireNote fiches={choix.length ? choix : [{ id: n.collaborateur_id, libelle: nomComplet(parFiche.get(n.collaborateur_id)) }]}
                        estAdmin={estAdmin} aujourdhui={aujourdhui} note={n} />
                    </details>
                  )}
                  <HistoriqueAbsences evenements={n.historique} />
                </td>
              </tr>
            ))}
            {!mesNotes.length && <tr><td colSpan={6} className="px-3 py-3 text-slate-500">Aucune note.</td></tr>}
          </tbody>
        </table>
      </section>

      {(estAdmin || moi.role === "manager") && (
        <section>
          <h2 className="mb-2 font-semibold">À décider ({aDecider.length})</h2>
          <table className="w-full rounded-lg border border-slate-200 bg-white text-sm [&_td]:pr-3 [&_th]:pr-3">
            {entete(true, "Décision")}
            <tbody>
              {aDecider.map((n) => (
                <tr key={n.id} className="border-t border-slate-100 align-top" data-note={n.id}>
                  {cellules(n, true)}
                  <td className="space-y-1 py-2 pr-3">
                    {estAdmin && (
                      <details><summary className="cursor-pointer text-xs underline">Corriger avant décision</summary>
                        <FormulaireNote fiches={[{ id: n.collaborateur_id, libelle: nomComplet(parFiche.get(n.collaborateur_id)) }]} estAdmin aujourdhui={aujourdhui} note={n} />
                      </details>
                    )}
                    <FormulaireAction action={deciderNote} caches={{ note_id: n.id, decision: "valider" }} libelle="Valider" principal />
                    <FormulaireAction action={deciderNote} caches={{ note_id: n.id, decision: "refuser" }} libelle="Refuser" className="flex gap-1">
                      <input name="motif" required placeholder="motif du refus" className={`${champ} mt-0 w-40`} />
                    </FormulaireAction>
                    <HistoriqueAbsences evenements={n.historique} />
                  </td>
                </tr>
              ))}
              {!aDecider.length && <tr><td colSpan={7} className="px-3 py-3 text-slate-500">Aucune note à décider.</td></tr>}
            </tbody>
          </table>
        </section>
      )}

      {estAdmin && (
        <>
          <section>
            <h2 className="mb-2 font-semibold">Validées, à rembourser ({aRembourser.length})</h2>
            <table className="w-full rounded-lg border border-slate-200 bg-white text-sm [&_td]:pr-3 [&_th]:pr-3">
              {entete(true, "Remboursement")}
              <tbody>
                {aRembourser.map((n) => (
                  <tr key={n.id} className="border-t border-slate-100 align-top" data-note={n.id}>
                    {cellules(n, true)}
                    <td className="space-y-1 py-2 pr-3">
                      <FormulaireAction action={declarerRemboursement} caches={{ note_id: n.id }} libelle="Déclarer le remboursement" principal className="flex flex-wrap gap-1">
                        <input type="date" name="rembourse_le" required max={aujourdhui} min={n.date_depense} aria-label="Date du remboursement" className={`${champ} mt-0 w-40`} />
                        <input name="reference" placeholder="référence (facultative)" aria-label="Référence" className={`${champ} mt-0 w-40`} />
                      </FormulaireAction>
                      <HistoriqueAbsences evenements={n.historique} />
                    </td>
                  </tr>
                ))}
                {!aRembourser.length && <tr><td colSpan={7} className="px-3 py-3 text-slate-500">Aucune note à rembourser.</td></tr>}
              </tbody>
            </table>
          </section>
          <section>
            <h2 className="mb-2 font-semibold">Remboursées ({remboursees.length})</h2>
            <table className="w-full rounded-lg border border-slate-200 bg-white text-sm [&_td]:pr-3 [&_th]:pr-3">
              {entete(true, "Correction (motif obligatoire)")}
              <tbody>
                {remboursees.map((n) => (
                  <tr key={n.id} className="border-t border-slate-100 align-top" data-note={n.id}>
                    {cellules(n, true)}
                    <td className="space-y-1 py-2 pr-3">
                      {n.collaborateur_id === moi.collaborateurId ? (
                        <p className="text-xs text-slate-600">Votre propre note : correction par un autre administrateur uniquement.</p>
                      ) : (
                        <>
                          <FormulaireAction action={corrigerRemboursement} caches={{ note_id: n.id, action: "corriger" }} libelle="Corriger" className="flex flex-wrap gap-1">
                            <input type="date" name="rembourse_le" required max={aujourdhui} defaultValue={n.rembourse_le ?? ""} aria-label="Date corrigée" className={`${champ} mt-0 w-40`} />
                            <input name="reference" defaultValue={n.reference_remboursement ?? ""} aria-label="Référence corrigée" className={`${champ} mt-0 w-36`} />
                            <input name="motif" required placeholder="motif" aria-label="Motif de la correction" className={`${champ} mt-0 w-40`} />
                          </FormulaireAction>
                          <FormulaireAction action={corrigerRemboursement} caches={{ note_id: n.id, action: "annuler" }} libelle="Annuler la déclaration"
                            confirmation="Annuler la déclaration de remboursement ? La note redevient « validée » ; l'historique est conservé." className="flex gap-1">
                            <input name="motif" required placeholder="motif" aria-label="Motif de l'annulation" className={`${champ} mt-0 w-40`} />
                          </FormulaireAction>
                        </>
                      )}
                      <HistoriqueAbsences evenements={n.historique} />
                    </td>
                  </tr>
                ))}
                {!remboursees.length && <tr><td colSpan={7} className="px-3 py-3 text-slate-500">Aucune note remboursée.</td></tr>}
              </tbody>
            </table>
          </section>
          <section>
            <h2 className="mb-2 font-semibold">Dépôts abandonnés</h2>
            <p className="mb-2 text-sm text-slate-600">
              Fichiers déposés il y a plus d&apos;une heure et rattachés à aucune note (formulaire abandonné). Un justificatif
              rattaché, même remplacé, n&apos;est jamais supprimé.
            </p>
            <FormulaireAction action={nettoyerDepots} caches={{}} libelle="Supprimer les dépôts abandonnés"
              confirmation="Supprimer les fichiers déposés il y a plus d'une heure et rattachés à aucune note ?" />
          </section>
        </>
      )}

      {autres.length > 0 && (
        <section>
          <h2 className="mb-2 font-semibold">{estAdmin ? "Autres notes" : "Notes de mon équipe"} ({autres.length})</h2>
          <table className="w-full rounded-lg border border-slate-200 bg-white text-sm [&_td]:pr-3 [&_th]:pr-3">
            {entete(true, "Détails")}
            <tbody>
              {autres.map((n) => (
                <tr key={n.id} className="border-t border-slate-100 align-top" data-note={n.id}>
                  {cellules(n, true)}
                  <td className="py-2 pr-3"><HistoriqueAbsences evenements={n.historique} /></td>
                </tr>
              ))}
            </tbody>
          </table>
        </section>
      )}
    </div>
  );
}
