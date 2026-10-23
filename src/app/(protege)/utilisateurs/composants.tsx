"use client";

import { useActionState, useState } from "react";
import type React from "react";
import {
  changerRole,
  creerAcces,
  creerFiche,
  rattacherCompte,
  reinitialiserMotDePasse,
  revoquerAcces,
} from "./actions";
import { ETAT_INITIAL, ROLES_ATTRIBUABLES, type EtatAction } from "@/lib/utilisateurs";
import { LIBELLES_ROLES, type Role } from "@/lib/navigation";

export type CompteAffiche = {
  id: string;
  email: string;
  nom: string | null;
  role: Role;
  estMoi: boolean;
  protege: boolean;
  mdpProvisoire: boolean;
  derniereConnexion: string | null;
};

export type FicheLibre = { id: string; libelle: string };

const bouton =
  "rounded-md border border-slate-300 bg-white px-3 py-1.5 text-sm hover:bg-slate-50 disabled:opacity-50";
const boutonPrincipal =
  "rounded-md bg-slate-900 px-3 py-1.5 text-sm font-medium text-white hover:bg-slate-700 disabled:opacity-50";
const champ = "rounded-md border border-slate-300 px-2 py-1.5 text-sm";

function ChoixRole({ nom = "role", defaut }: { nom?: string; defaut: Role }) {
  return (
    <select name={nom} defaultValue={defaut} className={champ}>
      {ROLES_ATTRIBUABLES.map((r) => (
        <option key={r} value={r}>
          {LIBELLES_ROLES[r]}
        </option>
      ))}
    </select>
  );
}

// Affiche le résultat d'une action. Le mot de passe provisoire n'est montré qu'ici,
// une seule fois : il disparaît dès que l'administrateur confirme l'avoir copié.
function Retour({ etat }: { etat: EtatAction }) {
  const [masque, setMasque] = useState<string | null>(null);
  const [copie, setCopie] = useState(false);
  if (!etat.statut) return null;

  if (etat.motDePasseProvisoire && masque !== etat.motDePasseProvisoire) {
    return (
      <div role="status" className="mt-2 max-w-md rounded-md border border-amber-300 bg-amber-50 p-3 text-sm">
        <p className="font-medium text-amber-900">{etat.message}</p>
        <p className="mt-1 text-amber-900">
          Identifiant : <strong>{etat.emailCompte}</strong>
        </p>
        <p className="mt-1 text-amber-900">Mot de passe provisoire (affiché une seule fois) :</p>
        <div className="mt-1 flex items-center gap-2">
          <code data-mot-de-passe className="rounded bg-white px-2 py-1 font-mono text-base">
            {etat.motDePasseProvisoire}
          </code>
          <button
            type="button"
            className={bouton}
            onClick={async () => {
              await navigator.clipboard.writeText(etat.motDePasseProvisoire ?? "");
              setCopie(true);
            }}
          >
            {copie ? "Copié ✓" : "Copier"}
          </button>
        </div>
        <p className="mt-2 text-amber-800">
          La personne devra le remplacer à sa première connexion.
        </p>
        <button
          type="button"
          className={`${bouton} mt-2`}
          onClick={() => {
            setMasque(etat.motDePasseProvisoire ?? null);
            setCopie(false);
          }}
        >
          J&apos;ai transmis le mot de passe, masquer
        </button>
      </div>
    );
  }
  if (etat.motDePasseProvisoire) return null;

  return (
    <p
      role="status"
      className={`mt-2 text-sm ${etat.statut === "erreur" ? "text-red-700" : "text-emerald-700"}`}
    >
      {etat.message}
    </p>
  );
}

// Une seule cellule par ligne, qui garde l'état de toutes ses actions : le résultat
// (en particulier le mot de passe provisoire) reste affiché même quand la ligne change
// d'état après l'action (ex. « Aucun accès » → « Accès actif »).
export function CelluleActions({
  collaborateurId,
  compte,
  ficheSansEmail = false,
}: {
  collaborateurId: string | null;
  compte: CompteAffiche | null;
  ficheSansEmail?: boolean;
}) {
  const [etatCreation, actionCreation, creationEnCours] = useActionState(creerAcces, ETAT_INITIAL);
  const [etatRole, actionRole, roleEnCours] = useActionState(changerRole, ETAT_INITIAL);
  const [etatMdp, actionMdp, mdpEnCours] = useActionState(reinitialiserMotDePasse, ETAT_INITIAL);
  const [etatRevoc, actionRevoc, revocEnCours] = useActionState(revoquerAcces, ETAT_INITIAL);

  let contenu: React.ReactNode;
  if (!compte) {
    contenu =
      ficheSansEmail || !collaborateurId ? (
        <span className="text-sm text-slate-500">Ajoutez un email à la fiche.</span>
      ) : (
        <form action={actionCreation} className="flex flex-wrap items-center gap-2">
          <input type="hidden" name="collaborateur_id" value={collaborateurId} />
          <ChoixRole defaut="collaborateur" />
          <button type="submit" disabled={creationEnCours} className={boutonPrincipal}>
            {creationEnCours ? "Création…" : "Créer l'accès"}
          </button>
        </form>
      );
  } else if (compte.estMoi || compte.protege) {
    contenu = (
      <p className="text-sm text-slate-500">
        {compte.estMoi ? "Votre compte" : "Compte protégé"} : rôle, mot de passe et accès non
        modifiables ici.
      </p>
    );
  } else {
    contenu = (
      <div className="space-y-2">
        <form action={actionRole} className="flex flex-wrap items-center gap-2">
          <input type="hidden" name="profil_id" value={compte.id} />
          <ChoixRole defaut={compte.role} />
          <button type="submit" disabled={roleEnCours} className={bouton}>
            Changer le rôle
          </button>
        </form>
        <div className="flex flex-wrap gap-2">
          <form action={actionMdp}>
            <input type="hidden" name="profil_id" value={compte.id} />
            <button type="submit" disabled={mdpEnCours} className={bouton}>
              Réinitialiser le mot de passe
            </button>
          </form>
          <form
            action={actionRevoc}
            onSubmit={(e) => {
              if (!confirm(`Révoquer l'accès de ${compte.email} ? La fiche collaborateur sera conservée.`)) {
                e.preventDefault();
              }
            }}
          >
            <input type="hidden" name="profil_id" value={compte.id} />
            <button
              type="submit"
              disabled={revocEnCours}
              className={`${bouton} border-red-300 text-red-700 hover:bg-red-50`}
            >
              Révoquer l&apos;accès
            </button>
          </form>
        </div>
      </div>
    );
  }

  return (
    <div>
      {contenu}
      <Retour etat={etatCreation} />
      <Retour etat={etatRole} />
      <Retour etat={etatMdp} />
      <Retour etat={etatRevoc} />
    </div>
  );
}

export function FormulaireRattachement({
  compteId,
  fichesLibres,
}: {
  compteId: string;
  fichesLibres: FicheLibre[];
}) {
  const [etat, action, enCours] = useActionState(rattacherCompte, ETAT_INITIAL);
  return (
    <div>
      <form action={action} className="flex flex-wrap items-center gap-2">
        <input type="hidden" name="profil_id" value={compteId} />
        <select name="collaborateur_id" required defaultValue="" className={champ}>
          <option value="" disabled>
            {fichesLibres.length ? "Choisir une fiche libre…" : "Aucune fiche libre"}
          </option>
          {fichesLibres.map((f) => (
            <option key={f.id} value={f.id}>
              {f.libelle}
            </option>
          ))}
        </select>
        <button type="submit" disabled={enCours || !fichesLibres.length} className={bouton}>
          Rattacher
        </button>
      </form>
      <Retour etat={etat} />
    </div>
  );
}

export function FormulaireNouvelleFiche({ monCompteDejaRattache }: { monCompteDejaRattache: boolean }) {
  const [etat, action, enCours] = useActionState(creerFiche, ETAT_INITIAL);
  const libelle = "block text-sm font-medium text-slate-700";
  return (
    <form action={action} className="max-w-2xl rounded-lg border border-slate-200 bg-white p-4">
      <div className="grid gap-3 sm:grid-cols-2">
        <label className={libelle}>
          Prénom
          <input name="prenom" className={`${champ} mt-1 w-full`} />
        </label>
        <label className={libelle}>
          Nom *
          <input name="nom" required className={`${champ} mt-1 w-full`} />
        </label>
        <label className={libelle}>
          Email
          <input name="email" type="email" className={`${champ} mt-1 w-full`} />
        </label>
        <label className={libelle}>
          Poste
          <input name="poste" className={`${champ} mt-1 w-full`} />
        </label>
        <label className={libelle}>
          Date d&apos;entrée
          <input name="date_entree" type="date" className={`${champ} mt-1 w-full`} />
        </label>
        <label className={libelle}>
          Taux horaire (€)
          <input
            name="taux_horaire"
            type="number"
            min="0"
            step="0.01"
            defaultValue="0"
            className={`${champ} mt-1 w-full`}
          />
        </label>
      </div>
      <label className="mt-3 flex items-center gap-2 text-sm">
        <input type="checkbox" name="rattacher_a_mon_compte" disabled={monCompteDejaRattache} />
        Rattacher cette fiche à mon compte
        {monCompteDejaRattache && <span className="text-slate-500">(déjà rattaché)</span>}
      </label>
      <button type="submit" disabled={enCours} className={`${boutonPrincipal} mt-3`}>
        {enCours ? "Création…" : "Créer la fiche"}
      </button>
      <Retour etat={etat} />
    </form>
  );
}
