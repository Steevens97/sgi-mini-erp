import { lireUtilisateurCourant } from "@/lib/session";
import { pdfFactureArchive } from "@/lib/finance/serveur";

// PDF d'une facture émise : fichier archivé, vérifié par son empreinte avant d'être servi. Jamais régénéré ici.
// Administrateur seulement (la lecture se fait avec la clé secrète, après ce contrôle).
export async function GET(_requete: Request, { params }: { params: Promise<{ id: string }> }) {
  const moi = await lireUtilisateurCourant();
  if (moi.role !== "admin") return new Response("Accès réservé à l'administrateur", { status: 403 });
  const { id } = await params;
  try {
    const { nom, contenu } = await pdfFactureArchive(id);
    return new Response(contenu as BodyInit, {
      headers: { "Content-Type": "application/pdf", "Content-Disposition": `inline; filename="${nom}"`, "Cache-Control": "private, no-store" },
    });
  } catch (e) {
    return new Response(e instanceof Error ? e.message : "PDF indisponible", { status: 409 });
  }
}
