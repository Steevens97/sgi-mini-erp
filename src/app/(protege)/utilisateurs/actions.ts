"use server";

import { revalidatePath } from "next/cache";
import { exigerAdmin } from "@/lib/session";
import { creerClientServeur } from "@/lib/supabase/serveur";
import { creerClientAdmin } from "@/lib/supabase/admin";
import { genererMotDePasseProvisoire } from "@/lib/mot-de-passe";
import {
  ROLES_ATTRIBUABLES,
  INDICATEUR_CHANGEMENT_MDP,
  estCompteProtege,
  type EtatAction,
} from "@/lib/utilisateurs";
import type { Role } from "@/lib/navigation";

// Chaque action commence par exigerAdmin() : le rôle est relu en base à chaque appel,
// indépendamment de ce qu'affiche la page. Les écritures sur profiles et collaborateurs
// passent par la session de l'admin (les règles RLS et les garde-fous en base s'appliquent) ;
// la clé secrète ne sert qu'aux opérations sur les comptes (auth).

const erreur = (message: string): EtatAction => ({ statut: "erreur", message });
const succes = (message: string): EtatAction => ({ statut: "succes", message });

function lireRole(valeur: FormDataEntryValue | null): Role | null {
  const role = String(valeur ?? "") as Role;
  return ROLES_ATTRIBUABLES.includes(role) ? role : null;
}

async function lireProfil(id: string) {
  const supabase = await creerClientServeur();
  const { data } = await supabase
    .from("profiles")
    .select("id, email, nom, role, collaborateur_id")
    .eq("id", id)
    .maybeSingle();
  return data;
}

async function compterAdmins(): Promise<number> {
  const supabase = await creerClientServeur();
  const { count } = await supabase
    .from("profiles")
    .select("id", { count: "exact", head: true })
    .eq("role", "admin");
  return count ?? 0;
}

async function trouverCompteParEmail(email: string) {
  const admin = creerClientAdmin();
  const { data } = await admin.auth.admin.listUsers({ page: 1, perPage: 1000 });
  return data?.users.find((u) => u.email?.toLowerCase() === email.toLowerCase()) ?? null;
}

// Crée le compte d'une fiche collaborateur et renvoie UNE FOIS un mot de passe provisoire.
export async function creerAcces(_e: EtatAction, donnees: FormData): Promise<EtatAction> {
  await exigerAdmin();
  const collaborateurId = String(donnees.get("collaborateur_id") ?? "");
  const role = lireRole(donnees.get("role"));
  if (!role) return erreur("Rôle invalide.");

  const supabase = await creerClientServeur();
  const { data: fiche } = await supabase
    .from("collaborateurs")
    .select("id, nom, prenom, email")
    .eq("id", collaborateurId)
    .maybeSingle();
  if (!fiche) return erreur("Fiche collaborateur introuvable.");
  const email = fiche.email?.trim().toLowerCase();
  if (!email) return erreur("Cette fiche n'a pas d'email : impossible de créer l'accès.");

  const { data: dejaRattache } = await supabase
    .from("profiles")
    .select("id")
    .eq("collaborateur_id", fiche.id)
    .maybeSingle();
  if (dejaRattache) return erreur("Cette fiche a déjà un accès.");
  if (await trouverCompteParEmail(email)) {
    return erreur(
      `Un compte existe déjà avec l'email ${email}. Utilisez « Rattacher » dans la section des comptes sans fiche.`,
    );
  }

  const nomComplet = [fiche.prenom, fiche.nom].filter(Boolean).join(" ");
  const motDePasse = genererMotDePasseProvisoire();
  const admin = creerClientAdmin();
  const { data: cree, error } = await admin.auth.admin.createUser({
    email,
    password: motDePasse,
    email_confirm: true,
    user_metadata: { nom: nomComplet },
    app_metadata: { [INDICATEUR_CHANGEMENT_MDP]: true },
  });
  if (error || !cree.user) {
    return erreur(`Création du compte impossible : ${error?.message ?? "erreur inconnue"}`);
  }

  const { data: maj, error: erreurProfil } = await supabase
    .from("profiles")
    .update({ role, collaborateur_id: fiche.id, nom: nomComplet, email })
    .eq("id", cree.user.id)
    .select("id");
  if (erreurProfil || !maj?.length) {
    // Annulation : pas de compte à moitié configuré.
    await admin.auth.admin.deleteUser(cree.user.id);
    return erreur(
      `Rattachement impossible, le compte a été annulé : ${erreurProfil?.message ?? "profil introuvable"}`,
    );
  }

  revalidatePath("/utilisateurs");
  return {
    statut: "succes",
    message: `Accès créé pour ${nomComplet}.`,
    motDePasseProvisoire: motDePasse,
    emailCompte: email,
  };
}

export async function changerRole(_e: EtatAction, donnees: FormData): Promise<EtatAction> {
  const moi = await exigerAdmin();
  const profilId = String(donnees.get("profil_id") ?? "");
  const role = lireRole(donnees.get("role"));
  if (!role) return erreur("Rôle invalide.");

  const cible = await lireProfil(profilId);
  if (!cible) return erreur("Compte introuvable.");
  if (cible.id === moi.id) return erreur("Vous ne pouvez pas modifier votre propre rôle.");
  if (estCompteProtege(cible.email)) return erreur("Ce compte est protégé : son rôle ne peut pas être modifié.");
  if (cible.role === role) return succes("Rôle inchangé.");
  if (cible.role === "admin" && (await compterAdmins()) <= 1) {
    return erreur("Impossible : ce compte est le dernier administrateur.");
  }

  const supabase = await creerClientServeur();
  const { data, error } = await supabase
    .from("profiles")
    .update({ role })
    .eq("id", cible.id)
    .select("id");
  if (error || !data?.length) {
    return erreur(`Modification refusée : ${error?.message ?? "aucune ligne modifiée"}`);
  }
  revalidatePath("/utilisateurs");
  return succes(`Rôle de ${cible.email} changé en « ${role} ».`);
}

export async function reinitialiserMotDePasse(
  _e: EtatAction,
  donnees: FormData,
): Promise<EtatAction> {
  const moi = await exigerAdmin();
  const cible = await lireProfil(String(donnees.get("profil_id") ?? ""));
  if (!cible) return erreur("Compte introuvable.");
  if (cible.id === moi.id) {
    return erreur("Pour votre propre compte, utilisez « Changer mon mot de passe » en bas du menu.");
  }
  if (estCompteProtege(cible.email)) return erreur("Ce compte est protégé.");

  const motDePasse = genererMotDePasseProvisoire();
  const admin = creerClientAdmin();
  const { error } = await admin.auth.admin.updateUserById(cible.id, {
    password: motDePasse,
    app_metadata: { [INDICATEUR_CHANGEMENT_MDP]: true },
  });
  if (error) return erreur(`Réinitialisation impossible : ${error.message}`);

  revalidatePath("/utilisateurs");
  return {
    statut: "succes",
    message: `Mot de passe réinitialisé pour ${cible.email}.`,
    motDePasseProvisoire: motDePasse,
    emailCompte: cible.email ?? "",
  };
}

// Supprime le compte de connexion ; la fiche collaborateur est conservée.
export async function revoquerAcces(_e: EtatAction, donnees: FormData): Promise<EtatAction> {
  const moi = await exigerAdmin();
  const cible = await lireProfil(String(donnees.get("profil_id") ?? ""));
  if (!cible) return erreur("Compte introuvable.");
  if (cible.id === moi.id) return erreur("Vous ne pouvez pas révoquer votre propre accès.");
  if (estCompteProtege(cible.email)) return erreur("Ce compte est protégé : il ne peut pas être révoqué.");
  if (cible.role === "admin" && (await compterAdmins()) <= 1) {
    return erreur("Impossible : ce compte est le dernier administrateur.");
  }

  const admin = creerClientAdmin();
  const { error } = await admin.auth.admin.deleteUser(cible.id);
  if (error) return erreur(`Révocation impossible : ${error.message}`);

  revalidatePath("/utilisateurs");
  return succes(`Accès de ${cible.email} révoqué. La fiche collaborateur est conservée.`);
}

// Rattache (ou détache, si aucune fiche n'est choisie) un compte existant à une fiche.
export async function rattacherCompte(_e: EtatAction, donnees: FormData): Promise<EtatAction> {
  await exigerAdmin();
  const cible = await lireProfil(String(donnees.get("profil_id") ?? ""));
  if (!cible) return erreur("Compte introuvable.");
  const collaborateurId = String(donnees.get("collaborateur_id") ?? "") || null;

  const supabase = await creerClientServeur();
  if (collaborateurId) {
    const { data: fiche } = await supabase
      .from("collaborateurs")
      .select("id")
      .eq("id", collaborateurId)
      .maybeSingle();
    if (!fiche) return erreur("Fiche collaborateur introuvable.");
    const { data: occupee } = await supabase
      .from("profiles")
      .select("id")
      .eq("collaborateur_id", collaborateurId)
      .neq("id", cible.id)
      .maybeSingle();
    if (occupee) return erreur("Cette fiche est déjà rattachée à un autre compte.");
  }

  const { data, error } = await supabase
    .from("profiles")
    .update({ collaborateur_id: collaborateurId })
    .eq("id", cible.id)
    .select("id");
  if (error || !data?.length) {
    return erreur(`Rattachement refusé : ${error?.message ?? "aucune ligne modifiée"}`);
  }
  revalidatePath("/", "layout");
  return succes(collaborateurId ? `Compte ${cible.email} rattaché.` : `Compte ${cible.email} détaché.`);
}

// Crée une fiche collaborateur ; peut la rattacher directement au compte de l'admin connecté.
export async function creerFiche(_e: EtatAction, donnees: FormData): Promise<EtatAction> {
  const moi = await exigerAdmin();
  const texte = (cle: string) => String(donnees.get(cle) ?? "").trim() || null;
  const nom = texte("nom");
  const tauxSaisi = texte("taux_horaire");
  const taux = tauxSaisi === null ? 0 : Number(tauxSaisi.replace(",", "."));
  const rattacher = donnees.get("rattacher_a_mon_compte") === "on";

  if (!nom) return erreur("Le nom est obligatoire.");
  if (!Number.isFinite(taux) || taux < 0) return erreur("Le taux horaire doit être un nombre positif ou 0.");
  if (rattacher && moi.collaborateurId) {
    return erreur("Votre compte est déjà rattaché à une fiche : détachez-le d'abord.");
  }

  const supabase = await creerClientServeur();
  const email = texte("email")?.toLowerCase() ?? null;
  if (email) {
    const { data: doublon } = await supabase
      .from("collaborateurs")
      .select("id")
      .ilike("email", email)
      .maybeSingle();
    if (doublon) return erreur(`Une fiche utilise déjà l'email ${email}.`);
  }

  const { data: fiche, error } = await supabase
    .from("collaborateurs")
    .insert({
      nom,
      prenom: texte("prenom"),
      email,
      poste: texte("poste"),
      date_entree: texte("date_entree"),
      taux_horaire: taux,
    })
    .select("id")
    .single();
  if (error || !fiche) return erreur(`Création de la fiche refusée : ${error?.message ?? "erreur inconnue"}`);

  if (rattacher) {
    const { data, error: erreurRattachement } = await supabase
      .from("profiles")
      .update({ collaborateur_id: fiche.id })
      .eq("id", moi.id)
      .select("id");
    if (erreurRattachement || !data?.length) {
      revalidatePath("/utilisateurs");
      return erreur(
        `Fiche créée, mais rattachement à votre compte refusé : ${erreurRattachement?.message ?? "aucune ligne modifiée"}`,
      );
    }
  }

  revalidatePath("/", "layout");
  return succes(rattacher ? "Fiche créée et rattachée à votre compte." : "Fiche créée.");
}
