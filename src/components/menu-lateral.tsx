"use client";

import Link from "next/link";
import { usePathname } from "next/navigation";
import { ENTREES_MENU, LIBELLES_ROLES, type Role } from "@/lib/navigation";
import { seDeconnecter } from "@/app/connexion/actions";

type Proprietes = {
  email: string;
  role: Role | null;
};

export function MenuLateral({ email, role }: Proprietes) {
  const cheminActuel = usePathname();
  const entreesVisibles = ENTREES_MENU.filter(
    (entree) => !entree.adminSeulement || role === "admin",
  );

  return (
    <aside className="flex w-60 shrink-0 flex-col bg-slate-900 text-slate-100">
      <div className="px-5 py-5 text-lg font-semibold">Mini-ERP SGI</div>

      <nav className="flex-1 space-y-1 px-3">
        {entreesVisibles.map((entree) => {
          const actif =
            entree.chemin === "/"
              ? cheminActuel === "/"
              : cheminActuel.startsWith(entree.chemin);
          return (
            <Link
              key={entree.chemin}
              href={entree.chemin}
              className={`block rounded-md px-3 py-2 text-sm ${
                actif ? "bg-slate-700 font-medium text-white" : "text-slate-300 hover:bg-slate-800"
              }`}
            >
              {entree.libelle}
            </Link>
          );
        })}
      </nav>

      <div className="border-t border-slate-700 px-5 py-4 text-sm">
        <p className="truncate font-medium" title={email}>
          {email}
        </p>
        <p className="text-slate-400">{role ? LIBELLES_ROLES[role] : "Rôle inconnu"}</p>
        <form action={seDeconnecter} className="mt-3">
          <button
            type="submit"
            className="w-full rounded-md border border-slate-600 px-3 py-1.5 text-slate-200 hover:bg-slate-800"
          >
            Se déconnecter
          </button>
        </form>
      </div>
    </aside>
  );
}
