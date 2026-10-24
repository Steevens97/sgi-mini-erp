"use client";

import { useActionState, useState } from "react";
import type { FormEvent } from "react";
import { ETAT_INITIAL, type EtatAction } from "@/lib/utilisateurs";
import { PARAMETRES_RH } from "@/lib/rh";
import { Message, boutonPrincipal, champ } from "../commercial/composants";
import { enregistrerTemps } from "./actions";

export type OptionSimple = { id: string; libelle: string };

const l = "block text-sm font-medium text-slate-700";

// Après chaque envoi, React vide les champs du formulaire, même si la base a refusé. Pour ne jamais faire
// perdre une saisie refusée, on garde ce qui a été envoyé et on recrée le formulaire avec ces valeurs.
export function useSaisieConservee(action: (e: EtatAction, d: FormData) => Promise<EtatAction>) {
  // Chaque réponse est horodatée : le formulaire n'est recréé qu'APRÈS la réponse du serveur.
  const [etat, executer, enCours] = useActionState(
    async (p: EtatAction & { recu?: number }, d: FormData) => ({ ...(await action(p, d)), recu: Date.now() }),
    ETAT_INITIAL as EtatAction & { recu?: number },
  );
  const [valeurs, setValeurs] = useState<Record<string, string>>({});
  const memoriser = (e: FormEvent<HTMLFormElement>) => {
    const v: Record<string, string> = {};
    new FormData(e.currentTarget).forEach((x, k) => { v[k] = String(x); });
    setValeurs(v);
  };
  const refuse = etat.statut === "erreur";
  return { etat, executer, enCours, memoriser, cle: `${etat.statut ?? "debut"}-${etat.recu ?? 0}`, conservees: refuse ? valeurs : null };
}

type Initial = { id: string; collaborateur_id: string; projet_id: string; date_saisie: string; heures: number;
                 commentaire: string | null; motif_derogation: string | null };

// Saisie ou correction d'un temps. Les listes ne contiennent que ce que la base accepterait :
// le collaborateur ne voit que sa fiche ; seuls les projets ouverts sont proposés ; dates bornées.
// Le cumul du jour est calculé à l'écran pour ALERTER avant l'envoi ; la base fait foi.
export function FormulaireTemps(props: {
  collaborateurs: OptionSimple[];
  projets: OptionSimple[];
  cumuls: Record<string, number>; // « collaborateur|date » → heures déjà enregistrées (hors ce temps)
  estAdmin: boolean;
  min: string | undefined;
  max: string;
  initial?: Initial;
}) {
  const s = useSaisieConservee(enregistrerTemps);
  if (!props.collaborateurs.length) {
    return <p role="alert" className="text-sm text-amber-800">Aucune fiche disponible pour la saisie.</p>;
  }
  return <CorpsTemps key={s.cle} {...props} s={s} />;
}

function CorpsTemps({ collaborateurs, projets, cumuls, estAdmin, min, max, initial, s }: Parameters<typeof FormulaireTemps>[0] & {
  s: ReturnType<typeof useSaisieConservee>;
}) {
  const c = s.conservees;
  const [collab] = useState(initial?.collaborateur_id ?? c?.collaborateur_id ?? collaborateurs[0]?.id ?? "");
  const [date, setDate] = useState(c?.date_saisie ?? initial?.date_saisie ?? max);
  const [heures, setHeures] = useState(c?.heures ?? (initial ? String(initial.heures) : ""));
  const h = Number(heures.replace(",", ".")) || 0;
  const total = (cumuls[`${collab}|${date}`] ?? 0) + h;
  const depasse12 = total > PARAMETRES_RH.seuilDerogationJour;
  const depasse24 = total > PARAMETRES_RH.plafondAbsoluJour;

  return (
    <form action={s.executer} onSubmit={s.memoriser} className="rounded-lg border border-slate-200 bg-white p-4">
      {initial && <input type="hidden" name="temps_id" value={initial.id} />}
      <input type="hidden" name="collaborateur_id" value={collab} />
      <div className="grid gap-3 sm:grid-cols-3">
        <label className={l}>Collaborateur *
          {/* Toujours une seule fiche : la sienne, ou celle choisie par l'administrateur (« Saisir pour »). */}
          <select value={collab} disabled aria-label="Collaborateur" className={champ}>
            {collaborateurs.map((o) => <option key={o.id} value={o.id}>{o.libelle}</option>)}
          </select>
        </label>
        <label className={l}>Projet *
          <select name="projet_id" defaultValue={c?.projet_id ?? initial?.projet_id ?? ""} required className={champ}>
            <option value="">— choisir —</option>
            {projets.map((p) => <option key={p.id} value={p.id}>{p.libelle}</option>)}
          </select>
        </label>
        <label className={l}>Date *
          <input type="date" name="date_saisie" value={date} min={min} max={max} required onChange={(e) => setDate(e.target.value)} className={champ} />
        </label>
        <label className={l}>Durée (heures) *
          <input name="heures" type="number" min="0.25" max="24" step="0.25" required value={heures}
            onChange={(e) => setHeures(e.target.value)} placeholder="ex. 7,5" className={champ} />
        </label>
        <label className={`${l} sm:col-span-2`}>Commentaire
          <input name="commentaire" defaultValue={c?.commentaire ?? initial?.commentaire ?? ""} className={champ} />
        </label>
        {estAdmin && (
          <label className={`${l} sm:col-span-3`}>Motif de dérogation (admin : au-delà de {PARAMETRES_RH.seuilDerogationJour} h/jour ou de {PARAMETRES_RH.fenetreJours} jours)
            <input name="motif_derogation" defaultValue={c?.motif_derogation ?? initial?.motif_derogation ?? ""} className={champ} />
          </label>
        )}
      </div>
      {h > 0 && depasse12 && (
        <p role="alert" className={`mt-2 text-sm ${depasse24 ? "text-red-700" : "text-amber-800"}`}>
          Alerte : {String(total).replace(".", ",")} h ce jour pour ce collaborateur.{" "}
          {depasse24
            ? `Au-delà de ${PARAMETRES_RH.plafondAbsoluJour} h : enregistrement impossible, même pour l'administrateur.`
            : estAdmin
              ? `Au-delà de ${PARAMETRES_RH.seuilDerogationJour} h (paramètre de gestion) : un motif de dérogation est obligatoire.`
              : `Au-delà de ${PARAMETRES_RH.seuilDerogationJour} h (paramètre de gestion), seul l'administrateur peut enregistrer, avec un motif.`}
        </p>
      )}
      <button type="submit" disabled={s.enCours || depasse24} className={`${boutonPrincipal} mt-3`}>
        {s.enCours ? "…" : initial ? "Enregistrer la correction" : "Enregistrer (brouillon)"}
      </button>
      <Message etat={s.etat} />
    </form>
  );
}
