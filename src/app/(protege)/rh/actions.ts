"use server";

import { revalidatePath } from "next/cache";
import { exigerAdmin, lireUtilisateurCourant } from "@/lib/session";
import { creerClientServeur } from "@/lib/supabase/serveur";
import { creerClientAdmin } from "@/lib/supabase/admin";
import { lireHeures, lireTaux, messageBase, STATUTS_PROJET } from "@/lib/rh";
import type { EtatAction } from "@/lib/utilisateurs";

// Chaque action relit l'utilisateur et son rôle. Les temps ne s'écrivent QUE par les fonctions SQL de
// service (clé secrète) : elles reçoivent l'identifiant du compte connecté et revérifient tout en base
// (compte actif, propriétaire, valideur, plafonds). Les fiches (taux compris) s'écrivent avec la clé
// secrète après exigerAdmin() ; les projets avec la session (règles RLS et déclencheur du manager).

const erreur = (message: string): EtatAction => ({ statut: "erreur", message });
const succes = (message: string): EtatAction => ({ statut: "succes", message });
const texte = (d: FormData, cle: string) => String(d.get(cle) ?? "").trim() || null;

async function exigerRole() {
  const moi = await lireUtilisateurCourant();
  if (!moi.role) throw new Error("Profil illisible : action impossible.");
  return moi;
}

// ---------- Fiches collaborateurs (admin) ----------
function champsFiche(d: FormData) {
  return {
    nom: texte(d, "nom"),
    prenom: texte(d, "prenom"),
    email: texte(d, "email")?.toLowerCase() ?? null,
    poste: texte(d, "poste"),
    date_entree: texte(d, "date_entree"),
    manager_id: texte(d, "manager_id"),
    date_sortie: texte(d, "date_sortie"),
  };
}

export async function enregistrerFiche(_e: EtatAction, d: FormData): Promise<EtatAction> {
  await exigerAdmin();
  const id = texte(d, "fiche_id");
  const f = champsFiche(d);
  if (!f.nom) return erreur("Le nom est obligatoire.");
  const taux = lireTaux(texte(d, "taux_horaire"));
  if (typeof taux === "string") return erreur(taux);
  if (id && f.manager_id === id) return erreur("Une personne ne peut pas être son propre manager.");
  if (f.date_sortie && f.date_entree && f.date_sortie < f.date_entree) {
    return erreur("La date de sortie ne peut pas précéder la date d'entrée.");
  }
  const admin = creerClientAdmin();
  if (f.email) {
    let q = admin.from("collaborateurs").select("id").ilike("email", f.email);
    if (id) q = q.neq("id", id);
    const { data: doublon } = await q.maybeSingle();
    if (doublon) return erreur(`Une fiche utilise déjà l'email ${f.email}.`);
  }
  const valeurs = { ...f, taux_horaire: taux };
  const { data, error } = id
    ? await admin.from("collaborateurs").update(valeurs).eq("id", id).select("id")
    : await admin.from("collaborateurs").insert(valeurs).select("id");
  if (error || !data?.length) return erreur(messageBase(error?.message ?? "Fiche introuvable."));
  revalidatePath("/rh/collaborateurs");
  return succes(id ? "Fiche enregistrée." : "Fiche créée.");
}

// ---------- Projets ----------
export async function creerProjet(_e: EtatAction, d: FormData): Promise<EtatAction> {
  await exigerAdmin();
  const nom = texte(d, "nom");
  if (!nom) return erreur("Le nom du projet est obligatoire.");
  const supabase = await creerClientServeur();
  const { error } = await supabase.from("projets").insert({ nom, client_id: texte(d, "client_id"), statut: "en_cours" });
  if (error) return erreur(messageBase(error.message));
  revalidatePath("/rh/projets");
  return succes("Projet créé (sans devis).");
}

// Manager : statut seulement. Admin : statut, et nom/client d'un projet créé à la main.
// La base l'impose aussi (déclencheur projets_avant_ecriture), même si l'écran est contourné.
export async function modifierProjet(_e: EtatAction, d: FormData): Promise<EtatAction> {
  const moi = await exigerRole();
  if (moi.role !== "admin" && moi.role !== "manager") return erreur("Action réservée à l'administrateur et aux managers.");
  const id = texte(d, "projet_id");
  const statut = texte(d, "statut");
  if (!id || !statut || !(STATUTS_PROJET as readonly string[]).includes(statut)) return erreur("Statut inconnu.");
  const valeurs: Record<string, string | null> = { statut };
  if (moi.role === "admin" && d.has("nom")) {
    const nom = texte(d, "nom");
    if (!nom) return erreur("Le nom du projet est obligatoire.");
    valeurs.nom = nom;
    if (d.has("client_id")) valeurs.client_id = texte(d, "client_id");
  }
  const supabase = await creerClientServeur();
  const { data, error } = await supabase.from("projets").update(valeurs).eq("id", id).select("id");
  if (error || !data?.length) return erreur(messageBase(error?.message ?? "Projet introuvable ou non modifiable."));
  revalidatePath("/rh/projets");
  return succes("Projet enregistré.");
}

// ---------- Temps ----------
export async function enregistrerTemps(_e: EtatAction, d: FormData): Promise<EtatAction> {
  const moi = await exigerRole();
  const id = texte(d, "temps_id");
  const collaborateur = texte(d, "collaborateur_id");
  const projet = texte(d, "projet_id");
  const date = texte(d, "date_saisie");
  if (!collaborateur || !projet || !date) return erreur("Collaborateur, projet et date sont obligatoires.");
  if (moi.role !== "admin" && collaborateur !== moi.collaborateurId) return erreur("Vous ne pouvez saisir que vos propres temps.");
  const heures = lireHeures(texte(d, "heures"));
  if (typeof heures === "string") return erreur(heures);
  const motif = moi.role === "admin" ? texte(d, "motif_derogation") : null;
  const { error } = await creerClientAdmin().rpc("rh_enregistrer_temps", {
    p_auteur: moi.id, p_temps_id: id, p_collaborateur_id: collaborateur, p_projet_id: projet, p_date: date,
    p_heures: heures, p_commentaire: texte(d, "commentaire"), p_motif_derogation: motif,
  });
  if (error) return erreur(messageBase(error.message));
  revalidatePath("/rh/temps");
  revalidatePath("/rh/validation");
  return succes(id ? "Temps corrigé." : "Temps enregistré (brouillon).");
}

export async function supprimerTemps(_e: EtatAction, d: FormData): Promise<EtatAction> {
  const moi = await exigerRole();
  const { error } = await creerClientAdmin().rpc("rh_supprimer_temps", { p_auteur: moi.id, p_temps_id: texte(d, "temps_id") });
  if (error) return erreur(messageBase(error.message));
  revalidatePath("/rh/temps");
  return succes("Brouillon supprimé.");
}

const ACTIONS: Record<string, string> = {
  soumettre: "Temps soumis.", retirer: "Temps retiré (brouillon).", renvoyer: "Temps renvoyé pour correction.",
  valider: "Temps validé.", rouvrir: "Temps rouvert (brouillon).", attester: "Attestation enregistrée (le temps reste soumis).",
};
export async function changerStatutTemps(_e: EtatAction, d: FormData): Promise<EtatAction> {
  const moi = await exigerRole();
  const action = texte(d, "action") ?? "";
  if (!(action in ACTIONS)) return erreur("Action inconnue.");
  if ((action === "valider" || action === "renvoyer") && moi.role !== "admin" && moi.role !== "manager") {
    return erreur("Action réservée aux responsables hiérarchiques et à l'administrateur.");
  }
  if (action === "rouvrir" && moi.role !== "admin") return erreur("Seul l'administrateur rouvre un temps validé.");
  const ids = d.getAll("temps_id").map(String).filter(Boolean);
  if (!ids.length) return erreur("Aucun temps sélectionné.");
  const motif = texte(d, "motif");
  if ((action === "renvoyer" || action === "rouvrir") && !motif) return erreur("Un motif est obligatoire.");
  const { error } = await creerClientAdmin().rpc("rh_changer_statut_temps", {
    p_auteur: moi.id, p_temps_ids: ids, p_action: action, p_motif: motif,
  });
  if (error) return erreur(messageBase(error.message));
  revalidatePath("/rh/temps");
  revalidatePath("/rh/validation");
  return succes(ACTIONS[action]);
}
