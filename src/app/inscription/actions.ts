"use server";

import { redirect } from "next/navigation";
import { creerClientAdmin } from "@/lib/supabase/admin";
import { creerClientServeur } from "@/lib/supabase/serveur";
import type { EtatInscription } from "./etat";
import { unCompteExisteDeja } from "./comptes";

// Inscription à usage unique : ne fonctionne que tant qu'AUCUN compte n'existe.
// Le compte est créé côté serveur, déjà confirmé (pas d'email à attendre),
// puis l'utilisateur est connecté directement.
export async function creerPremierCompte(
  _etatPrecedent: EtatInscription,
  donnees: FormData,
): Promise<EtatInscription> {
  const nom = String(donnees.get("nom") ?? "").trim();
  const email = String(donnees.get("email") ?? "").trim().toLowerCase();
  const motDePasse = String(donnees.get("mot_de_passe") ?? "");
  const confirmation = String(donnees.get("confirmation") ?? "");

  if (!nom || !email || !motDePasse) {
    return { nom, email, erreur: "Tous les champs sont obligatoires." };
  }
  if (motDePasse.length < 10) {
    return { nom, email, erreur: "Le mot de passe doit contenir au moins 10 caractères." };
  }
  if (motDePasse !== confirmation) {
    return { nom, email, erreur: "Les deux mots de passe ne correspondent pas." };
  }

  if (await unCompteExisteDeja()) {
    return { nom, email, erreur: "L'inscription est fermée : un compte existe déjà." };
  }

  const admin = creerClientAdmin();
  const { data, error } = await admin.auth.admin.createUser({
    email,
    password: motDePasse,
    email_confirm: true,
    user_metadata: { nom },
  });
  if (error || !data.user) {
    return { nom, email, erreur: `Création du compte impossible : ${error?.message ?? "erreur inconnue"}` };
  }

  // Le déclencheur a créé la ligne profiles ; on y inscrit le nom saisi.
  await admin.from("profiles").update({ nom }).eq("id", data.user.id);

  const supabase = await creerClientServeur();
  const { error: erreurConnexion } = await supabase.auth.signInWithPassword({
    email,
    password: motDePasse,
  });
  if (erreurConnexion) {
    return {
      nom,
      email,
      erreur: `Compte créé, mais connexion automatique impossible : ${erreurConnexion.message}. Utilisez la page de connexion.`,
    };
  }
  redirect("/");
}
