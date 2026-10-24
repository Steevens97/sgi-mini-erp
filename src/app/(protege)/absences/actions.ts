"use server";

import { revalidatePath } from "next/cache";
import { redirect } from "next/navigation";
import { exigerAdmin, lireUtilisateurCourant } from "@/lib/session";
import { creerClientAdmin } from "@/lib/supabase/admin";
import { accesActif } from "@/lib/absences/serveur";
import { TYPES_ABSENCE, controlerDemande, lireSolde, messageBaseAbsences } from "@/lib/absences";
import type { EtatAction } from "@/lib/utilisateurs";

// Chaque action relit l'utilisateur, son rôle et l'état de sa session. Congés et soldes ne s'écrivent QUE par les
// fonctions SQL de service (clé secrète) : elles reçoivent le compte connecté et revérifient tout en base
// (compte actif, propriétaire, valideur, demi-journées, chevauchements, soldes, jamais pour soi).

const erreur = (message: string): EtatAction => ({ statut: "erreur", message });
const succes = (message: string): EtatAction => ({ statut: "succes", message });
const texte = (d: FormData, cle: string) => String(d.get(cle) ?? "").trim() || null;

// Profil lisible et session encore active (sinon : message, aucune écriture).
async function refusSession(moi: { role: string | null }): Promise<EtatAction | null> {
  if (!moi.role) return erreur("Profil illisible : action impossible.");
  if (!(await accesActif())) return erreur("Session expirée ou révoquée : reconnectez-vous.");
  return null;
}

function rafraichir() {
  revalidatePath("/absences");
  revalidatePath("/absences/soldes");
}

export async function demanderConge(_e: EtatAction, d: FormData): Promise<EtatAction> {
  const moi = await lireUtilisateurCourant();
  const refus0 = await refusSession(moi);
  if (refus0) return refus0;
  const collaborateur = texte(d, "collaborateur_id");
  if (!collaborateur) return erreur("Aucune fiche collaborateur : demande impossible.");
  if (moi.role !== "admin" && collaborateur !== moi.collaborateurId) return erreur("Vous ne pouvez demander des congés que pour vous-même.");
  const type = texte(d, "type") ?? "";
  if (!(TYPES_ABSENCE as readonly string[]).includes(type)) return erreur("Type d'absence inconnu : congés payés, RTT ou sans solde.");
  const v = {
    debut: texte(d, "date_debut") ?? "", fin: texte(d, "date_fin") ?? "",
    apresMidi: d.get("debut_apres_midi") === "on", finMidi: d.get("fin_midi") === "on", jours: texte(d, "nb_jours") ?? "",
  };
  const refus = controlerDemande(v);
  if (refus) return erreur(refus);
  const { error } = await creerClientAdmin().rpc("abs_demander_conge", {
    p_auteur: moi.id, p_collaborateur: collaborateur, p_type: type, p_debut: v.debut, p_fin: v.fin,
    p_debut_apres_midi: v.apresMidi, p_fin_midi: v.finMidi, p_nb_jours: Number(v.jours.replace(",", ".")),
    p_motif: texte(d, "motif"), p_motif_retroactif: moi.role === "admin" ? texte(d, "motif_retroactif") : null,
  });
  if (error) return erreur(messageBaseAbsences(error.message));
  rafraichir();
  return succes("Demande enregistrée : elle reste « demandée » jusqu'à la décision d'un responsable (jamais la vôtre).");
}

export async function deciderConge(_e: EtatAction, d: FormData): Promise<EtatAction> {
  const moi = await lireUtilisateurCourant();
  const refus = await refusSession(moi);
  if (refus) return refus;
  if (moi.role !== "admin" && moi.role !== "manager") return erreur("Décision réservée aux responsables hiérarchiques et à l'administrateur.");
  const decision = texte(d, "decision");
  if (decision !== "valider" && decision !== "refuser") return erreur("Décision inconnue.");
  const motif = texte(d, "motif");
  if (decision === "refuser" && !motif) return erreur("Refus : un motif est obligatoire.");
  const { data, error } = await creerClientAdmin().rpc("abs_decider_conge", {
    p_auteur: moi.id, p_conge: texte(d, "conge_id"), p_decision: decision, p_motif: motif,
  });
  if (error) return erreur(messageBaseAbsences(error.message));
  rafraichir();
  const code = (data as { deja_decide?: boolean } | null)?.deja_decide ? "conge_deja" : decision === "valider" ? "conge_valide" : "conge_refuse";
  redirect(`/absences?confirmation=${code}`);
}

export async function ajusterSolde(_e: EtatAction, d: FormData): Promise<EtatAction> {
  const moi = await exigerAdmin();
  const refus = await refusSession(moi);
  if (refus) return refus;
  const collaborateur = texte(d, "collaborateur_id");
  if (collaborateur && collaborateur === moi.collaborateurId) return erreur("Vous ne pouvez pas ajuster votre propre solde.");
  const type = texte(d, "type");
  if (type !== "conges_payes" && type !== "rtt") return erreur("Solde inconnu : congés payés ou RTT.");
  const nouveau = lireSolde(texte(d, "nouveau"));
  if (typeof nouveau === "string") return erreur(nouveau);
  const motif = texte(d, "motif");
  if (!motif) return erreur("Ajustement : un motif est obligatoire.");
  const { error } = await creerClientAdmin().rpc("abs_ajuster_solde", {
    p_auteur: moi.id, p_collaborateur: collaborateur, p_type: type,
    p_ancien: Number(texte(d, type === "rtt" ? "ancien_rtt" : "ancien_cp")), p_nouveau: nouveau, p_motif: motif,
  });
  if (error) return erreur(messageBaseAbsences(error.message));
  rafraichir();
  redirect("/absences/soldes?confirmation=solde");
}
