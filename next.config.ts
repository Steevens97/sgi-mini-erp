import type { NextConfig } from "next";

const nextConfig: NextConfig = {
  // Rendu dynamique classique : chaque page protégée lit la session à chaque requête.
  cacheComponents: false,
  turbopack: {
    rules: {
      "*.css": {
        loaders: ["@tailwindcss/turbopack"],
        as: "*.css",
      },
    },
  },
};

export default nextConfig;
