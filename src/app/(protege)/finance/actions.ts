"use server";

import { revalidatePath } from "next/cache";
import { redirect } from "next/navigation";
import { exigerAdmin } from "@/lib/session";
import { creerClientAdmin } from "@/lib/supabase/admin";
import { aujourdhuiMartinique, messageBase } from "@/lib/rh";
import { lireParametresFacture, lireTarif } from "@/lib/finance";
import { conditionsFacture, emetteurFacture, GABARIT_FACTURE } from "@/lib/entreprise";
import { archiverFacture } from "@/lib/finance/serveur";
import type { EtatAction } from "@/lib/utilisateurs";

// Chaque action revérifie que l'utilisateur est administrateur (exigerAdmin), puis appelle une fonction de
// service de la base avec la clé secrète ; la base revérifie l'auteur (administrateur actif) et toutes les règles.
// Aucun email n'est envoyé : l'envoi et le règlement sont seulement déclarés.

const erreur = (message: string): EtatAction => ({ statut: "erreur", message });
const succes = (message: string): EtatAction => ({ statut: "succes", message });
const texte = (d: FormData, cle: string) => String(d.get(cle) ?? "").trim() || null;

// Après un envoi, un règlement, sa correction ou la reprise du PDF, la section du formulaire est remplacée par la
// suivante : la confirmation est donc affichée par la fiche facture (code connu, texte fixe), qui reste visible.
function confirmer(d: FormData, code: "pdf" | "envoi" | "reglement" | "correction"): never {
  const id = String(d.get("facture_id") ?? "");
  revalidatePath(`/finance/factures/${id}`);
  redirect(`/finance/factures/${id}?confirmation=${code}`);
}

export async function definirMode(_e: EtatAction, d: FormData): Promise<EtatAction> {
  const moi = await exigerAdmin();
  const { error } = await creerClientAdmin().rpc("finance_definir_mode", {
    p_auteur: moi.id, p_projet: texte(d, "projet_id"), p_mode: texte(d, "mode_facturation"),
  });
  if (error) return erreur(messageBase(error.message));
  revalidatePath("/finance/projets");
  return succes("Mode de facturation enregistré.");
}

// Nouveau tarif ou correction du dernier : l'empreinte des temps concernés, affichée avec leur liste, est
// renvoyée telle quelle ; si un temps a changé entre-temps (identité, date, heures), la base refuse.
export async function confirmerTarif(_e: EtatAction, d: FormData): Promise<EtatAction> {
  const moi = await exigerAdmin();
  const tarif = lireTarif(texte(d, "tarif"));
  if (typeof tarif === "string") return erreur(tarif);
  if (d.get("confirmation") !== "oui") return erreur("Cochez la confirmation des temps concernés.");
  const correction = texte(d, "periode_id");
  const admin = creerClientAdmin();
  const { error } = correction
    ? await admin.rpc("finance_corriger_tarif", {
        p_auteur: moi.id, p_projet: texte(d, "projet_id"), p_periode_id: correction, p_tarif: tarif,
        p_reference: texte(d, "reference"), p_motif: texte(d, "motif"), p_empreinte_temps: texte(d, "empreinte_temps"),
      })
    : await admin.rpc("finance_confirmer_tarif", {
        p_auteur: moi.id, p_projet: texte(d, "projet_id"), p_tarif: tarif, p_date_effet: texte(d, "date_effet"),
        p_reference: texte(d, "reference"), p_empreinte_temps: texte(d, "empreinte_temps"),
      });
  if (error) return erreur(messageBase(error.message));
  revalidatePath("/finance/projets");
  return succes(correction ? "Dernier tarif corrigé (l'ancienne valeur reste dans l'historique)." : "Tarif confirmé.");
}

// Émission : la clé d'émission vient de l'aperçu affiché. Un nouvel envoi du même formulaire (double clic,
// coupure réseau) retrouve la même facture ; si l'aperçu est périmé, rien n'est émis.
export async function emettreFacture(_e: EtatAction, d: FormData): Promise<EtatAction> {
  const moi = await exigerAdmin();
  const p = lireParametresFacture({ get: (n) => d.get(n) as string | null, getAll: (n) => d.getAll(n).map(String) });
  const essai = d.get("essai") === "oui";
  const { data, error } = await creerClientAdmin().rpc("finance_emettre_facture", {
    p_auteur: moi.id, p_cle_emission: texte(d, "cle_emission"), p_client: p.client, p_mois: p.mois, p_projets: p.projets,
    p_tva: p.tva, p_empreinte: texte(d, "empreinte"), p_emetteur: emetteurFacture(essai), p_conditions: conditionsFacture(essai),
    p_gabarit: GABARIT_FACTURE,
  });
  if (error) return erreur(messageBase(error.message));
  const facture = (data as { facture_id: string }).facture_id;
  await archiverFacture(facture); // en cas d'échec : la fiche de la facture propose la reprise
  revalidatePath("/finance");
  redirect(`/finance/factures/${facture}`);
}

export async function reprendrePdf(_e: EtatAction, d: FormData): Promise<EtatAction> {
  await exigerAdmin();
  const r = await archiverFacture(String(d.get("facture_id") ?? ""));
  if (r.statut !== "disponible") return erreur(`PDF non archivé : ${r.message}`);
  confirmer(d, "pdf");
}

export async function declarerEnvoi(_e: EtatAction, d: FormData): Promise<EtatAction> {
  const moi = await exigerAdmin();
  const date = texte(d, "date_envoi");
  const { error } = await creerClientAdmin().rpc("finance_declarer_envoi", {
    p_auteur: moi.id, p_facture: texte(d, "facture_id"), // Le jour même : l'heure actuelle ; un jour passé : midi (heure de Martinique).
    p_date_envoi: !date ? null : date === aujourdhuiMartinique() ? new Date().toISOString() : new Date(`${date}T12:00:00-04:00`).toISOString(),
    p_canal: texte(d, "canal"), p_destinataire: texte(d, "destinataire"),
  });
  if (error) return erreur(messageBase(error.message));
  confirmer(d, "envoi");
}

export async function enregistrerReglement(_e: EtatAction, d: FormData): Promise<EtatAction> {
  const moi = await exigerAdmin();
  const { error } = await creerClientAdmin().rpc("finance_enregistrer_reglement", {
    p_auteur: moi.id, p_facture: texte(d, "facture_id"), p_date: texte(d, "date_reglement"), p_mode: texte(d, "mode_reglement"),
    p_reference: texte(d, "reference_reglement"), p_integral: d.get("integral") === "oui",
  });
  if (error) return erreur(messageBase(error.message));
  confirmer(d, "reglement");
}

export async function corrigerReglement(_e: EtatAction, d: FormData): Promise<EtatAction> {
  const moi = await exigerAdmin();
  const { error } = await creerClientAdmin().rpc("finance_corriger_reglement", {
    p_auteur: moi.id, p_facture: texte(d, "facture_id"), p_action: texte(d, "action_correction"),
    p_date: texte(d, "date_reglement"), p_mode: texte(d, "mode_reglement"), p_reference: texte(d, "reference_reglement"),
    p_motif: texte(d, "motif"),
  });
  if (error) return erreur(messageBase(error.message));
  confirmer(d, "correction");
}
