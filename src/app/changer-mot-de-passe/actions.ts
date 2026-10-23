"use server";

import { redirect } from "next/navigation";
import { creerClientServeur } from "@/lib/supabase/serveur";
import { creerClientAdmin } from "@/lib/supabase/admin";
import { INDICATEUR_CHANGEMENT_MDP, type EtatAction } from "@/lib/utilisateurs";

export async function changerMonMotDePasse(
  _e: EtatAction,
  donnees: FormData,
): Promise<EtatAction> {
  const supabase = await creerClientServeur();
  const {
    data: { user },
  } = await supabase.auth.getUser();
  if (!user) redirect("/connexion");

  const nouveau = String(donnees.get("nouveau") ?? "");
  const confirmation = String(donnees.get("confirmation") ?? "");
  if (nouveau.length < 10) {
    return { statut: "erreur", message: "Le mot de passe doit contenir au moins 10 caractères." };
  }
  if (nouveau !== confirmation) {
    return { statut: "erreur", message: "Les deux mots de passe ne correspondent pas." };
  }

  const { error } = await supabase.auth.updateUser({ password: nouveau });
  if (error) {
    const message =
      error.code === "same_password"
        ? "Choisissez un mot de passe différent de l'actuel."
        : error.code === "weak_password"
          ? "Mot de passe trop faible : allongez-le ou variez les caractères."
          : `Changement impossible : ${error.message}`;
    return { statut: "erreur", message };
  }

  // Levée de l'obligation (seule la clé secrète peut modifier app_metadata).
  if (user.app_metadata?.[INDICATEUR_CHANGEMENT_MDP]) {
    await creerClientAdmin().auth.admin.updateUserById(user.id, {
      app_metadata: { [INDICATEUR_CHANGEMENT_MDP]: false },
    });
    await supabase.auth.refreshSession();
  }
  redirect("/");
}
