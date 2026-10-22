type Proprietes = { titre: string; description: string };

export function EnConstruction({ titre, description }: Proprietes) {
  return (
    <div>
      <h1 className="text-2xl font-semibold">{titre}</h1>
      <p className="mt-2 text-slate-600">{description}</p>
      <p className="mt-6 rounded-md border border-dashed border-slate-300 bg-white px-4 py-6 text-center text-sm text-slate-500">
        Module à venir.
      </p>
    </div>
  );
}
