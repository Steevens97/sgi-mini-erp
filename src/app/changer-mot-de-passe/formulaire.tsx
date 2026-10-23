"use client";

import { useActionState } from "react";
import { changerMonMotDePasse } from "./actions";
import { ETAT_INITIAL } from "@/lib/utilisateurs";

const champ =
  "mt-1 w-full rounded-md border border-slate-300 px-3 py-2 focus:border-slate-500 focus:outline-none";

export function FormulaireChangementMotDePasse() {
  const [etat, action, enCours] = useActionState(changerMonMotDePasse, ETAT_INITIAL);
  return (
    <form action={action} className="space-y-4">
      <div>
        <label htmlFor="nouveau" className="block text-sm font-medium text-slate-700">
          Nouveau mot de passe (10 caractères minimum)
        </label>
        <input id="nouveau" name="nouveau" type="password" required minLength={10} autoComplete="new-password" className={champ} />
      </div>
      <div>
        <label htmlFor="confirmation" className="block text-sm font-medium text-slate-700">
          Confirmez le nouveau mot de passe
        </label>
        <input id="confirmation" name="confirmation" type="password" required minLength={10} autoComplete="new-password" className={champ} />
      </div>
      {etat.statut === "erreur" && (
        <p role="alert" className="rounded-md bg-red-50 px-3 py-2 text-sm text-red-700">
          {etat.message}
        </p>
      )}
      <button
        type="submit"
        disabled={enCours}
        className="w-full rounded-md bg-slate-900 px-4 py-2 font-medium text-white hover:bg-slate-700 disabled:opacity-60"
      >
        {enCours ? "Enregistrement…" : "Enregistrer le nouveau mot de passe"}
      </button>
    </form>
  );
}
