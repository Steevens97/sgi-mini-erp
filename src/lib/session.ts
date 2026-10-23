import "server-only";
import { cache } from "react";
import { redirect } from "next/navigation";
import { creerClientServeur } from "@/lib/supabase/serveur";
import type { Role } from "@/lib/navigation";

export type UtilisateurCourant = {
  id: string;
  email: string;
  role: Role | null;
  nom: string | null;
  collaborateurId: string | null;
  // Explique pourquoi le profil n'a pas pu être lu (affiché à l'écran).
  problemeProfil: string | null;
};

// Lit l'utilisateur connecté et son profil ; redirige vers la connexion sinon.
// `cache` évite de relire la session plusieurs fois pendant un même affichage.
export const lireUtilisateurCourant = cache(
  async (): Promise<UtilisateurCourant> => {
    const supabase = await creerClientServeur();
    const {
      data: { user },
    } = await supabase.auth.getUser();

    if (!user) redirect("/connexion");

    const { data: profil, error } = await supabase
      .from("profiles")
      .select("role, nom, collaborateur_id")
      .eq("id", user.id)
      .maybeSingle();

    let problemeProfil: string | null = null;
    if (error) {
      problemeProfil = `Lecture du profil impossible : ${error.message}`;
    } else if (!profil) {
      problemeProfil = "Aucun profil n'existe pour ce compte.";
    }

    return {
      id: user.id,
      email: user.email ?? "",
      role: (profil?.role as Role | undefined) ?? null,
      nom: profil?.nom ?? null,
      collaborateurId: profil?.collaborateur_id ?? null,
      problemeProfil,
    };
  },
);

// À appeler en tête de chaque page ou action réservée aux administrateurs.
export async function exigerAdmin(): Promise<UtilisateurCourant> {
  const utilisateur = await lireUtilisateurCourant();
  if (utilisateur.role !== "admin") redirect("/");
  return utilisateur;
}
