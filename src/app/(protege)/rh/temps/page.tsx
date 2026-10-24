import Link from "next/link";
import { lireUtilisateurCourant } from "@/lib/session";
import { creerClientServeur } from "@/lib/supabase/serveur";
import { LIBELLES_STATUT_TEMPS, PARAMETRES_RH, aujourdhuiMartinique, decalerJours, nomComplet, type EvenementTemps } from "@/lib/rh";
import { dateFr } from "@/lib/format";
import { FormulaireAction, champ } from "../../commercial/composants";
import { FormulaireTemps } from "../composants";
import { changerStatutTemps, supprimerTemps } from "../actions";
import { Historique } from "../historique";

// « Mes temps ». Lecture avec la session : un collaborateur ne lit que ses temps (règle RLS) ; l'admin et
// le manager lisent tout, mais l'écran ne montre ici que les temps de la personne choisie. Écritures :
// actions serveur → fonctions de service. L'admin peut saisir pour une autre personne : l'auteur de la
// saisie et le collaborateur concerné sont affichés séparément.
export default async function PageMesTemps({ searchParams }: { searchParams: Promise<{ pour?: string; corriger?: string }> }) {
  const moi = await lireUtilisateurCourant();
  const { pour, corriger } = await searchParams;
  const supabase = await creerClientServeur();
  const estAdmin = moi.role === "admin";
  const aujourdhui = aujourdhuiMartinique();

  const { data: fiches } = await supabase.from("collaborateurs").select("id, nom, prenom, date_sortie").order("nom");
  const choix = estAdmin ? (fiches ?? []) : (fiches ?? []).filter((f) => f.id === moi.collaborateurId);
  const cible = estAdmin ? (pour && choix.some((f) => f.id === pour) ? pour : moi.collaborateurId ?? choix[0]?.id) : moi.collaborateurId;

  if (!cible) {
    return (
      <div className="space-y-4">
        <Link href="/rh" className="text-sm text-slate-600 underline">← RH</Link>
        <h1 className="text-2xl font-semibold">Mes temps</h1>
        <p role="alert" className="rounded-md bg-amber-50 px-3 py-2 text-sm text-amber-900">
          Votre compte n&apos;est rattaché à aucune fiche collaborateur : la saisie de vos temps est impossible.
          Un administrateur peut faire ce rattachement depuis l&apos;écran Utilisateurs.
        </p>
      </div>
    );
  }
  const ficheCible = (fiches ?? []).find((f) => f.id === cible);
  const [{ data: temps }, { data: ouverts }] = await Promise.all([
    supabase.from("temps")
      .select("id, collaborateur_id, projet_id, date_saisie, heures, commentaire, statut, facture_id, saisi_par, saisi_par_nom, saisi_le, valide_par_nom, valide_le, motif_derogation, historique")
      .eq("collaborateur_id", cible).order("date_saisie", { ascending: false }).order("created_at", { ascending: false }),
    supabase.from("rh_projets_ouverts").select("id, nom, client_nom").order("nom"),
  ]);
  const liste = temps ?? [];
  // Noms des projets (y compris fermés) : admin/manager via la table, collaborateur via ses propres temps + vue.
  const nomsProjets = new Map((ouverts ?? []).map((p) => [p.id, p.client_nom ? `${p.nom} — ${p.client_nom}` : p.nom]));
  if (estAdmin || moi.role === "manager") {
    const { data: tous } = await supabase.from("projets").select("id, nom");
    for (const p of tous ?? []) if (!nomsProjets.has(p.id)) nomsProjets.set(p.id, `${p.nom} (fermé)`);
  }
  const cumuls: Record<string, number> = {};
  for (const t of liste) cumuls[`${t.collaborateur_id}|${t.date_saisie}`] = (cumuls[`${t.collaborateur_id}|${t.date_saisie}`] ?? 0) + Number(t.heures);
  const aCorriger = liste.find((t) => t.id === corriger && t.statut === "brouillon");
  const cumulsSansCorrige = { ...cumuls };
  if (aCorriger) cumulsSansCorrige[`${aCorriger.collaborateur_id}|${aCorriger.date_saisie}`] -= Number(aCorriger.heures);
  const projetsProposes = (ouverts ?? []).map((p) => ({ id: p.id, libelle: nomsProjets.get(p.id)! }));
  if (aCorriger && !projetsProposes.some((p) => p.id === aCorriger.projet_id)) {
    projetsProposes.push({ id: aCorriger.projet_id, libelle: nomsProjets.get(aCorriger.projet_id) ?? "Projet actuel" });
  }
  const sortie = ficheCible?.date_sortie ?? null;
  const max = sortie && sortie < aujourdhui ? sortie : aujourdhui;
  const min = estAdmin ? undefined : decalerJours(aujourdhui, -PARAMETRES_RH.fenetreJours);
  const parJour = Object.entries(cumuls).filter(([k]) => k.startsWith(`${cible}|`)).map(([k, v]) => [k.split("|")[1], v] as const)
    .sort((a, b) => b[0].localeCompare(a[0])).slice(0, 10);

  return (
    <div className="space-y-6">
      <div>
        <Link href="/rh" className="text-sm text-slate-600 underline">← RH</Link>
        <h1 className="mt-2 text-2xl font-semibold">{cible === moi.collaborateurId ? "Mes temps" : `Temps de ${nomComplet(ficheCible)}`}</h1>
        {sortie && <p className="text-sm text-amber-800">Sortie le {dateFr(sortie)} : saisie possible seulement pour les journées antérieures (régularisation).</p>}
      </div>
      {estAdmin && (
        <form className="flex flex-wrap items-end gap-2 text-sm">
          <label className="font-medium">Saisir pour (administrateur)
            <select name="pour" defaultValue={cible} className={champ}>
              {choix.map((f) => <option key={f.id} value={f.id}>{nomComplet(f)}{f.id === moi.collaborateurId ? " (moi)" : ""}{f.date_sortie ? ` — sortie ${dateFr(f.date_sortie)}` : ""}</option>)}
            </select>
          </label>
          <button className="rounded-md border border-slate-300 px-3 py-1.5">Afficher</button>
        </form>
      )}
      <section>
        <h2 className="mb-2 font-semibold">{aCorriger ? "Corriger le brouillon" : "Nouveau temps"}</h2>
        <FormulaireTemps
          key={aCorriger?.id ?? `nouveau-${cible}`}
          collaborateurs={[{ id: cible, libelle: nomComplet(ficheCible) }]}
          projets={projetsProposes} cumuls={aCorriger ? cumulsSansCorrige : cumuls} estAdmin={estAdmin} min={min} max={max}
          initial={aCorriger ? { ...aCorriger, heures: Number(aCorriger.heures) } : undefined}
        />
        {aCorriger && <Link href={`/rh/temps${estAdmin ? `?pour=${cible}` : ""}`} className="mt-2 inline-block text-sm underline">Annuler la correction</Link>}
      </section>
      {parJour.length > 0 && (
        <p className="text-sm text-slate-600">Cumuls récents : {parJour.map(([j, h]) => `${dateFr(j)} : ${String(h).replace(".", ",")} h`).join(" ; ")}</p>
      )}
      <section>
        <h2 className="mb-2 font-semibold">Temps enregistrés</h2>
        <table className="w-full rounded-lg border border-slate-200 bg-white text-sm">
          <thead className="bg-slate-50 text-left"><tr><th className="px-3 py-2">Date</th><th>Projet</th><th>Heures</th><th>Statut</th><th>Saisi par</th><th>Actions</th></tr></thead>
          <tbody>
            {liste.map((t) => (
              <tr key={t.id} className="border-t border-slate-100 align-top" data-temps={t.id}>
                <td className="px-3 py-2">{dateFr(t.date_saisie)}</td>
                <td>{nomsProjets.get(t.projet_id) ?? "Projet fermé"}{t.commentaire ? <span className="block text-xs text-slate-500">{t.commentaire}</span> : null}</td>
                <td>{String(t.heures).replace(".", ",")}</td>
                <td>{LIBELLES_STATUT_TEMPS[t.statut]}{t.facture_id ? " (facturé)" : ""}{t.valide_par_nom ? <span className="block text-xs text-slate-500">par {t.valide_par_nom}</span> : null}</td>
                <td>{t.saisi_par_nom ?? <span className="text-slate-500">inconnu (antérieur au module RH)</span>}
                  {t.saisi_par && t.saisi_par !== moi.id && t.collaborateur_id === moi.collaborateurId ? <span className="block text-xs text-slate-500">pour vous</span> : null}</td>
                <td className="space-y-1 py-2 pr-3">
                  {t.statut === "brouillon" && (
                    <>
                      <Link href={`/rh/temps?corriger=${t.id}${estAdmin ? `&pour=${cible}` : ""}`} className="block underline">Corriger</Link>
                      <FormulaireAction action={changerStatutTemps} caches={{ temps_id: t.id, action: "soumettre" }} libelle="Soumettre" />
                      <FormulaireAction action={supprimerTemps} caches={{ temps_id: t.id }} libelle="Supprimer" confirmation="Supprimer ce brouillon ?" />
                    </>
                  )}
                  {t.statut === "soumis" && t.collaborateur_id === moi.collaborateurId && (
                    <>
                      <FormulaireAction action={changerStatutTemps} caches={{ temps_id: t.id, action: "retirer" }} libelle="Retirer (repasser en brouillon)" />
                      <FormulaireAction action={changerStatutTemps} caches={{ temps_id: t.id, action: "attester" }} libelle="Attester (sans validation)" className="flex gap-1">
                        <input name="motif" placeholder="précision (facultatif)" className={`${champ} mt-0 w-40`} />
                      </FormulaireAction>
                    </>
                  )}
                  <Historique evenements={t.historique as EvenementTemps[]} />
                </td>
              </tr>
            ))}
            {liste.length === 0 && <tr><td colSpan={6} className="px-3 py-3 text-slate-500">Aucun temps enregistré.</td></tr>}
          </tbody>
        </table>
      </section>
    </div>
  );
}
