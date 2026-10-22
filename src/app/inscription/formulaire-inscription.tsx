"use client";

import { useActionState } from "react";
import { creerPremierCompte } from "./actions";
import type { EtatInscription } from "./etat";

const etatInitial: EtatInscription = { erreur: null, nom: "", email: "" };

const classeChamp =
  "mt-1 w-full rounded-md border border-slate-300 px-3 py-2 focus:border-slate-500 focus:outline-none";

export function FormulaireInscription() {
  const [etat, action, enCours] = useActionState(creerPremierCompte, etatInitial);

  return (
    <form action={action} className="space-y-4">
      <div>
        <label htmlFor="nom" className="block text-sm font-medium text-slate-700">
          Nom complet
        </label>
        <input id="nom" name="nom" defaultValue={etat.nom} required autoComplete="name" className={classeChamp} />
      </div>
      <div>
        <label htmlFor="email" className="block text-sm font-medium text-slate-700">
          Email
        </label>
        <input id="email" name="email" type="email" defaultValue={etat.email} required autoComplete="email" className={classeChamp} />
      </div>
      <div>
        <label htmlFor="mot_de_passe" className="block text-sm font-medium text-slate-700">
          Mot de passe (10 caractères minimum)
        </label>
        <input
          id="mot_de_passe"
          name="mot_de_passe"
          type="password"
          required
          minLength={10}
          autoComplete="new-password"
          className={classeChamp}
        />
      </div>
      <div>
        <label htmlFor="confirmation" className="block text-sm font-medium text-slate-700">
          Confirmez le mot de passe
        </label>
        <input
          id="confirmation"
          name="confirmation"
          type="password"
          required
          minLength={10}
          autoComplete="new-password"
          className={classeChamp}
        />
      </div>

      {etat.erreur && (
        <p role="alert" className="rounded-md bg-red-50 px-3 py-2 text-sm text-red-700">
          {etat.erreur}
        </p>
      )}

      <button
        type="submit"
        disabled={enCours}
        className="w-full rounded-md bg-slate-900 px-4 py-2 font-medium text-white hover:bg-slate-700 disabled:opacity-60"
      >
        {enCours ? "Création…" : "Créer mon compte administrateur"}
      </button>
    </form>
  );
}
