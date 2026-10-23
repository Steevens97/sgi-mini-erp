import Link from "next/link";
import { notFound } from "next/navigation";
import { lireUtilisateurCourant } from "@/lib/session";
import { creerClientServeur } from "@/lib/supabase/serveur";
import { creerClientAdmin } from "@/lib/supabase/admin";
import { libelleTraitement, type Criteres } from "@/lib/tva";
import { MENTION_ASSURANCE, TYPES_MISSION, blocagesEmission, type TypeMission } from "@/lib/entreprise";
import { LIBELLES_CANAL, LIBELLES_STATUT_DEVIS, dateFr, euros } from "@/lib/format";
import {
  ajouterLigne, creerAvenant, decider, declarerEnvoi, emettre, enregistrerTva, modifierLigne,
  nouvelleVersion, regenererPdf, supprimerBrouillon, supprimerLigne,
} from "../../actions";
import { FormulaireAction, FormulaireTva, LigneEditable, champ } from "../../composants";

const COLONNES_COMMERCIAL = "id, prospect_id, numero, date_emission, statut, total_ht, tva, total_ttc, regime_tva, territoire_tva, pays_tva, taux_tva, mention_tva, criteres_tva, date_envoi, canal_envoi, envoi_destinataire, envoi_declare_par_nom, emis_par_nom, decision_par_nom, decision_le, remplace_devis_id, avenant_du_devis_id, essai, type_mission, pdf_statut, pdf_erreur, created_at";
const COLONNES_CONSULTATION = "id, prospect_id, numero, date_emission, statut, total_ht, tva, total_ttc, regime_tva, territoire_tva, pays_tva, taux_tva, mention_tva, date_envoi, canal_envoi, remplace_devis_id, avenant_du_devis_id, essai, type_mission, created_at";

type Devis = Record<string, string | number | boolean | null> & { criteres_tva?: Criteres | null };

export default async function PageDevis({ params }: { params: Promise<{ id: string }> }) {
  const { id } = await params;
  const moi = await lireUtilisateurCourant();
  const commercial = moi.role === "admin" || moi.role === "manager";
  const supabase = await creerClientServeur();
  const table = commercial ? "devis" : "commercial_devis";
  const { data } = await supabase.from(table).select(commercial ? COLONNES_COMMERCIAL : COLONNES_CONSULTATION).eq("id", id).maybeSingle();
  if (!data) notFound();
  const d = data as unknown as Devis;
  const [{ data: lignes }, { data: prospect }, { data: lies }] = await Promise.all([
    supabase.from(commercial ? "devis_lignes" : "commercial_devis_lignes").select("id, designation, quantite, prix_unitaire, montant_ht")
      .eq("devis_id", id).order("created_at").order("id"),
    supabase.from(commercial ? "prospects" : "commercial_prospects").select("id, nom, societe").eq("id", String(d.prospect_id)).maybeSingle(),
    supabase.from(table).select("id, numero, statut, avenant_du_devis_id, remplace_devis_id")
      .or(`id.eq.${d.remplace_devis_id ?? id},id.eq.${d.avenant_du_devis_id ?? id},remplace_devis_id.eq.${id},avenant_du_devis_id.eq.${id}`),
  ]);
  const autres = (lies ?? []).filter((x) => x.id !== id);
  // Projet de la mission (devis initial ou devis complété par cet avenant) : lu côté serveur après
  // vérification du rôle commercial (la table projets reste réservée à l'admin en lecture directe).
  const racine = (d.avenant_du_devis_id as string | null) ?? id;
  const projet = commercial
    ? (await creerClientAdmin().from("projets").select("id, nom, statut").eq("devis_id", racine).maybeSingle()).data
    : null;
  const brouillon = d.statut === "brouillon";
  const ecriture = commercial && !d.essai;
  const caches = { devis_id: id };
  const manquants = d.essai ? [] : blocagesEmission(d.type_mission as TypeMission | null);

  return (
    <div className="space-y-6">
      <div>
        <Link href={`/commercial/prospects/${d.prospect_id}`} className="text-sm text-slate-600 underline">
          ← {prospect?.societe || prospect?.nom || "Prospect"}
        </Link>
        <h1 className="mt-2 text-2xl font-semibold">
          {d.avenant_du_devis_id ? "Avenant " : "Devis "}{d.numero ?? "brouillon"}{" "}
          <span className="rounded bg-slate-100 px-2 text-base">{LIBELLES_STATUT_DEVIS[String(d.statut)]}</span>{" "}
          {d.essai ? <span className="rounded bg-red-100 px-2 text-base text-red-800">ESSAI — SANS VALEUR</span> : null}
        </h1>
        <p className="text-sm text-slate-600">
          Mission : {TYPES_MISSION.find((m) => m.valeur === d.type_mission)?.libelle ?? "non renseignée"} — {libelleTraitement(d.regime_tva as string, d.territoire_tva as string, d.pays_tva as string, d.taux_tva === null ? null : Number(d.taux_tva))}
          {d.date_emission && !brouillon ? ` — émis le ${dateFr(String(d.date_emission))}` : ""}
          {d.emis_par_nom ? ` par ${d.emis_par_nom}` : ""}
        </p>
        <p className="text-sm text-amber-800">Assurance : {MENTION_ASSURANCE}.</p>
        {autres.length > 0 && (
          <ul className="mt-2 text-sm">
            {autres.map((x) => (
              <li key={x.id}>
                <Link href={`/commercial/devis/${x.id}`} className="underline">
                  {x.id === d.remplace_devis_id ? "Remplace" : x.id === d.avenant_du_devis_id ? "Avenant du devis" :
                    x.remplace_devis_id === id ? "Nouvelle version" : "Avenant"} {x.numero ?? "(brouillon)"}
                </Link> — {LIBELLES_STATUT_DEVIS[x.statut]}
              </li>
            ))}
          </ul>
        )}
        {projet && <p className="mt-2 text-sm">Projet de la mission : <strong>{projet.nom}</strong> ({projet.statut})</p>}
      </div>

      {/* Lignes */}
      <section className="rounded-lg border border-slate-200 bg-white p-4">
        <h2 className="mb-2 font-semibold">Lignes</h2>
        {brouillon && ecriture ? (
          <>
            {(lignes ?? []).map((l) => (
              <LigneEditable key={l.id} action={modifierLigne} supprimer={supprimerLigne} devisId={id}
                ligne={{ ...l, quantite: Number(l.quantite), prix_unitaire: Number(l.prix_unitaire), montant_ht: Number(l.montant_ht) }} />
            ))}
            <FormulaireAction action={ajouterLigne} caches={caches} libelle="Ajouter la ligne" className="mt-3 flex flex-wrap items-end gap-2">
              <input name="designation" placeholder="Désignation" className={`${champ} mt-0 min-w-64 flex-1`} />
              <input name="quantite" placeholder="Qté" defaultValue="1" inputMode="decimal" className={`${champ} mt-0 w-20`} />
              <input name="prix_unitaire" placeholder="P.U. HT" inputMode="decimal" className={`${champ} mt-0 w-28`} />
            </FormulaireAction>
            {d.avenant_du_devis_id && <p className="mt-2 text-xs text-slate-500">Avenant : une quantité négative retire une partie de la mission ; le total de la mission (devis initial + avenants acceptés) ne peut pas devenir négatif.</p>}
          </>
        ) : (
          <table className="w-full text-sm">
            <tbody>
              {(lignes ?? []).map((l) => (
                <tr key={l.id} className="border-b border-slate-100 last:border-0">
                  <td className="py-1">{l.designation}</td><td className="text-right">{String(l.quantite).replace(".", ",")}</td>
                  <td className="text-right">{euros(l.prix_unitaire)}</td><td className="text-right">{euros(l.montant_ht)}</td>
                </tr>
              ))}
            </tbody>
          </table>
        )}
        <div className="mt-3 text-right text-sm">
          <div>Total HT : {euros(d.total_ht as number)}</div>
          <div>TVA : {euros(d.tva as number)}</div>
          <div className="font-semibold">Total TTC : {euros(d.total_ttc as number)}</div>
          {d.mention_tva && <div className="mt-1 text-slate-600">{d.mention_tva}</div>}
        </div>
      </section>

      {brouillon && ecriture && (
        <FormulaireTva action={enregistrerTva} devisId={id} v={{
          regime_tva: d.regime_tva as string | null, territoire_tva: d.territoire_tva as string | null,
          pays_tva: d.pays_tva as string | null, taux_tva: d.taux_tva === null ? null : Number(d.taux_tva),
          mention_tva: d.mention_tva as string | null, criteres_tva: d.criteres_tva ?? null,
          type_mission: d.type_mission as string | null }} />
      )}

      {commercial && (
        <section className="space-y-3 rounded-lg border border-slate-200 bg-white p-4">
          <h2 className="font-semibold">Actions</h2>
          {brouillon && (
            <div className="flex flex-wrap gap-3">
              <a href={`/commercial/devis/${id}/pdf`} className="rounded-md border border-slate-300 px-3 py-1.5 text-sm">Aperçu PDF (brouillon, non émis)</a>
              {ecriture && (
                <>
                  {manquants.length > 0 ? (
                    <div className="text-sm text-amber-800"><p className="font-medium">Émission bloquée :</p><ul className="list-disc pl-5">{manquants.map((m) => <li key={m}>{m}</li>)}</ul></div>
                  ) : (
                    <FormulaireAction action={emettre} caches={caches} libelle="Émettre (attribue le numéro, fige le devis)" principal
                      confirmation="Émettre ce devis ? Il recevra son numéro définitif et ne sera plus modifiable." />
                  )}
                  <FormulaireAction action={supprimerBrouillon} caches={caches} libelle="Supprimer le brouillon" confirmation="Supprimer ce brouillon ?" />
                </>
              )}
            </div>
          )}
          {!brouillon && (
            <div className="space-y-2 text-sm">
              <p>PDF archivé : {d.pdf_statut === "disponible" ? "disponible" : d.pdf_statut === "echec" ? `en échec (${d.pdf_erreur})` : "en attente"}</p>
              <div className="flex flex-wrap gap-2">
                {d.pdf_statut === "disponible"
                  ? <a href={`/commercial/devis/${id}/pdf`} className="rounded-md border border-slate-300 px-3 py-1.5">Télécharger le PDF archivé</a>
                  : <FormulaireAction action={regenererPdf} caches={caches} libelle="Régénérer le PDF (même numéro, même contenu)" />}
              </div>
              <p className="text-slate-500">Un téléchargement ne vaut pas envoi : l&apos;envoi se déclare ci-dessous.</p>
            </div>
          )}
          {d.statut === "emis" && ecriture && d.pdf_statut === "disponible" && (
            <FormulaireAction action={declarerEnvoi} caches={caches} libelle="Déclarer l'envoi" principal className="flex flex-wrap items-end gap-2">
              <label className="text-sm">Date et heure (Martinique)<input type="datetime-local" name="date_envoi" required className={champ} /></label>
              <label className="text-sm">Canal
                <select name="canal_envoi" className={champ}>{Object.entries(LIBELLES_CANAL).map(([v, l]) => <option key={v} value={v}>{l}</option>)}</select></label>
              <label className="text-sm">Destinataire (email, nom…)<input name="envoi_destinataire" className={champ} /></label>
            </FormulaireAction>
          )}
          {d.statut !== "brouillon" && d.statut !== "emis" && d.date_envoi && (
            <p className="text-sm">Envoi déclaré : {dateFr(String(d.date_envoi))} — {LIBELLES_CANAL[String(d.canal_envoi)]}
              {d.envoi_destinataire ? ` — ${d.envoi_destinataire}` : ""} — par {d.envoi_declare_par_nom}</p>
          )}
          {d.statut === "envoye" && ecriture && (
            <div className="flex flex-wrap gap-2">
              <FormulaireAction action={decider} caches={{ ...caches, decision: "accepte" }} libelle="Client : accepté" principal
                confirmation="Enregistrer l'acceptation ? Le client et le projet seront créés automatiquement." />
              <FormulaireAction action={decider} caches={{ ...caches, decision: "refuse" }} libelle="Client : refusé" confirmation="Enregistrer le refus ?" />
            </div>
          )}
          {(d.statut === "emis" || d.statut === "envoye") && ecriture && (
            <FormulaireAction action={nouvelleVersion} caches={caches} libelle="Créer une nouvelle version (le devis actuel reste intact)" />
          )}
          {d.statut === "accepte" && !d.avenant_du_devis_id && ecriture && (
            <FormulaireAction action={creerAvenant} caches={caches} libelle="Créer un avenant (modification de mission)" />
          )}
          {d.decision_par_nom && <p className="text-sm">Décision enregistrée par {d.decision_par_nom} le {dateFr(String(d.decision_le))}</p>}
        </section>
      )}
    </div>
  );
}
