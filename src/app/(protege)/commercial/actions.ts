"use server";

import { revalidatePath } from "next/cache";
import { redirect } from "next/navigation";
import { exigerCommercial } from "@/lib/session";
import { creerClientServeur } from "@/lib/supabase/serveur";
import { creerClientAdmin } from "@/lib/supabase/admin";
import { archiverDevis } from "@/lib/devis/serveur";
import {
  COORDONNEES_DEMO,
  GABARIT_DEVIS,
  TYPES_MISSION,
  blocagesEmission,
  emetteurPourMission,
  type TypeMission,
} from "@/lib/entreprise";
import type { EtatAction } from "@/lib/utilisateurs";

// Chaque action relit le rôle (exigerCommercial). Les écritures de brouillon passent par la session
// (règles RLS, droits de colonnes, déclencheurs) ; les changements de statut par les fonctions SQL
// réservées à la clé secrète, qui revérifient l'auteur en base.

const erreur = (message: string): EtatAction => ({ statut: "erreur", message });
const succes = (message: string): EtatAction => ({ statut: "succes", message });
const texte = (d: FormData, cle: string) => String(d.get(cle) ?? "").trim() || null;

function champsProspect(d: FormData) {
  const pays = texte(d, "pays")?.toUpperCase() ?? null;
  return {
    nom: texte(d, "nom"),
    societe: texte(d, "societe"),
    email: texte(d, "email")?.toLowerCase() ?? null,
    telephone: texte(d, "telephone"),
    source: texte(d, "source"),
    adresse: texte(d, "adresse"),
    code_postal: texte(d, "code_postal"),
    ville: texte(d, "ville"),
    pays,
  };
}

export async function creerProspect(_e: EtatAction, d: FormData): Promise<EtatAction> {
  await exigerCommercial();
  const champs = champsProspect(d);
  if (!champs.nom) return erreur("Le nom est obligatoire.");
  const supabase = await creerClientServeur();
  const { data, error } = await supabase.from("prospects").insert(champs).select("id").single();
  if (error || !data) return erreur(`Création refusée : ${error?.message ?? "erreur inconnue"}`);
  redirect(`/commercial/prospects/${data.id}`);
}

export async function modifierProspect(_e: EtatAction, d: FormData): Promise<EtatAction> {
  await exigerCommercial();
  const id = String(d.get("prospect_id") ?? "");
  const champs = champsProspect(d);
  if (!champs.nom) return erreur("Le nom est obligatoire.");
  const supabase = await creerClientServeur();
  const { data, error } = await supabase.from("prospects").update(champs).eq("id", id).select("id");
  if (error || !data?.length) return erreur(`Modification refusée : ${error?.message ?? "aucune ligne modifiée"}`);
  revalidatePath(`/commercial/prospects/${id}`);
  return succes("Prospect enregistré.");
}

export async function changerStatutProspect(_e: EtatAction, d: FormData): Promise<EtatAction> {
  await exigerCommercial();
  const id = String(d.get("prospect_id") ?? "");
  const statut = String(d.get("statut") ?? "");
  if (!["contacte", "perdu"].includes(statut)) {
    return erreur("Seuls « contacté » et « perdu » se choisissent ; les autres statuts découlent des devis.");
  }
  const supabase = await creerClientServeur();
  const { data, error } = await supabase.from("prospects").update({ statut }).eq("id", id).select("id");
  if (error || !data?.length) return erreur(`Changement refusé : ${error?.message ?? "aucune ligne modifiée"}`);
  revalidatePath(`/commercial/prospects/${id}`);
  return succes("Statut enregistré.");
}

export async function creerDevis(_e: EtatAction, d: FormData): Promise<EtatAction> {
  await exigerCommercial();
  const supabase = await creerClientServeur();
  const { data, error } = await supabase
    .from("devis")
    .insert({ prospect_id: String(d.get("prospect_id") ?? ""), regime_tva: null })
    .select("id")
    .single();
  if (error || !data) return erreur(`Création refusée : ${error?.message ?? "erreur inconnue"}`);
  redirect(`/commercial/devis/${data.id}`);
}

export async function enregistrerTva(_e: EtatAction, d: FormData): Promise<EtatAction> {
  await exigerCommercial();
  const id = String(d.get("devis_id") ?? "");
  const regime = texte(d, "regime_tva");
  const typeMission = texte(d, "type_mission");
  if (typeMission && !TYPES_MISSION.some((m) => m.valeur === typeMission)) return erreur("Type de mission inconnu.");
  const territoire = texte(d, "territoire_tva");
  const tauxSaisi = texte(d, "taux_tva");
  const taux = regime === "taxable" && tauxSaisi ? Number(tauxSaisi.replace(",", ".")) : null;
  if (regime === "taxable" && (taux === null || !Number.isFinite(taux))) return erreur("Taux de TVA invalide.");
  const criteres = Object.fromEntries(
    ["nature_mission", "statut_client", "lieu_client", "lieu_immeuble", "numero_tva_client", "justification_taux"]
      .map((cle) => [cle, texte(d, cle)])
      .filter(([, v]) => v !== null),
  );
  const supabase = await creerClientServeur();
  const { data, error } = await supabase
    .from("devis")
    .update({
      regime_tva: regime,
      territoire_tva: territoire,
      pays_tva: territoire === "UE" || territoire === "AUTRE" ? texte(d, "pays_tva")?.toUpperCase() ?? null : null,
      taux_tva: taux,
      mention_tva: texte(d, "mention_tva"),
      criteres_tva: regime ? criteres : null,
      type_mission: typeMission,
    })
    .eq("id", id)
    .select("id");
  if (error || !data?.length) return erreur(error?.message ?? "Aucune ligne modifiée.");
  revalidatePath(`/commercial/devis/${id}`);
  return succes("Traitement fiscal enregistré (totaux recalculés par la base).");
}

function nombre(d: FormData, cle: string): number | null {
  const v = texte(d, cle);
  if (v === null) return null;
  const n = Number(v.replace(",", "."));
  return Number.isFinite(n) ? n : null;
}

// Colonnes de la base : quantite numeric(10,2), prix_unitaire numeric(12,2). Une 3e décimale serait
// arrondie en silence par la base : on la refuse ici avec un message clair.
function controleLigne(d: FormData): string | null {
  const deuxDecimales = /^-?[0-9]+([.,][0-9]{1,2})?$/;
  const q = texte(d, "quantite") ?? "", p = texte(d, "prix_unitaire") ?? "";
  if (!deuxDecimales.test(q)) return "Quantité : nombre avec au plus 2 décimales (ex. 1,5).";
  if (!deuxDecimales.test(p)) return "Prix unitaire : montant avec au plus 2 décimales (ex. 100,33).";
  if (Math.abs(Number(q.replace(",", "."))) >= 1e8) return "Quantité trop élevée.";
  if (Math.abs(Number(p.replace(",", "."))) >= 1e10) return "Prix unitaire trop élevé.";
  return null;
}

export async function ajouterLigne(_e: EtatAction, d: FormData): Promise<EtatAction> {
  await exigerCommercial();
  const devisId = String(d.get("devis_id") ?? "");
  const quantite = nombre(d, "quantite");
  const prix = nombre(d, "prix_unitaire");
  if (!texte(d, "designation") || quantite === null || prix === null) {
    return erreur("Désignation, quantité et prix unitaire sont obligatoires.");
  }
  const refus = controleLigne(d);
  if (refus) return erreur(refus);
  const supabase = await creerClientServeur();
  const { error } = await supabase
    .from("devis_lignes")
    .insert({ devis_id: devisId, designation: texte(d, "designation"), quantite, prix_unitaire: prix });
  if (error) return erreur(error.message);
  revalidatePath(`/commercial/devis/${devisId}`);
  return succes("Ligne ajoutée.");
}

export async function modifierLigne(_e: EtatAction, d: FormData): Promise<EtatAction> {
  await exigerCommercial();
  const devisId = String(d.get("devis_id") ?? "");
  const quantite = nombre(d, "quantite");
  const prix = nombre(d, "prix_unitaire");
  if (!texte(d, "designation") || quantite === null || prix === null) return erreur("Ligne incomplète.");
  const refus = controleLigne(d);
  if (refus) return erreur(refus);
  const supabase = await creerClientServeur();
  const { data, error } = await supabase
    .from("devis_lignes")
    .update({ designation: texte(d, "designation"), quantite, prix_unitaire: prix })
    .eq("id", String(d.get("ligne_id") ?? ""))
    .select("id");
  if (error || !data?.length) return erreur(error?.message ?? "Aucune ligne modifiée.");
  revalidatePath(`/commercial/devis/${devisId}`);
  return succes("Ligne enregistrée.");
}

export async function supprimerLigne(_e: EtatAction, d: FormData): Promise<EtatAction> {
  await exigerCommercial();
  const devisId = String(d.get("devis_id") ?? "");
  const supabase = await creerClientServeur();
  const { data, error } = await supabase
    .from("devis_lignes")
    .delete()
    .eq("id", String(d.get("ligne_id") ?? ""))
    .select("id");
  if (error || !data?.length) return erreur(error?.message ?? "Aucune ligne supprimée.");
  revalidatePath(`/commercial/devis/${devisId}`);
  return succes("Ligne supprimée.");
}

export async function supprimerBrouillon(_e: EtatAction, d: FormData): Promise<EtatAction> {
  await exigerCommercial();
  const supabase = await creerClientServeur();
  const { data: devis } = await supabase
    .from("devis")
    .select("prospect_id")
    .eq("id", String(d.get("devis_id") ?? ""))
    .maybeSingle();
  const { data, error } = await supabase
    .from("devis")
    .delete()
    .eq("id", String(d.get("devis_id") ?? ""))
    .select("id");
  if (error || !data?.length) return erreur(error?.message ?? "Suppression refusée.");
  redirect(devis ? `/commercial/prospects/${devis.prospect_id}` : "/commercial");
}

export async function emettre(_e: EtatAction, d: FormData): Promise<EtatAction> {
  const moi = await exigerCommercial();
  const id = String(d.get("devis_id") ?? "");
  const admin = creerClientAdmin();
  const { data: devis } = await admin.from("devis").select("essai, type_mission").eq("id", id).maybeSingle();
  if (!devis) return erreur("Devis introuvable.");
  // Devis réel : coordonnées réelles complètes et assurance selon la mission (la base le revérifie).
  const type = devis.type_mission as TypeMission | null;
  const blocages = devis.essai ? [] : blocagesEmission(type);
  if (blocages.length) return erreur(`Émission bloquée : ${blocages.join(" ; ")}.`);
  const emetteur = devis.essai
    ? { ...COORDONNEES_DEMO, obligation_assurance: "non_requise" }
    : emetteurPourMission(type as TypeMission);
  const { data: numero, error } = await admin.rpc("emettre_devis", {
    p_devis_id: id, p_auteur: moi.id, p_emetteur: emetteur, p_gabarit: GABARIT_DEVIS,
  });
  if (error || !numero) return erreur(error?.message ?? "Émission refusée.");
  const archive = await archiverDevis(id);
  revalidatePath(`/commercial/devis/${id}`);
  return archive.statut === "disponible"
    ? succes(`Devis émis : ${numero}. PDF archivé.`)
    : erreur(`Devis émis : ${numero} (numéro conservé). PDF non archivé : ${archive.message}. Utilisez « Régénérer le PDF ».`);
}

export async function regenererPdf(_e: EtatAction, d: FormData): Promise<EtatAction> {
  await exigerCommercial();
  const id = String(d.get("devis_id") ?? "");
  const archive = await archiverDevis(id);
  revalidatePath(`/commercial/devis/${id}`);
  return archive.statut === "disponible" ? succes("PDF archivé et disponible.") : erreur(`PDF non archivé : ${archive.message}`);
}

export async function declarerEnvoi(_e: EtatAction, d: FormData): Promise<EtatAction> {
  const moi = await exigerCommercial();
  const id = String(d.get("devis_id") ?? "");
  const date = texte(d, "date_envoi"); // « AAAA-MM-JJTHH:MM », heure de Martinique
  const canal = texte(d, "canal_envoi");
  if (!date || !canal) return erreur("Date et canal d'envoi obligatoires.");
  const { error } = await creerClientAdmin().rpc("declarer_envoi_devis", {
    p_devis_id: id, p_auteur: moi.id, p_date_envoi: `${date}:00-04:00`, p_canal: canal,
    p_destinataire: texte(d, "envoi_destinataire"),
  });
  if (error) return erreur(error.message);
  revalidatePath(`/commercial/devis/${id}`);
  return succes("Envoi déclaré.");
}

export async function decider(_e: EtatAction, d: FormData): Promise<EtatAction> {
  const moi = await exigerCommercial();
  const id = String(d.get("devis_id") ?? "");
  const decision = String(d.get("decision") ?? "");
  const { error } = await creerClientAdmin().rpc("decider_devis", { p_devis_id: id, p_auteur: moi.id, p_decision: decision });
  if (error) return erreur(error.message);
  revalidatePath(`/commercial/devis/${id}`);
  return succes(decision === "accepte" ? "Devis accepté : client et projet créés automatiquement." : "Devis refusé.");
}

export async function nouvelleVersion(_e: EtatAction, d: FormData): Promise<EtatAction> {
  const moi = await exigerCommercial();
  const { data, error } = await creerClientAdmin().rpc("creer_nouvelle_version_devis", {
    p_devis_id: String(d.get("devis_id") ?? ""), p_auteur: moi.id,
  });
  if (error || !data) return erreur(error?.message ?? "Création refusée.");
  redirect(`/commercial/devis/${data}`);
}

export async function creerAvenant(_e: EtatAction, d: FormData): Promise<EtatAction> {
  const moi = await exigerCommercial();
  const { data, error } = await creerClientAdmin().rpc("creer_avenant_devis", {
    p_devis_id: String(d.get("devis_id") ?? ""), p_auteur: moi.id,
  });
  if (error || !data) return erreur(error?.message ?? "Création refusée.");
  redirect(`/commercial/devis/${data}`);
}
