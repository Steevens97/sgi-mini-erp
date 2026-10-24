"use server";

import { revalidatePath } from "next/cache";
import { redirect } from "next/navigation";
import { exigerAdmin, lireUtilisateurCourant } from "@/lib/session";
import { creerClientAdmin } from "@/lib/supabase/admin";
import { accesActif, controlerFichierStocke, nettoyerDepotsAbandonnes, preparerDepot, supprimerSiNonRattache } from "@/lib/absences/serveur";
import { CATEGORIES_FRAIS, TYPES_JUSTIFICATIF, cheminConforme, lireMontant, messageBaseAbsences } from "@/lib/absences";
import type { EtatAction } from "@/lib/utilisateurs";

// Notes de frais. Contrôles du SERVEUR (session active, droits, signature et taille du fichier stocké, SHA-256)
// puis de la BASE (emplacement du fichier, existence, taille et type stockés, délai de rattachement, catégories,
// montant, transitions, jamais pour soi). Toute écriture passe par les fonctions de service (clé secrète).

export type EtatNote = EtatAction & { fichierRejete?: boolean };
const erreur = (message: string, fichierRejete = false): EtatNote => ({ statut: "erreur", message, fichierRejete });
const succes = (message: string): EtatNote => ({ statut: "succes", message });
const texte = (d: FormData, cle: string) => String(d.get(cle) ?? "").trim() || null;

async function refusSession(moi: { role: string | null }): Promise<EtatNote | null> {
  if (!moi.role) return erreur("Profil illisible : action impossible.");
  if (!(await accesActif())) return erreur("Session expirée ou révoquée : reconnectez-vous.");
  return null;
}
const rafraichir = () => revalidatePath("/rh/notes-de-frais");
// La ligne change de section après une décision : confirmation affichée en haut de page (texte fixe).
function confirmer(code: string): never {
  redirect(`/rh/notes-de-frais?confirmation=${code}`);
}

// Étape 1 du dépôt : lien signé pour UN chemin neuf du dossier de la fiche concernée.
export async function preparerDepotJustificatif(collaborateurId: string, type: string, taille: number):
  Promise<{ ok: true; chemin: string; url: string } | { ok: false; message: string }> {
  const moi = await lireUtilisateurCourant();
  const refus = await refusSession(moi);
  if (refus) return { ok: false, message: refus.message };
  if (moi.role !== "admin" && collaborateurId !== moi.collaborateurId) {
    return { ok: false, message: "Vous ne pouvez déposer des justificatifs que pour vous-même." };
  }
  if (!/^[0-9a-f-]{36}$/.test(collaborateurId)) return { ok: false, message: "Fiche collaborateur inconnue." };
  if (!TYPES_JUSTIFICATIF[type]) return { ok: false, message: "Format refusé : PDF, JPEG ou PNG uniquement." };
  try {
    return { ok: true, ...(await preparerDepot(collaborateurId, type, taille)) };
  } catch (e) {
    return { ok: false, message: e instanceof Error ? e.message : "Dépôt impossible." };
  }
}

function champsNote(d: FormData) {
  return {
    date: texte(d, "date_depense"), categorie: texte(d, "categorie") ?? "", precision: texte(d, "categorie_precision"),
    objet: texte(d, "objet"), montant: lireMontant(texte(d, "montant")), chemin: texte(d, "chemin"), type: texte(d, "type") ?? "",
  };
}
function controleChamps(f: ReturnType<typeof champsNote>): string | null {
  if (!f.date) return "Date de la dépense obligatoire.";
  if (typeof f.montant === "string") return f.montant;
  if (!(CATEGORIES_FRAIS as readonly string[]).includes(f.categorie)) return "Catégorie inconnue.";
  if (f.categorie === "autre" && !f.precision) return "Catégorie « autre » : la précision est obligatoire.";
  if (!f.objet) return "L'objet de la dépense est obligatoire.";
  return null;
}

// Contrôle du fichier stocké ; un fichier refusé pour son contenu est supprimé s'il n'est rattaché à aucune note.
async function verifierJustificatif(chemin: string, type: string, collaborateurId: string) {
  if (!cheminConforme(chemin, collaborateurId, type)) {
    return { erreur: erreur("Justificatif : emplacement non conforme (dossier du collaborateur concerné uniquement).", true) };
  }
  const c = await controlerFichierStocke(chemin, type);
  if (c.ok) return { taille: c.taille, empreinte: c.empreinte };
  if (c.contenuRefuse) await supprimerSiNonRattache(chemin);
  return { erreur: erreur(c.message, true) };
}
// Messages de la base qui exigent un nouveau dépôt (le fichier déposé ne peut plus servir).
const exigeNouveauDepot = (m: string) => /absent du stockage|plus de 30 minutes|déjà rattaché|emplacement non conforme|stockée diffère|stocké diffère/.test(m);

export async function creerNote(_e: EtatNote, d: FormData): Promise<EtatNote> {
  const moi = await lireUtilisateurCourant();
  const refus = await refusSession(moi);
  if (refus) return refus;
  const collaborateur = texte(d, "collaborateur_id");
  if (!collaborateur) return erreur("Aucune fiche collaborateur : note impossible.");
  if (moi.role !== "admin" && collaborateur !== moi.collaborateurId) return erreur("Vous ne pouvez déposer des notes de frais que pour vous-même.");
  const f = champsNote(d);
  const r = controleChamps(f);
  if (r) return erreur(r);
  if (!f.chemin) return erreur("Justificatif obligatoire : déposez un fichier PDF, JPEG ou PNG.");
  const v = await verifierJustificatif(f.chemin, f.type, collaborateur);
  if (v.erreur) return v.erreur;
  const { data, error } = await creerClientAdmin().rpc("abs_creer_note", {
    p_auteur: moi.id, p_collaborateur: collaborateur, p_date: f.date, p_montant: f.montant, p_categorie: f.categorie,
    p_precision: f.precision, p_objet: f.objet, p_chemin: f.chemin, p_type: f.type, p_taille: v.taille, p_empreinte: v.empreinte,
  });
  if (error) return erreur(messageBaseAbsences(error.message), exigeNouveauDepot(error.message));
  rafraichir();
  if ((data as { deja_creee?: boolean } | null)?.deja_creee) return succes("Note déjà enregistrée (envoi répété) : aucun doublon créé.");
  return succes("Note de frais déposée : elle est « soumise » à votre responsable (jamais à vous-même).");
}

export async function modifierNote(_e: EtatNote, d: FormData): Promise<EtatNote> {
  const moi = await lireUtilisateurCourant();
  const refus = await refusSession(moi);
  if (refus) return refus;
  const note = texte(d, "note_id");
  const collaborateur = texte(d, "collaborateur_id");
  if (!note || !collaborateur) return erreur("Note introuvable.");
  if (moi.role !== "admin" && collaborateur !== moi.collaborateurId) return erreur("Vous ne pouvez modifier que vos propres notes de frais.");
  const f = champsNote(d);
  const r = controleChamps(f);
  if (r) return erreur(r);
  let fichier: { taille: number | null; empreinte: string | null } = { taille: null, empreinte: null };
  if (f.chemin) {
    const v = await verifierJustificatif(f.chemin, f.type, collaborateur);
    if (v.erreur) return v.erreur;
    fichier = { taille: v.taille, empreinte: v.empreinte };
  }
  const { error } = await creerClientAdmin().rpc("abs_modifier_note", {
    p_auteur: moi.id, p_note: note, p_date: f.date, p_montant: f.montant, p_categorie: f.categorie, p_precision: f.precision,
    p_objet: f.objet, p_chemin: f.chemin, p_type: f.chemin ? f.type : null, p_taille: fichier.taille, p_empreinte: fichier.empreinte,
  });
  if (error) return erreur(messageBaseAbsences(error.message), !!f.chemin && exigeNouveauDepot(error.message));
  rafraichir();
  return succes(f.chemin ? "Note modifiée ; l'ancien justificatif reste conservé dans l'historique." : "Note modifiée.");
}

export async function deciderNote(_e: EtatAction, d: FormData): Promise<EtatAction> {
  const moi = await lireUtilisateurCourant();
  const refus = await refusSession(moi);
  if (refus) return refus;
  if (moi.role !== "admin" && moi.role !== "manager") return erreur("Décision réservée aux responsables hiérarchiques et à l'administrateur.");
  const decision = texte(d, "decision");
  if (decision !== "valider" && decision !== "refuser") return erreur("Décision inconnue.");
  const motif = texte(d, "motif");
  if (decision === "refuser" && !motif) return erreur("Refus : un motif est obligatoire.");
  const { data, error } = await creerClientAdmin().rpc("abs_decider_note", {
    p_auteur: moi.id, p_note: texte(d, "note_id"), p_decision: decision, p_motif: motif,
  });
  if (error) return erreur(messageBaseAbsences(error.message));
  rafraichir();
  confirmer((data as { deja_decide?: boolean } | null)?.deja_decide ? "note_deja" : decision === "valider" ? "note_validee" : "note_refusee");
}

export async function declarerRemboursement(_e: EtatAction, d: FormData): Promise<EtatAction> {
  const moi = await exigerAdmin();
  const refus = await refusSession(moi);
  if (refus) return refus;
  const date = texte(d, "rembourse_le");
  if (!date) return erreur("Date du remboursement obligatoire.");
  const { data, error } = await creerClientAdmin().rpc("abs_declarer_remboursement", {
    p_auteur: moi.id, p_note: texte(d, "note_id"), p_date: date, p_reference: texte(d, "reference"),
  });
  if (error) return erreur(messageBaseAbsences(error.message));
  rafraichir();
  confirmer((data as { deja_declare?: boolean } | null)?.deja_declare ? "remboursement_deja" : "remboursement");
}

export async function corrigerRemboursement(_e: EtatAction, d: FormData): Promise<EtatAction> {
  const moi = await exigerAdmin();
  const refus = await refusSession(moi);
  if (refus) return refus;
  const action = texte(d, "action");
  if (action !== "annuler" && action !== "corriger") return erreur("Correction inconnue.");
  const motif = texte(d, "motif");
  if (!motif) return erreur("Correction : un motif est obligatoire.");
  const { error } = await creerClientAdmin().rpc("abs_corriger_remboursement", {
    p_auteur: moi.id, p_note: texte(d, "note_id"), p_action: action,
    p_date: action === "corriger" ? texte(d, "rembourse_le") : null, p_reference: action === "corriger" ? texte(d, "reference") : null,
    p_motif: motif,
  });
  if (error) return erreur(messageBaseAbsences(error.message));
  rafraichir();
  confirmer(action === "annuler" ? "annulation" : "correction");
}

export async function nettoyerDepots(): Promise<EtatAction> {
  const moi = await exigerAdmin();
  const refus = await refusSession(moi);
  if (refus) return refus;
  try {
    const n = await nettoyerDepotsAbandonnes();
    return succes(n ? `${n} dépôt(s) abandonné(s) supprimé(s) (plus d'une heure, rattachés à aucune note).` : "Aucun dépôt abandonné.");
  } catch (e) {
    return erreur(e instanceof Error ? e.message : "Nettoyage impossible.");
  }
}
