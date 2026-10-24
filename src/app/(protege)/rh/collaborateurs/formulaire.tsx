"use client";

import { Message, boutonPrincipal, champ } from "../../commercial/composants";
import { enregistrerFiche } from "../actions";
import { useSaisieConservee, type OptionSimple } from "../composants";

const l = "block text-sm font-medium text-slate-700";

export type ValeursFiche = {
  id: string; nom: string; prenom: string | null; email: string | null; poste: string | null;
  date_entree: string | null; manager_id: string | null; date_sortie: string | null; taux_horaire: number;
};

// Création et modification d'une fiche (admin). Le manager est choisi parmi les personnes éligibles
// (ni la personne elle-même, ni ses subordonnés, ni une personne sortie). Le taux n'est jamais prérempli
// à la création ; à la modification, il est relu côté serveur avec la clé secrète (écran admin seulement).
// Une saisie refusée est conservée (rien n'est à retaper).
export function FormulaireFiche({ managers, valeurs }: { managers: OptionSimple[]; valeurs?: ValeursFiche }) {
  const s = useSaisieConservee(enregistrerFiche);
  const c = s.conservees;
  const v = (cle: keyof ValeursFiche) => c?.[cle] ?? (valeurs?.[cle] != null ? String(valeurs[cle]) : "");
  return (
    <form key={s.cle} action={s.executer} onSubmit={s.memoriser} className="rounded-lg border border-slate-200 bg-white p-4">
      {valeurs && <input type="hidden" name="fiche_id" value={valeurs.id} />}
      <div className="grid gap-3 sm:grid-cols-3">
        <label className={l}>Nom *<input name="nom" required defaultValue={v("nom")} className={champ} /></label>
        <label className={l}>Prénom<input name="prenom" defaultValue={v("prenom")} className={champ} /></label>
        <label className={l}>Email<input name="email" type="email" defaultValue={v("email")} className={champ} /></label>
        <label className={l}>Poste<input name="poste" defaultValue={v("poste")} className={champ} /></label>
        <label className={l}>Date d&apos;entrée<input name="date_entree" type="date" defaultValue={v("date_entree")} className={champ} /></label>
        <label className={l}>Manager
          <select name="manager_id" defaultValue={v("manager_id")} className={champ}>
            <option value="">— aucun —</option>
            {managers.map((m) => <option key={m.id} value={m.id}>{m.libelle}</option>)}
          </select>
        </label>
        <label className={l}>Taux horaire (€) *
          <input name="taux_horaire" type="number" min="0" step="0.01" required placeholder="taux confirmé"
            defaultValue={c ? c.taux_horaire ?? "" : valeurs ? String(valeurs.taux_horaire) : undefined} className={champ} />
          <span className="mt-1 block text-xs font-normal text-slate-500">Obligatoire, jamais proposé : saisissez le taux confirmé.</span>
        </label>
        {valeurs && (
          <label className={l}>Date de sortie
            <input name="date_sortie" type="date" defaultValue={v("date_sortie")} className={champ} />
            <span className="mt-1 block text-xs font-normal text-slate-500">Ne révoque pas le compte (écran Utilisateurs).</span>
          </label>
        )}
      </div>
      <button type="submit" disabled={s.enCours} className={`${boutonPrincipal} mt-3`}>
        {s.enCours ? "…" : valeurs ? "Enregistrer la fiche" : "Créer la fiche"}
      </button>
      <Message etat={s.etat} />
    </form>
  );
}
