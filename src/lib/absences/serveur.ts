import "server-only";
import { randomUUID } from "node:crypto";
import { creerClientAdmin } from "@/lib/supabase/admin";
import { creerClientServeur } from "@/lib/supabase/serveur";
import { empreinteSha256 } from "@/lib/devis/archivage";
import { TAILLE_MAX_JUSTIFICATIF, TYPES_JUSTIFICATIF, signatureConforme, typeSelonSignature } from "@/lib/absences";

// Justificatifs : bucket PRIVÉ « justificatifs », sans aucun accès direct avec un jeton (même admin).
// - Dépôt : le serveur vérifie la session et les droits, puis émet un lien signé valable pour UN chemin neuf
//   (<fiche>/<aléatoire>.<ext>, jamais d'écrasement) ; le navigateur envoie le fichier directement au stockage
//   (pas de limite de taille des fonctions Vercel) ; le serveur relit ensuite le fichier stocké et contrôle sa
//   SIGNATURE (premiers octets) et sa taille, calcule son SHA-256, puis la base contrôle le reste.
// - Consultation : le serveur relit la note avec la session de l'utilisateur (droits et session active imposés
//   par la base), relit le fichier, vérifie son empreinte, puis redirige vers un lien temporaire (60 s), jamais stocké.
// - Suppression : seulement d'un fichier refusé pour son contenu et que la base dit NON rattaché ; les dépôts
//   abandonnés (plus d'une heure, jamais rattachés) sont listés par la base, jamais devinés ici.
const BUCKET = "justificatifs";
const DUREE_LIEN_SECONDES = 60;

// Session encore active (révocation, déconnexion, mot de passe à changer) : vérifiée par la base.
export async function accesActif(): Promise<boolean> {
  const supabase = await creerClientServeur();
  const { data, error } = await supabase.rpc("acces_actif");
  return !error && data === true;
}

export async function preparerDepot(collaborateurId: string, type: string, taille: number) {
  const ext = TYPES_JUSTIFICATIF[type];
  if (!ext) throw new Error("Format refusé : PDF, JPEG ou PNG uniquement.");
  if (!(taille > 0) || taille > TAILLE_MAX_JUSTIFICATIF) throw new Error("Fichier vide ou de plus de 10 Mo : refusé.");
  const chemin = `${collaborateurId}/${randomUUID()}.${ext}`;
  const { data, error } = await creerClientAdmin().storage.from(BUCKET).createSignedUploadUrl(chemin);
  if (error || !data) throw new Error(`Dépôt impossible pour le moment : ${error?.message ?? "lien non émis"}.`);
  return { chemin, url: data.signedUrl };
}

async function lire(chemin: string): Promise<Uint8Array | null> {
  const { data, error } = await creerClientAdmin().storage.from(BUCKET).download(chemin);
  if (error || !data) return null;
  return new Uint8Array(await data.arrayBuffer());
}

export type ControleFichier =
  | { ok: true; taille: number; empreinte: string }
  | { ok: false; contenuRefuse: boolean; message: string };

// Contrôle SERVEUR du fichier réellement stocké (le type et la taille annoncés par le navigateur ne prouvent rien).
export async function controlerFichierStocke(chemin: string, type: string): Promise<ControleFichier> {
  const octets = await lire(chemin);
  if (!octets) return { ok: false, contenuRefuse: false, message: "Justificatif introuvable dans le stockage : déposez le fichier à nouveau." };
  if (octets.length === 0 || octets.length > TAILLE_MAX_JUSTIFICATIF) {
    return { ok: false, contenuRefuse: true, message: "Fichier refusé : vide ou de plus de 10 Mo." };
  }
  if (!signatureConforme(type, octets)) {
    const reel = typeSelonSignature(octets);
    return {
      ok: false, contenuRefuse: true,
      message: reel
        ? "Fichier refusé : son contenu ne correspond pas à son extension (renommé ?). Déposez le fichier d'origine."
        : "Fichier refusé : son contenu n'est pas un PDF, un JPEG ou un PNG valide.",
    };
  }
  return { ok: true, taille: octets.length, empreinte: await empreinteSha256(octets) };
}

// Supprime un dépôt refusé, uniquement si la base confirme qu'aucune note (ni son historique) ne le porte.
export async function supprimerSiNonRattache(chemin: string): Promise<boolean> {
  const admin = creerClientAdmin();
  const { data: rattache, error } = await admin.rpc("abs_justificatif_rattache", { p_chemin: chemin });
  if (error || rattache !== false) return false;
  const { error: e2 } = await admin.storage.from(BUCKET).remove([chemin]);
  return !e2;
}

// Nettoyage des dépôts abandonnés (plus d'une heure, jamais rattachés) : liste établie par la base.
export async function nettoyerDepotsAbandonnes(): Promise<number> {
  const admin = creerClientAdmin();
  const { data, error } = await admin.rpc("abs_fichiers_orphelins");
  if (error) throw new Error(error.message);
  const chemins = (data as string[] | null) ?? [];
  let n = 0;
  for (const c of chemins) if (await supprimerSiNonRattache(c)) n++;
  return n;
}

// Lien temporaire de consultation, après vérification de l'empreinte du fichier stocké.
export async function lienConsultation(chemin: string, empreinte: string, taille: number): Promise<string> {
  const octets = await lire(chemin);
  if (!octets) throw new Error("Justificatif introuvable dans le stockage.");
  if (octets.length !== Number(taille) || (await empreinteSha256(octets)) !== empreinte) {
    throw new Error("Justificatif altéré (empreinte différente de celle enregistrée) : consultation bloquée. Prévenez l'administrateur.");
  }
  const { data, error } = await creerClientAdmin().storage.from(BUCKET).createSignedUrl(chemin, DUREE_LIEN_SECONDES);
  if (error || !data) throw new Error(`Lien de consultation indisponible : ${error?.message ?? "inconnu"}.`);
  return data.signedUrl;
}
