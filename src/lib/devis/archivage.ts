// Archivage du PDF d'un devis émis : une seule fois, puis toujours servi depuis l'archive.
// Règle : le fichier STOCKÉ fait foi. Si un fichier existe déjà au chemin du devis (génération
// concurrente, reprise après un échec d'enregistrement), il est relu et c'est lui qui est déclaré :
// même numéro, même document. Le numéro ne dépend jamais de cette étape (attribué à l'émission).
// Fichier sans dépendance serveur : testé hors Next.js avec un stockage simulé.

export type StockageDevis = {
  // Dépose sans jamais écraser ; renvoie "existe" si un fichier est déjà à ce chemin.
  deposer(chemin: string, contenu: Uint8Array): Promise<"depose" | "existe">;
  lire(chemin: string): Promise<Uint8Array | null>;
};

export type BaseDevis = {
  enregistrer(devisId: string, chemin: string, empreinte: string, taille: number): Promise<void>;
  signalerEchec(devisId: string, message: string): Promise<void>;
};

export type ResultatArchivage =
  | { statut: "disponible"; chemin: string; empreinte: string; taille: number; repris: boolean }
  | { statut: "echec"; message: string };

export function cheminDevis(devisId: string, numero: string): string {
  return `${devisId}/${numero}.pdf`;
}

export async function empreinteSha256(contenu: Uint8Array): Promise<string> {
  const octets = new Uint8Array(await crypto.subtle.digest("SHA-256", contenu as BufferSource));
  return Array.from(octets, (o) => o.toString(16).padStart(2, "0")).join("");
}

export async function archiverPdfDevis(
  devis: { id: string; numero: string },
  generer: () => Promise<Uint8Array>,
  stockage: StockageDevis,
  base: BaseDevis,
): Promise<ResultatArchivage> {
  const chemin = cheminDevis(devis.id, devis.numero);
  try {
    let contenu = await stockage.lire(chemin);
    let repris = contenu !== null;
    if (!contenu) {
      const genere = await generer();
      if ((await stockage.deposer(chemin, genere)) === "existe") {
        contenu = await stockage.lire(chemin); // déposé entre-temps par un autre traitement
        repris = true;
      } else contenu = genere;
    }
    if (!contenu || contenu.length === 0) throw new Error("fichier stocké illisible ou vide");
    const empreinte = await empreinteSha256(contenu);
    await base.enregistrer(devis.id, chemin, empreinte, contenu.length);
    return { statut: "disponible", chemin, empreinte, taille: contenu.length, repris };
  } catch (e) {
    const message = e instanceof Error ? e.message : String(e);
    try {
      await base.signalerEchec(devis.id, message);
    } catch {
      // l'état reste « à générer » : la prochaine reprise réessaiera
    }
    return { statut: "echec", message };
  }
}

// Téléchargement : le fichier archivé est vérifié contre l'empreinte enregistrée avant d'être servi.
export async function lireArchiveVerifiee(
  stockage: StockageDevis,
  chemin: string,
  empreinteAttendue: string,
): Promise<Uint8Array> {
  const contenu = await stockage.lire(chemin);
  if (!contenu) throw new Error("PDF archivé introuvable dans le stockage");
  if ((await empreinteSha256(contenu)) !== empreinteAttendue) {
    throw new Error("PDF archivé altéré : son empreinte ne correspond plus");
  }
  return contenu;
}
