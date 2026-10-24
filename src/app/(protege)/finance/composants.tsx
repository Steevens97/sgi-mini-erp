"use client";

import type React from "react";
import { Message, boutonPrincipal, champ } from "../commercial/composants";
import { useSaisieConservee } from "../rh/composants";
import { MODES_FACTURATION, MODES_REGLEMENT, MENTION_PAIEMENT_PARTIEL } from "@/lib/finance";
import { LIBELLES_CANAL } from "@/lib/format";
import { confirmerTarif, corrigerReglement, declarerEnvoi, definirMode, emettreFacture, enregistrerReglement } from "./actions";

const l = "block text-sm font-medium text-slate-700";
type S = ReturnType<typeof useSaisieConservee>;

// Toute saisie refusée par la base reste à l'écran : le formulaire est recréé avec les valeurs envoyées.
function Formulaire({ s, caches, libelle, confirmation, desactive = false, children }: {
  s: S; caches: Record<string, string>; libelle: string; confirmation?: string; desactive?: boolean; children?: React.ReactNode;
}) {
  return (
    <form action={s.executer} className="rounded-lg border border-slate-200 bg-white p-4"
      onSubmit={(e) => {
        if (confirmation && !confirm(confirmation)) {
          e.preventDefault();
          return;
        }
        s.memoriser(e);
      }}>
      {Object.entries(caches).map(([nom, valeur]) => <input key={nom} type="hidden" name={nom} value={valeur} />)}
      {children}
      <button type="submit" disabled={s.enCours || desactive} className={`${boutonPrincipal} mt-3`}>{s.enCours ? "…" : libelle}</button>
      <Message etat={s.etat} />
    </form>
  );
}

export function FormulaireMode({ projetId, mode }: { projetId: string; mode: string | null }) {
  const s = useSaisieConservee(definirMode);
  const v = s.conservees;
  return (
    <div key={s.cle}><Formulaire s={s} caches={{ projet_id: projetId }} libelle="Enregistrer le mode">
      <label className={l}>Mode
        <select name="mode_facturation" defaultValue={v?.mode_facturation ?? mode ?? ""} required className={champ}>
          <option value="">— choisir —</option>
          {MODES_FACTURATION.map((m) => <option key={m.valeur} value={m.valeur}>{m.libelle}</option>)}
        </select>
      </label>
    </Formulaire></div>
  );
}

export function FormulaireTarif({ projetId, empreinte, nbTemps, dateEffetFr, dateEffet, correction }: {
  projetId: string; empreinte: string; nbTemps: number; dateEffetFr: string; dateEffet: string;
  correction: { periodeId: string; reference: string } | null;
}) {
  const s = useSaisieConservee(confirmerTarif);
  const v = s.conservees;
  const caches: Record<string, string> = { projet_id: projetId, empreinte_temps: empreinte,
    ...(correction ? { periode_id: correction.periodeId } : { date_effet: dateEffet }) };
  return (
    <div key={s.cle}><Formulaire s={s} caches={caches} libelle={correction ? "Enregistrer la correction" : "Confirmer le tarif"}>
      <div className="grid gap-3 sm:grid-cols-2">
        <label className={l}>Tarif horaire de vente HT (€) *
          <input name="tarif" inputMode="decimal" required defaultValue={v?.tarif ?? ""} placeholder="ex. 85,50" className={champ} /></label>
        <label className={l}>Référence du contrat (contrat, devis ou avenant) *
          <input name="reference" required defaultValue={v?.reference ?? correction?.reference ?? ""} className={champ} /></label>
        {correction && (
          <label className={`${l} sm:col-span-2`}>Motif de la correction *
            <input name="motif" required defaultValue={v?.motif ?? ""} className={champ} /></label>)}
        <label className="flex items-start gap-2 text-sm sm:col-span-2">
          <input type="checkbox" name="confirmation" value="oui" required className="mt-1" />
          <span>J&apos;applique ce tarif aux {nbTemps} temps non facturé(s) travaillé(s) depuis le {dateEffetFr}
            {nbTemps > 0 ? " (liste ci-dessus)" : ""}. Si l&apos;un d&apos;eux change avant l&apos;enregistrement, la confirmation sera refusée.</span>
        </label>
      </div>
    </Formulaire></div>
  );
}

// Émission : champs cachés repris de l'aperçu affiché (dont sa clé d'émission et son empreinte).
export function FormulaireEmission({ caches, libelle, desactive }: { caches: [string, string][]; libelle: string; desactive: boolean }) {
  const s = useSaisieConservee(emettreFacture);
  return (
    <form action={s.executer} className="rounded-lg border border-slate-200 bg-white p-4">
      {caches.map(([nom, valeur], i) => <input key={`${nom}-${i}`} type="hidden" name={nom} value={valeur} />)}
      <button type="submit" disabled={s.enCours || desactive} className={boutonPrincipal}>{s.enCours ? "Émission en cours…" : libelle}</button>
      <Message etat={s.etat} />
    </form>
  );
}

export function FormulaireEnvoi({ factureId, aujourdhui, desactive }: { factureId: string; aujourdhui: string; desactive: boolean }) {
  const s = useSaisieConservee(declarerEnvoi);
  const v = s.conservees;
  return (
    <div key={s.cle}><Formulaire s={s} caches={{ facture_id: factureId }} libelle="Déclarer l'envoi" desactive={desactive}>
      <p className="mb-2 text-sm text-slate-600">L&apos;application n&apos;envoie aucun email : vous déclarez l&apos;envoi que vous avez fait.</p>
      <div className="grid gap-3 sm:grid-cols-3">
        <label className={l}>Date d&apos;envoi *<input type="date" name="date_envoi" required max={aujourdhui} defaultValue={v?.date_envoi ?? aujourdhui} className={champ} /></label>
        <label className={l}>Canal *
          <select name="canal" required defaultValue={v?.canal ?? ""} className={champ}>
            <option value="">— choisir —</option>
            {Object.entries(LIBELLES_CANAL).map(([k, x]) => <option key={k} value={k}>{x}</option>)}
          </select></label>
        <label className={l}>Destinataire<input name="destinataire" defaultValue={v?.destinataire ?? ""} className={champ} /></label>
      </div>
    </Formulaire></div>
  );
}

function ChampsReglement({ v, aujourdhui, requis = true }: { v: Record<string, string> | null; aujourdhui: string; requis?: boolean }) {
  return (
    <>
      <label className={l}>Date du règlement{requis ? " *" : ""}<input type="date" name="date_reglement" required={requis} max={aujourdhui}
        defaultValue={v?.date_reglement ?? aujourdhui} className={champ} /></label>
      <label className={l}>Mode{requis ? " *" : ""}
        <select name="mode_reglement" required={requis} defaultValue={v?.mode_reglement ?? ""} className={champ}>
          <option value="">— choisir —</option>
          {MODES_REGLEMENT.map((m) => <option key={m.valeur} value={m.valeur}>{m.libelle}</option>)}
        </select></label>
      <label className={l}>Référence (n° de chèque, de virement…)<input name="reference_reglement" defaultValue={v?.reference_reglement ?? ""} className={champ} /></label>
    </>
  );
}

export function FormulaireReglement({ factureId, totalTtc, aujourdhui }: { factureId: string; totalTtc: string; aujourdhui: string }) {
  const s = useSaisieConservee(enregistrerReglement);
  return (
    <div key={s.cle}><Formulaire s={s} caches={{ facture_id: factureId }} libelle="Enregistrer le règlement intégral">
      <p role="note" className="mb-2 rounded-md border border-amber-300 bg-amber-50 p-2 text-sm text-amber-900">{MENTION_PAIEMENT_PARTIEL}</p>
      <div className="grid gap-3 sm:grid-cols-3"><ChampsReglement v={s.conservees} aujourdhui={aujourdhui} /></div>
      <label className="mt-3 flex items-start gap-2 text-sm">
        <input type="checkbox" name="integral" value="oui" className="mt-1" />
        <span>La totalité de la facture ({totalTtc} TTC) a été reçue.</span>
      </label>
    </Formulaire></div>
  );
}

export function FormulaireCorrectionReglement({ factureId, aujourdhui }: { factureId: string; aujourdhui: string }) {
  const s = useSaisieConservee(corrigerReglement);
  const v = s.conservees;
  return (
    <div key={s.cle}><Formulaire s={s} caches={{ facture_id: factureId }} libelle="Corriger la déclaration de règlement"
      confirmation="Corriger la déclaration de règlement ? La facture émise ne change pas ; l'ancienne déclaration reste dans l'historique.">
      <p className="mb-2 text-sm text-slate-600">Réservé aux erreurs de déclaration. La facture émise (numéro, contenu, montants) ne change pas.</p>
      <div className="grid gap-3 sm:grid-cols-3">
        <label className={`${l} sm:col-span-3`}>Correction *
          <select name="action_correction" required defaultValue={v?.action_correction ?? ""} className={champ}>
            <option value="">— choisir —</option>
            <option value="modifier">Modifier la date, le mode ou la référence</option>
            <option value="annuler">Annuler la déclaration (aucun règlement reçu)</option>
          </select></label>
        <ChampsReglement v={v} aujourdhui={aujourdhui} requis={false} />
        <label className={`${l} sm:col-span-3`}>Motif *<input name="motif" required defaultValue={v?.motif ?? ""} className={champ} /></label>
      </div>
    </Formulaire></div>
  );
}
