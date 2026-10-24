import Link from "next/link";
import { lireUtilisateurCourant } from "@/lib/session";
import { creerClientServeur } from "@/lib/supabase/serveur";
import { LIBELLES_STATUT_PROJET, STATUTS_PROJET } from "@/lib/rh";
import { FormulaireAction, champ } from "../../commercial/composants";
import { creerProjet, modifierProjet } from "../actions";

// Admin et manager : table projets (règles RLS). Collaborateur : vue des projets ouverts (nom du client
// seulement, aucune coordonnée, aucun lien vers le devis).
// Droits de modification : le MANAGER change uniquement le statut (en cours / terminé / annulé) ;
// l'ADMIN change aussi le nom et le client d'un projet créé à la main. Un projet issu d'un devis garde
// son devis et son client. La base l'impose (déclencheur projets_avant_ecriture), écran contourné ou non.
export default async function PageProjets() {
  const moi = await lireUtilisateurCourant();
  const supabase = await creerClientServeur();
  const commercial = moi.role === "admin" || moi.role === "manager";

  if (!commercial) {
    const { data: ouverts } = await supabase.from("rh_projets_ouverts").select("id, nom, statut, client_nom").order("nom");
    return (
      <div className="space-y-4">
        <Link href="/rh" className="text-sm text-slate-600 underline">← RH</Link>
        <h1 className="text-2xl font-semibold">Projets ouverts à la saisie</h1>
        <ul className="divide-y divide-slate-100 rounded-lg border border-slate-200 bg-white text-sm">
          {(ouverts ?? []).map((p) => (
            <li key={p.id} className="px-4 py-2"><span className="font-medium">{p.nom}</span> — {p.client_nom ?? "sans client (mission interne)"}</li>
          ))}
          {!ouverts?.length && <li className="px-4 py-2 text-slate-500">Aucun projet ouvert.</li>}
        </ul>
      </div>
    );
  }

  const [{ data: projets }, { data: clients }, { data: devis }] = await Promise.all([
    supabase.from("projets").select("id, nom, statut, client_id, devis_id, created_at").order("created_at", { ascending: false }),
    supabase.from("clients").select("id, nom").order("nom"),
    supabase.from("devis").select("id, numero"),
  ]);
  const nomClient = new Map((clients ?? []).map((c) => [c.id, c.nom]));
  const numeroDevis = new Map((devis ?? []).map((d) => [d.id, d.numero]));
  const estAdmin = moi.role === "admin";

  return (
    <div className="space-y-6">
      <div>
        <Link href="/rh" className="text-sm text-slate-600 underline">← RH</Link>
        <h1 className="mt-2 text-2xl font-semibold">Projets</h1>
        <p className="text-sm text-slate-600">
          {estAdmin
            ? "Administrateur : statut, et nom et client des projets créés à la main. Un projet issu d'un devis garde son devis et son client."
            : "Manager : vous pouvez changer uniquement le statut d'un projet (en cours, terminé, annulé)."}
        </p>
      </div>
      <table className="w-full rounded-lg border border-slate-200 bg-white text-sm">
        <thead className="bg-slate-50 text-left"><tr><th className="px-3 py-2">Projet</th><th>Client</th><th>Origine</th><th>Statut</th></tr></thead>
        <tbody>
          {(projets ?? []).map((p) => {
            const manuel = !p.devis_id;
            return (
              <tr key={p.id} className="border-t border-slate-100 align-top" data-projet={p.nom}>
                <td className="px-3 py-2 font-medium">{p.nom}</td>
                <td>{p.client_id ? nomClient.get(p.client_id) ?? "—" : "—"}</td>
                <td>{manuel ? "Création manuelle" : `Devis ${numeroDevis.get(p.devis_id!) ?? ""}`}</td>
                <td className="py-2 pr-3">
                  <FormulaireAction action={modifierProjet} caches={{ projet_id: p.id }} libelle="Enregistrer" className="flex flex-wrap items-center gap-2">
                    {estAdmin && manuel && (
                      <>
                        <input name="nom" defaultValue={p.nom} aria-label="Nom du projet" className={`${champ} mt-0 w-48`} />
                        <select name="client_id" defaultValue={p.client_id ?? ""} aria-label="Client" className={`${champ} mt-0 w-44`}>
                          <option value="">— sans client —</option>
                          {(clients ?? []).map((c) => <option key={c.id} value={c.id}>{c.nom}</option>)}
                        </select>
                      </>
                    )}
                    <select name="statut" defaultValue={p.statut} aria-label="Statut" className={`${champ} mt-0 w-56`}>
                      {STATUTS_PROJET.map((s) => <option key={s} value={s}>{LIBELLES_STATUT_PROJET[s]}</option>)}
                    </select>
                  </FormulaireAction>
                </td>
              </tr>
            );
          })}
        </tbody>
      </table>
      {estAdmin && (
        <section>
          <h2 className="mb-2 font-semibold">Nouveau projet sans devis</h2>
          <p className="mb-2 text-sm text-slate-600">Missions internes, prospection, reprise d&apos;historique. Les projets issus d&apos;un devis sont créés automatiquement à son acceptation.</p>
          <FormulaireAction action={creerProjet} caches={{}} libelle="Créer le projet" principal className="flex flex-wrap items-end gap-2 rounded-lg border border-slate-200 bg-white p-4">
            <label className="text-sm font-medium">Nom *<input name="nom" required className={champ} /></label>
            <label className="text-sm font-medium">Client (facultatif)
              <select name="client_id" className={champ}>
                <option value="">— sans client —</option>
                {(clients ?? []).map((c) => <option key={c.id} value={c.id}>{c.nom}</option>)}
              </select>
            </label>
          </FormulaireAction>
        </section>
      )}
    </div>
  );
}
