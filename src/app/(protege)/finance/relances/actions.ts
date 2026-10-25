"use server";

import { revalidatePath } from "next/cache";
import { redirect } from "next/navigation";
import { exigerAdmin } from "@/lib/session";
import { creerClientAdmin } from "@/lib/supabase/admin";
import { messageBase } from "@/lib/rh";
import type { EtatAction } from "@/lib/utilisateurs";

// Résolution d'une relance bloquante (administrateur, motif obligatoire) : constat seulement, JAMAIS de renvoi.
// exigerAdmin ici, puis la base revérifie l'auteur (administrateur actif) et toutes les règles.
export async function resoudreRelance(_e: EtatAction, d: FormData): Promise<EtatAction> {
  const moi = await exigerAdmin();
  const id = String(d.get("relance_id") ?? "");
  const date = String(d.get("date_envoi") ?? "").trim();
  // Date saisie en heure de Martinique (UTC−4, sans heure d'été).
  const dateEnvoi = date ? new Date(`${date}:00-04:00`).toISOString() : null;
  const { error } = await creerClientAdmin().rpc("relances_resoudre", {
    p_admin: moi.id, p_relance: id, p_constat: String(d.get("constat") ?? ""), p_motif: String(d.get("motif") ?? ""),
    p_date_envoi: dateEnvoi, p_fournisseur_id: String(d.get("fournisseur_id") ?? "").trim() || null,
  });
  if (error) return { statut: "erreur", message: messageBase(error.message) };
  revalidatePath(`/finance/relances/${id}`);
  redirect(`/finance/relances/${id}?confirmation=resolution`);
}
