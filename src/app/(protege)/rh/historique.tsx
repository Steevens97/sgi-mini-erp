import { LIBELLES_EVENEMENT, type EvenementTemps } from "@/lib/rh";

const quand = (iso: string | null) =>
  iso ? new Date(iso).toLocaleString("fr-FR", { timeZone: "America/Martinique", dateStyle: "short", timeStyle: "short" }) : "date inconnue";

// Historique d'un temps, tel qu'enregistré par la base (lecture seule).
export function Historique({ evenements }: { evenements: EvenementTemps[] }) {
  if (!evenements?.length) return null;
  return (
    <details className="text-xs text-slate-600">
      <summary className="cursor-pointer">Historique ({evenements.length})</summary>
      <ol className="mt-1 list-decimal space-y-1 pl-4">
        {evenements.map((e, i) => (
          <li key={i}>
            <strong>{LIBELLES_EVENEMENT[e.action] ?? e.action}</strong> — {quand(e.le)} — {e.auteur_nom ?? "auteur inconnu"}
            {e.motif ? ` — motif : ${e.motif}` : ""}
            {e.validation_precedente ? ` — validation précédente : ${e.validation_precedente.valide_par_nom ?? "inconnue"}${e.validation_precedente.valide_le ? ` (${quand(e.validation_precedente.valide_le)})` : ""}` : ""}
          </li>
        ))}
      </ol>
    </details>
  );
}
