import { blocagesEmissionFacture } from "@/lib/entreprise";
import { FACTURATION_ELECTRONIQUE_PROVISOIRE, LIMITES_FINANCE } from "@/lib/finance";

// Bandeaux communs aux écrans Finance : émission réelle bloquée, limites de la version, facturation électronique.
export function BandeauxFinance() {
  const blocages = blocagesEmissionFacture();
  return (
    <div className="space-y-3">
      {blocages.length > 0 && (
        <div role="alert" className="rounded-md border border-amber-300 bg-amber-50 p-3 text-sm text-amber-900">
          <p className="font-medium">Émission réelle bloquée : informations de SG Ingénierie à confirmer.</p>
          <ul className="mt-1 list-disc pl-5">{blocages.map((b) => <li key={b}>{b}</li>)}</ul>
          <p className="mt-1">Les factures d&apos;essai (projets d&apos;ESSAI) restent possibles, avec des coordonnées de démonstration.</p>
        </div>
      )}
      <div className="rounded-md border border-slate-200 bg-slate-50 p-3 text-sm text-slate-700">
        <p className="font-medium">Limites de cette version</p>
        <ul className="mt-1 list-disc pl-5">{LIMITES_FINANCE.map((l) => <li key={l}>{l}</li>)}</ul>
      </div>
      <p className="rounded-md border border-sky-200 bg-sky-50 p-3 text-xs text-sky-900">{FACTURATION_ELECTRONIQUE_PROVISOIRE}</p>
    </div>
  );
}
