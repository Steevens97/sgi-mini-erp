"use client";

import { useState } from "react";
import { LIBELLES_TYPE_ABSENCE, TYPES_ABSENCE, controlerDemande, estimationJoursOuvres, joursMaximum, nombreFr } from "@/lib/absences";
import { Message, boutonPrincipal, champ } from "../commercial/composants";
import { useSaisieConservee, type OptionSimple } from "../rh/composants";
import { demanderConge } from "./actions";

const l = "block text-sm font-medium text-slate-700";

export type SoldeAffiche = { cp: number; rtt: number; rttRenseignes: boolean };

// Demande de congé. Le nombre de jours est SAISI (aucun calendrier des jours fériés) : l'estimation affichée
// n'est qu'une aide et n'est jamais enregistrée à la place de la saisie. La base revérifie tout.
export function FormulaireConge(props: {
  fiches: OptionSimple[];
  estAdmin: boolean;
  aujourdhui: string;
  temps: Record<string, Record<string, number>>; // fiche → date → heures déjà saisies
  soldes: Record<string, SoldeAffiche>;
}) {
  const s = useSaisieConservee(demanderConge);
  if (!props.fiches.length) {
    return <p role="alert" className="text-sm text-amber-800">Aucune fiche collaborateur rattachée à votre compte : demande impossible.</p>;
  }
  return <CorpsConge key={s.cle} {...props} s={s} />;
}

function CorpsConge({ fiches, estAdmin, aujourdhui, temps, soldes, s }: Parameters<typeof FormulaireConge>[0] & {
  s: ReturnType<typeof useSaisieConservee>;
}) {
  const c = s.conservees;
  const [fiche, setFiche] = useState(c?.collaborateur_id ?? fiches[0].id);
  const [type, setType] = useState(c?.type ?? "conges_payes");
  const [debut, setDebut] = useState(c?.date_debut ?? "");
  const [fin, setFin] = useState(c?.date_fin ?? "");
  const [apresMidi, setApresMidi] = useState(c?.debut_apres_midi === "on");
  const [finMidi, setFinMidi] = useState(c?.fin_midi === "on");
  const [jours, setJours] = useState(c?.nb_jours ?? "");
  const max = joursMaximum(debut, fin, apresMidi, finMidi);
  const estimation = estimationJoursOuvres(debut, fin, apresMidi, finMidi);
  const probleme = debut && fin && jours ? controlerDemande({ debut, fin, apresMidi, finMidi, jours }) : null;
  const retroactif = !!debut && debut < aujourdhui;
  const tempsPeriode = debut && fin && fin >= debut
    ? Object.entries(temps[fiche] ?? {}).filter(([d]) => d >= debut && d <= fin).sort() : [];
  const solde = soldes[fiche];
  const n = Number(jours.replace(",", ".")) || 0;
  const disponible = type === "conges_payes" ? solde?.cp : type === "rtt" ? solde?.rtt : undefined;

  return (
    <form action={s.executer} onSubmit={s.memoriser} className="rounded-lg border border-slate-200 bg-white p-4">
      <div className="grid gap-3 sm:grid-cols-3">
        <label className={l}>{estAdmin ? "Demander pour *" : "Collaborateur"}
          {estAdmin ? (
            <select name="collaborateur_id" value={fiche} onChange={(e) => setFiche(e.target.value)} className={champ}>
              {fiches.map((o) => <option key={o.id} value={o.id}>{o.libelle}</option>)}
            </select>
          ) : (
            <>
              <input type="hidden" name="collaborateur_id" value={fiche} />
              <input value={fiches[0].libelle} disabled aria-label="Collaborateur" className={champ} />
            </>
          )}
        </label>
        <label className={l}>Type *
          <select name="type" value={type} onChange={(e) => setType(e.target.value)} className={champ}>
            {TYPES_ABSENCE.map((t) => <option key={t} value={t}>{LIBELLES_TYPE_ABSENCE[t]}</option>)}
          </select>
        </label>
        <span />
        <label className={l}>Premier jour *
          <input type="date" name="date_debut" required value={debut} min={estAdmin ? undefined : aujourdhui}
            onChange={(e) => setDebut(e.target.value)} className={champ} />
          <span className="mt-1 flex items-center gap-2 font-normal">
            <input type="checkbox" name="debut_apres_midi" checked={apresMidi} onChange={(e) => setApresMidi(e.target.checked)} />
            commence l&apos;après-midi
          </span>
        </label>
        <label className={l}>Dernier jour *
          <input type="date" name="date_fin" required value={fin} min={debut || (estAdmin ? undefined : aujourdhui)}
            onChange={(e) => setFin(e.target.value)} className={champ} />
          <span className="mt-1 flex items-center gap-2 font-normal">
            <input type="checkbox" name="fin_midi" checked={finMidi} onChange={(e) => setFinMidi(e.target.checked)} />
            finit à midi
          </span>
        </label>
        <label className={l}>Nombre de jours * (par demi-journée)
          <input name="nb_jours" type="number" min="0.5" step="0.5" max={max ?? undefined} required value={jours}
            onChange={(e) => setJours(e.target.value)} placeholder="ex. 1,5" className={champ} />
          {max !== null && (
            <span className="mt-1 block text-xs font-normal text-slate-600">
              Au plus {nombreFr(max)} jour(s) sur cette période.
              {estimation !== null && <> Estimation indicative (lundi–vendredi, jours fériés non déduits) : {nombreFr(estimation)} — c&apos;est le nombre saisi qui sera enregistré.</>}
            </span>
          )}
        </label>
        <label className={`${l} sm:col-span-3`}>Commentaire (facultatif)
          <input name="motif" defaultValue={c?.motif ?? ""} className={champ} />
        </label>
        {estAdmin && retroactif && (
          <label className={`${l} sm:col-span-3`}>Motif de la demande rétroactive * (administrateur)
            <input name="motif_retroactif" required defaultValue={c?.motif_retroactif ?? ""} className={champ} />
          </label>
        )}
      </div>
      {probleme && <p role="alert" className="mt-2 text-sm text-red-700">{probleme}</p>}
      {!estAdmin && retroactif && (
        <p role="alert" className="mt-2 text-sm text-red-700">Une demande sur une date passée est réservée à l&apos;administrateur (avec motif).</p>
      )}
      {tempsPeriode.length > 0 && (
        <p role="alert" className="mt-2 text-sm text-amber-800">
          Attention : des temps sont déjà saisis sur cette période ({tempsPeriode.map(([d, h]) => `${d.split("-").reverse().join("/")} : ${nombreFr(h)} h`).join(" ; ")}).
          Rien ne sera modifié automatiquement : vérifiez ces temps avec la personne concernée.
        </p>
      )}
      {type === "rtt" && solde && !solde.rttRenseignes && (
        <p role="note" className="mt-2 text-sm text-amber-800">
          Droits RTT non renseignés pour cette personne : la demande peut être enregistrée, mais sa validation sera refusée tant
          que l&apos;administrateur n&apos;aura pas renseigné les droits.
        </p>
      )}
      {disponible !== undefined && n > disponible && (solde?.rttRenseignes || type !== "rtt") && (
        <p role="note" className="mt-2 text-sm text-amber-800">
          Solde actuel : {nombreFr(disponible)} jour(s). La validation sera refusée si le solde reste insuffisant.
        </p>
      )}
      <button type="submit" disabled={s.enCours || !!probleme || (!estAdmin && retroactif)} className={`${boutonPrincipal} mt-3`}>
        {s.enCours ? "…" : "Envoyer la demande"}
      </button>
      <Message etat={s.etat} />
    </form>
  );
}
