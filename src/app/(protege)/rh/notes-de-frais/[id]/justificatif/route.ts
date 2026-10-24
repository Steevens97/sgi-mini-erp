import { lireUtilisateurCourant } from "@/lib/session";
import { creerClientServeur } from "@/lib/supabase/serveur";
import { lienConsultation } from "@/lib/absences/serveur";

// Consultation d'un justificatif. La note est relue avec la SESSION de l'utilisateur : la base ne la renvoie qu'à son
// propriétaire, au manager de son équipe directe ou à l'administrateur, et seulement si la session est encore active.
// Le fichier stocké est ensuite vérifié (taille, SHA-256) avant l'émission d'un lien temporaire de 60 s, jamais stocké.
// « ?ancien=n » : justificatif remplacé, conservé dans l'historique de la note (même contrôle).
export async function GET(requete: Request, { params }: { params: Promise<{ id: string }> }) {
  const moi = await lireUtilisateurCourant();
  if (!moi.role) return new Response("Profil illisible.", { status: 403 });
  const { id } = await params;
  const supabase = await creerClientServeur();
  const { data: note } = await supabase.from("notes_de_frais")
    .select("justificatif_url, justificatif_empreinte, justificatif_taille, historique").eq("id", id).maybeSingle();
  if (!note) return new Response("Justificatif introuvable ou non autorisé avec vos droits.", { status: 404 });
  let { justificatif_url: chemin, justificatif_empreinte: empreinte, justificatif_taille: taille } = note;
  const ancien = new URL(requete.url).searchParams.get("ancien");
  if (ancien !== null) {
    const versions = (note.historique as { action: string; avant?: { justificatif_url?: string; justificatif_empreinte?: string; justificatif_taille?: number } }[])
      .filter((e) => e.action === "modification" && e.avant?.justificatif_url).map((e) => e.avant!);
    const v = versions[Number(ancien)];
    if (!/^[0-9]+$/.test(ancien) || !v) return new Response("Ancien justificatif introuvable.", { status: 404 });
    chemin = v.justificatif_url!;
    empreinte = v.justificatif_empreinte!;
    taille = v.justificatif_taille ?? null;
  }
  try {
    const lien = await lienConsultation(chemin, empreinte, taille);
    return new Response(null, { status: 303, headers: { Location: lien, "Cache-Control": "private, no-store" } });
  } catch (e) {
    return new Response(e instanceof Error ? e.message : "Consultation impossible.", { status: 409 });
  }
}
