"use client";

import { useActionState, useState } from "react";
import type React from "react";
import { ETAT_INITIAL, type EtatAction } from "@/lib/utilisateurs";
import {
  NATURES,
  PAYS_UE,
  REGIMES,
  STATUTS_CLIENT,
  TAUX_PAR_TERRITOIRE,
  TERRITOIRES,
  proposerTraitement,
  type Criteres,
  type Regime,
  type Territoire,
} from "@/lib/tva";
import { MENTION_ASSURANCE, TYPES_MISSION } from "@/lib/entreprise";

export const champ = "mt-1 w-full rounded-md border border-slate-300 px-2 py-1.5 text-sm";
export const bouton = "rounded-md border border-slate-300 bg-white px-3 py-1.5 text-sm hover:bg-slate-50 disabled:opacity-50";
export const boutonPrincipal = "rounded-md bg-slate-900 px-3 py-1.5 text-sm font-medium text-white hover:bg-slate-700 disabled:opacity-50";

type Action = (e: EtatAction, d: FormData) => Promise<EtatAction>;

export function Message({ etat }: { etat: EtatAction }) {
  if (!etat.statut) return null;
  return (
    <p role="status" className={`mt-2 text-sm ${etat.statut === "erreur" ? "text-red-700" : "text-emerald-700"}`}>
      {etat.message}
    </p>
  );
}

// Formulaire générique : champs cachés + bouton, résultat affiché sous le formulaire.
export function FormulaireAction({
  action, caches, libelle, confirmation, principal = false, children, className = "",
}: {
  action: Action;
  caches: Record<string, string>;
  libelle: string;
  confirmation?: string;
  principal?: boolean;
  children?: React.ReactNode;
  className?: string;
}) {
  const [etat, executer, enCours] = useActionState(action, ETAT_INITIAL);
  return (
    <form
      action={executer}
      className={className}
      onSubmit={(e) => {
        if (confirmation && !confirm(confirmation)) e.preventDefault();
      }}
    >
      {Object.entries(caches).map(([nom, valeur]) => (
        <input key={nom} type="hidden" name={nom} value={valeur} />
      ))}
      {children}
      <button type="submit" disabled={enCours} className={principal ? boutonPrincipal : bouton}>
        {enCours ? "…" : libelle}
      </button>
      <Message etat={etat} />
    </form>
  );
}

export type ValeursProspect = {
  nom: string; societe: string; email: string; telephone: string; source: string;
  adresse: string; code_postal: string; ville: string; pays: string;
};

export function ChampsProspect({ v }: { v: Partial<ValeursProspect> }) {
  const l = "block text-sm font-medium text-slate-700";
  return (
    <div className="grid gap-3 sm:grid-cols-2">
      <label className={l}>Nom du contact *<input name="nom" required defaultValue={v.nom} className={champ} /></label>
      <label className={l}>Société<input name="societe" defaultValue={v.societe} className={champ} /></label>
      <label className={l}>Email<input name="email" type="email" defaultValue={v.email} className={champ} /></label>
      <label className={l}>Téléphone<input name="telephone" defaultValue={v.telephone} className={champ} /></label>
      <label className={`${l} sm:col-span-2`}>Adresse (obligatoire avant l&apos;émission d&apos;un devis)
        <input name="adresse" defaultValue={v.adresse} className={champ} /></label>
      <label className={l}>Code postal<input name="code_postal" defaultValue={v.code_postal} className={champ} /></label>
      <label className={l}>Ville<input name="ville" defaultValue={v.ville} className={champ} /></label>
      <label className={l}>Pays (code à 2 lettres : MQ, GP, GF, FR, DE…)
        <input name="pays" maxLength={2} defaultValue={v.pays ?? "MQ"} className={champ} /></label>
      <label className={l}>Source<input name="source" defaultValue={v.source} className={champ} /></label>
    </div>
  );
}

export function FormulaireProspect({ action, v, idProspect, libelle }: {
  action: Action; v: Partial<ValeursProspect>; idProspect?: string; libelle: string;
}) {
  const [etat, executer, enCours] = useActionState(action, ETAT_INITIAL);
  return (
    <form action={executer} className="max-w-2xl rounded-lg border border-slate-200 bg-white p-4">
      {idProspect && <input type="hidden" name="prospect_id" value={idProspect} />}
      <ChampsProspect v={v} />
      <button type="submit" disabled={enCours} className={`${boutonPrincipal} mt-3`}>{enCours ? "…" : libelle}</button>
      <Message etat={etat} />
    </form>
  );
}

export type ValeursTva = {
  regime_tva: string | null; territoire_tva: string | null; pays_tva: string | null; taux_tva: number | null;
  mention_tva: string | null; criteres_tva: Criteres | null; type_mission: string | null;
};

// Traitement fiscal : la PROPOSITION s'affiche à partir des critères ; elle n'est reprise que si
// l'utilisateur clique « Reprendre la proposition », puis il enregistre lui-même.
export function FormulaireTva({ action, devisId, v }: { action: Action; devisId: string; v: ValeursTva }) {
  const [etat, executer, enCours] = useActionState(action, ETAT_INITIAL);
  const [criteres, setCriteres] = useState<Criteres>(v.criteres_tva ?? {});
  const [regime, setRegime] = useState<string>(v.regime_tva ?? "taxable");
  const [territoire, setTerritoire] = useState<string>(v.territoire_tva ?? "MQ");
  const [pays, setPays] = useState<string>(v.pays_tva ?? "");
  const [taux, setTaux] = useState<string>(v.taux_tva !== null ? String(v.taux_tva) : "8.5");
  const [mention, setMention] = useState<string>(v.mention_tva ?? "");
  const proposition = proposerTraitement(criteres);
  const tauxTerritoire = TAUX_PAR_TERRITOIRE[territoire as Territoire];
  const tauxNormal = tauxTerritoire && Number(taux.replace(",", ".")) === tauxTerritoire.normal;
  const l = "block text-sm font-medium text-slate-700";
  const maj = (cle: keyof Criteres, valeur: string) => setCriteres((c) => ({ ...c, [cle]: valeur || undefined }));

  return (
    <form action={executer} className="rounded-lg border border-slate-200 bg-white p-4">
      <input type="hidden" name="devis_id" value={devisId} />
      <p className="mb-3 text-sm font-semibold">1. Mission et critères de décision</p>
      <div className="grid gap-3 sm:grid-cols-2">
        <label className={`${l} sm:col-span-2`}>Type de mission *
          <select name="type_mission" defaultValue={v.type_mission ?? ""} className={champ}>
            <option value="">— choisir —</option>
            {TYPES_MISSION.map((m) => <option key={m.valeur} value={m.valeur}>{m.libelle}</option>)}
          </select>
          <span className="mt-1 block text-xs font-normal text-amber-800">Assurance : {MENTION_ASSURANCE}.</span></label>
        <label className={l}>Nature de la mission *
          <select name="nature_mission" value={criteres.nature_mission ?? ""} onChange={(e) => maj("nature_mission", e.target.value)} className={champ}>
            <option value="">— choisir —</option>
            {NATURES.map((n) => <option key={n.valeur} value={n.valeur}>{n.libelle}</option>)}
          </select></label>
        <label className={l}>Statut du client *
          <select name="statut_client" value={criteres.statut_client ?? ""} onChange={(e) => maj("statut_client", e.target.value)} className={champ}>
            <option value="">— choisir —</option>
            {STATUTS_CLIENT.map((n) => <option key={n.valeur} value={n.valeur}>{n.libelle}</option>)}
          </select></label>
        <label className={l}>Lieu d&apos;établissement du client (MQ, GP, GF, FR ou code pays)
          <input name="lieu_client" maxLength={2} value={criteres.lieu_client ?? ""} onChange={(e) => maj("lieu_client", e.target.value.toUpperCase())} className={champ} /></label>
        <label className={l}>Lieu de l&apos;immeuble (si la mission s&apos;y rattache)
          <input name="lieu_immeuble" maxLength={2} value={criteres.lieu_immeuble ?? ""} onChange={(e) => maj("lieu_immeuble", e.target.value.toUpperCase())} className={champ} /></label>
        <label className={l}>N° de TVA du client (obligatoire en autoliquidation)
          <input name="numero_tva_client" value={criteres.numero_tva_client ?? ""} onChange={(e) => maj("numero_tva_client", e.target.value)} className={champ} /></label>
      </div>

      <div className={`mt-4 rounded-md border p-3 text-sm ${proposition.aConfirmer ? "border-amber-300 bg-amber-50 text-amber-900" : "border-slate-200 bg-slate-50"}`}>
        <p className="font-medium">Proposition {proposition.aConfirmer ? "(à confirmer)" : ""}</p>
        <p className="mt-1">{proposition.explication}</p>
        {proposition.regime && (
          <button type="button" className={`${bouton} mt-2`} onClick={() => {
            setRegime(proposition.regime as Regime);
            if (proposition.territoire) setTerritoire(proposition.territoire);
            setPays(proposition.pays ?? "");
            setTaux(proposition.taux !== null ? String(proposition.taux) : "");
            setMention(proposition.mention);
          }}>Reprendre la proposition</button>
        )}
      </div>

      <p className="mb-3 mt-4 text-sm font-semibold">2. Traitement retenu</p>
      <div className="grid gap-3 sm:grid-cols-2">
        <label className={l}>Régime *
          <select name="regime_tva" value={regime} onChange={(e) => setRegime(e.target.value)} className={champ}>
            {REGIMES.map((r) => <option key={r.valeur} value={r.valeur}>{r.libelle}</option>)}
          </select></label>
        <label className={l}>Territoire fiscal *
          <select name="territoire_tva" value={territoire} onChange={(e) => setTerritoire(e.target.value)} className={champ}>
            {TERRITOIRES.map((t) => <option key={t.valeur} value={t.valeur}>{t.libelle}</option>)}
          </select></label>
        {(territoire === "UE" || territoire === "AUTRE") && (
          <label className={l}>Pays * {territoire === "UE" && <span className="text-slate-500">({PAYS_UE.join(", ")})</span>}
            <input name="pays_tva" maxLength={2} value={pays} onChange={(e) => setPays(e.target.value.toUpperCase())} className={champ} /></label>
        )}
        {regime === "taxable" && (
          <label className={l}>Taux (%) *
            <input name="taux_tva" inputMode="decimal" value={taux} onChange={(e) => setTaux(e.target.value)} className={champ} />
            {tauxTerritoire && (
              <span className="mt-1 block text-xs font-normal text-slate-500">
                Normal : {String(tauxTerritoire.normal).replace(".", ",")} % — réduits (justification obligatoire) :{" "}
                {tauxTerritoire.reduits.map((r) => String(r).replace(".", ",")).join(" ; ")} %
              </span>
            )}
          </label>
        )}
        {regime === "taxable" && !tauxNormal && (
          <label className={`${l} sm:col-span-2`}>Justification du taux (obligatoire, 10 caractères minimum)
            <input name="justification_taux" defaultValue={v.criteres_tva?.justification_taux} className={champ} /></label>
        )}
        <label className={`${l} sm:col-span-2`}>Mention imprimée sur le devis {regime !== "taxable" && "* (texte justificatif exact)"}
          <input name="mention_tva" value={mention} onChange={(e) => setMention(e.target.value)} className={champ} /></label>
      </div>
      <button type="submit" disabled={enCours} className={`${boutonPrincipal} mt-3`}>{enCours ? "…" : "Enregistrer le traitement fiscal"}</button>
      <Message etat={etat} />
    </form>
  );
}

export function LigneEditable({ action, supprimer, devisId, ligne }: {
  action: Action; supprimer: Action; devisId: string;
  ligne: { id: string; designation: string; quantite: number; prix_unitaire: number; montant_ht: number };
}) {
  const [etat, executer, enCours] = useActionState(action, ETAT_INITIAL);
  const [etatSuppr, executerSuppr] = useActionState(supprimer, ETAT_INITIAL);
  return (
    <div className="border-b border-slate-100 py-2 last:border-0">
      <form action={executer} className="flex flex-wrap items-end gap-2">
        <input type="hidden" name="devis_id" value={devisId} />
        <input type="hidden" name="ligne_id" value={ligne.id} />
        <input name="designation" defaultValue={ligne.designation} className={`${champ} mt-0 min-w-64 flex-1`} />
        <input name="quantite" defaultValue={String(ligne.quantite)} inputMode="decimal" className={`${champ} mt-0 w-20`} />
        <input name="prix_unitaire" defaultValue={String(ligne.prix_unitaire)} inputMode="decimal" className={`${champ} mt-0 w-28`} />
        <span className="w-28 text-right text-sm">{ligne.montant_ht.toFixed(2).replace(".", ",")} €</span>
        <button type="submit" disabled={enCours} className={bouton}>Enregistrer</button>
        <button type="submit" formAction={executerSuppr} className={`${bouton} text-red-700`}>Supprimer</button>
      </form>
      <Message etat={etat} />
      <Message etat={etatSuppr} />
    </div>
  );
}
