"use server";

import { redirect } from "next/navigation";
import { creerClientServeur } from "@/lib/supabase/serveur";
import type { EtatConnexion } from "./etat";

export async function seConnecter(
  _etatPrecedent: EtatConnexion,
  donnees: FormData,
): Promise<EtatConnexion> {
  const email = String(donnees.get("email") ?? "").trim();
  const motDePasse = String(donnees.get("mot_de_passe") ?? "");

  if (!email || !motDePasse) {
    return { erreur: "Saisissez votre email et votre mot de passe." };
  }

  const supabase = await creerClientServeur();
  const { error } = await supabase.auth.signInWithPassword({
    email,
    password: motDePasse,
  });

  if (error) {
    return { erreur: traduireErreur(error.code, error.message) };
  }
  redirect("/");
}

export async function seDeconnecter() {
  const supabase = await creerClientServeur();
  await supabase.auth.signOut();
  redirect("/connexion");
}

function traduireErreur(code: string | undefined, message: string): string {
  switch (code) {
    case "invalid_credentials":
      return "Email ou mot de passe incorrect.";
    case "email_not_confirmed":
      return "Ce compte n'a pas encore été confirmé.";
    case "user_banned":
      return "Cet accès a été révoqué. Contactez un administrateur.";
    case "over_request_rate_limit":
      return "Trop de tentatives. Patientez quelques minutes.";
    default:
      return `Connexion impossible : ${message}`;
  }
}
