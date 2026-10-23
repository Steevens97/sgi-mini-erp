export function euros(n: number | string | null | undefined): string {
  const v = Number(n ?? 0);
  const [entier, dec] = Math.abs(v).toFixed(2).split(".");
  return `${v < 0 ? "-" : ""}${entier.replace(/\B(?=(\d{3})+(?!\d))/g, " ")},${dec} €`;
}

export function dateFr(iso: string | null | undefined): string {
  if (!iso) return "—";
  return new Date(iso).toLocaleDateString("fr-FR", { timeZone: "America/Martinique" });
}

export const LIBELLES_STATUT_DEVIS: Record<string, string> = {
  brouillon: "Brouillon", emis: "Émis", envoye: "Envoyé", accepte: "Accepté", refuse: "Refusé", remplace: "Remplacé",
};
export const LIBELLES_STATUT_PROSPECT: Record<string, string> = {
  contacte: "Contacté", devis_envoye: "Devis envoyé", gagne: "Gagné", perdu: "Perdu",
};
export const LIBELLES_CANAL: Record<string, string> = {
  email: "Email", main_propre: "Remise en main propre", courrier: "Courrier", plateforme: "Plateforme", autre: "Autre",
};
