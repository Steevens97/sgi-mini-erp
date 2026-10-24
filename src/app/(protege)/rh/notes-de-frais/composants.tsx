"use client";

import { useState, useTransition } from "react";
import type { FormEvent } from "react";
import { CATEGORIES_FRAIS, LIBELLES_CATEGORIE_FRAIS, TAILLE_MAX_JUSTIFICATIF, TYPES_JUSTIFICATIF } from "@/lib/absences";
import { ETAT_INITIAL } from "@/lib/utilisateurs";
import { Message, boutonPrincipal, champ } from "../../commercial/composants";
import type { OptionSimple } from "../composants";
import { creerNote, modifierNote, preparerDepotJustificatif, type EtatNote } from "./actions";

const l = "block text-sm font-medium text-slate-700";
type Depot = { chemin: string; type: string; nom: string; taille: number; modifie: number };

export type NoteModifiable = {
  id: string; collaborateur_id: string; date_depense: string; montant: number; categorie: string;
  categorie_precision: string | null; objet: string;
};

// Dépôt en deux temps : (1) le serveur vérifie la session et les droits puis émet un lien signé pour UN chemin neuf ;
// le navigateur y envoie le fichier directement ; (2) le serveur relit le fichier stocké (signature, taille, SHA-256)
// puis la base crée la note. Une nouvelle tentative réutilise le fichier déjà déposé (aucun doublon) ; un fichier
// refusé pour son contenu est supprimé par le serveur et doit être choisi à nouveau. La saisie n'est jamais perdue.
export function FormulaireNote({ fiches, estAdmin, aujourdhui, note }: {
  fiches: OptionSimple[]; estAdmin: boolean; aujourdhui: string; note?: NoteModifiable;
}) {
  const [etat, setEtat] = useState<EtatNote>(ETAT_INITIAL);
  const [enCours, demarrer] = useTransition();
  const [depot, setDepot] = useState<Depot | null>(null);
  const [cle, setCle] = useState(0);
  const [categorie, setCategorie] = useState(note?.categorie ?? "repas");
  const [fiche, setFiche] = useState(note?.collaborateur_id ?? fiches[0]?.id ?? "");
  if (!fiches.length && !note) {
    return <p role="alert" className="text-sm text-amber-800">Aucune fiche collaborateur rattachée à votre compte : note de frais impossible.</p>;
  }

  async function envoyer(e: FormEvent<HTMLFormElement>) {
    e.preventDefault();
    const formulaire = e.currentTarget;
    const d = new FormData(formulaire);
    const fichier = d.get("fichier");
    d.delete("fichier");
    demarrer(async () => {
      let actuel = depot;
      const choisi = fichier instanceof File && fichier.size > 0 ? fichier : null;
      if (choisi && (!actuel || actuel.nom !== choisi.name || actuel.taille !== choisi.size || actuel.modifie !== choisi.lastModified)) {
        if (!TYPES_JUSTIFICATIF[choisi.type]) return setEtat({ statut: "erreur", message: "Format refusé : PDF, JPEG ou PNG uniquement." });
        if (choisi.size > TAILLE_MAX_JUSTIFICATIF) return setEtat({ statut: "erreur", message: "Fichier de plus de 10 Mo : refusé." });
        const p = await preparerDepotJustificatif(fiche, choisi.type, choisi.size);
        if (!p.ok) return setEtat({ statut: "erreur", message: p.message });
        try {
          const r = await fetch(p.url, { method: "PUT", body: choisi, headers: { "content-type": choisi.type, "x-upsert": "false" } });
          if (!r.ok) return setEtat({ statut: "erreur", message: `Envoi du fichier refusé par le stockage (code ${r.status}). Rien n'a été enregistré.` });
        } catch {
          return setEtat({ statut: "erreur", message: "Envoi du fichier interrompu (réseau). Rien n'a été enregistré : réessayez." });
        }
        actuel = { chemin: p.chemin, type: choisi.type, nom: choisi.name, taille: choisi.size, modifie: choisi.lastModified };
        setDepot(actuel);
      }
      if (!note && !actuel) return setEtat({ statut: "erreur", message: "Justificatif obligatoire : choisissez un fichier PDF, JPEG ou PNG." });
      if (actuel) {
        d.set("chemin", actuel.chemin);
        d.set("type", actuel.type);
      }
      const r = await (note ? modifierNote : creerNote)(ETAT_INITIAL, d);
      setEtat(r);
      if (r.fichierRejete) setDepot(null);
      if (r.statut === "succes") {
        setDepot(null);
        if (!note) { formulaire.reset(); setCle((k) => k + 1); }
      }
    });
  }

  return (
    <form onSubmit={envoyer} className="rounded-lg border border-slate-200 bg-white p-4" data-formulaire-note={note?.id ?? "nouvelle"}>
      {note && <input type="hidden" name="note_id" value={note.id} />}
      <div className="grid gap-3 sm:grid-cols-3" key={cle}>
        <label className={l}>{estAdmin && !note ? "Pour *" : "Collaborateur"}
          {estAdmin && !note ? (
            <select name="collaborateur_id" value={fiche} onChange={(e) => { setFiche(e.target.value); setDepot(null); }} className={champ}>
              {fiches.map((o) => <option key={o.id} value={o.id}>{o.libelle}</option>)}
            </select>
          ) : (
            <>
              <input type="hidden" name="collaborateur_id" value={fiche} />
              <input value={fiches.find((f) => f.id === fiche)?.libelle ?? "—"} disabled aria-label="Collaborateur" className={champ} />
            </>
          )}
        </label>
        <label className={l}>Date de la dépense *
          <input type="date" name="date_depense" required max={aujourdhui} defaultValue={note?.date_depense ?? ""} className={champ} />
        </label>
        <label className={l}>Montant TTC (€) *
          <input name="montant" type="number" min="0.01" step="0.01" required defaultValue={note ? String(note.montant) : ""} placeholder="ex. 42,50" className={champ} />
        </label>
        <label className={l}>Catégorie *
          <select name="categorie" value={categorie} onChange={(e) => setCategorie(e.target.value)} className={champ}>
            {CATEGORIES_FRAIS.map((c) => <option key={c} value={c}>{LIBELLES_CATEGORIE_FRAIS[c]}</option>)}
          </select>
        </label>
        <label className={l}>Précision {categorie === "autre" ? "*" : "(facultative)"}
          <input name="categorie_precision" required={categorie === "autre"} defaultValue={note?.categorie_precision ?? ""} className={champ} />
        </label>
        <label className={l}>Objet de la dépense *
          <input name="objet" required maxLength={300} defaultValue={note?.objet ?? ""} placeholder="ex. Déjeuner chantier Le Lamentin" className={champ} />
        </label>
        <label className={`${l} sm:col-span-3`}>{note ? "Remplacer le justificatif (facultatif ; l'ancien reste conservé)" : "Justificatif * (PDF, JPEG ou PNG, 10 Mo au plus)"}
          <input type="file" name="fichier" accept="application/pdf,image/jpeg,image/png" required={!note && !depot} className={`${champ} bg-white`} />
          {depot && <span className="mt-1 block text-xs font-normal text-slate-600">Fichier déjà déposé : {depot.nom} — il sera réutilisé si vous renvoyez le formulaire.</span>}
        </label>
      </div>
      <p className="mt-2 text-xs text-slate-500">Montant TTC uniquement (aucune TVA récupérable n&apos;est calculée). Le fichier est vérifié par le serveur (contenu réel, pas seulement son nom).</p>
      <button type="submit" disabled={enCours} className={`${boutonPrincipal} mt-3`}>{enCours ? "Envoi…" : note ? "Enregistrer la modification" : "Déposer la note"}</button>
      <Message etat={etat} />
    </form>
  );
}
