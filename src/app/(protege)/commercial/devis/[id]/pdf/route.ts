import { lireUtilisateurCourant } from "@/lib/session";
import { creerClientServeur } from "@/lib/supabase/serveur";
import { pdfArchive, pdfBrouillon } from "@/lib/devis/serveur";

// PDF d'un devis : brouillon → généré à la volée (filigrane, jamais stocké, aucune écriture) ;
// émis → fichier archivé, vérifié par son empreinte. Jamais de régénération d'un devis émis ici.
export async function GET(_requete: Request, { params }: { params: Promise<{ id: string }> }) {
  const { id } = await params;
  const moi = await lireUtilisateurCourant();
  if (moi.role !== "admin" && moi.role !== "manager") {
    return new Response("Accès réservé aux administrateurs et managers", { status: 403 });
  }
  const supabase = await creerClientServeur();
  const { data } = await supabase.from("devis").select("statut").eq("id", id).maybeSingle();
  if (!data) return new Response("Devis introuvable", { status: 404 });
  try {
    const { nom, contenu } = data.statut === "brouillon" ? await pdfBrouillon(id) : await pdfArchive(id);
    return new Response(contenu as BodyInit, {
      headers: {
        "Content-Type": "application/pdf",
        "Content-Disposition": `inline; filename="${nom}"`,
        "Cache-Control": "private, no-store",
      },
    });
  } catch (e) {
    return new Response(e instanceof Error ? e.message : "PDF indisponible", { status: 409 });
  }
}
