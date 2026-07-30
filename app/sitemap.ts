import type { MetadataRoute } from "next";
import { publicRoutes, siteUrl } from "@/lib/site";

export default function sitemap(): MetadataRoute.Sitemap {
  const now = new Date();
  return publicRoutes.map((path) => ({
    url: path === "/" ? `${siteUrl}/` : `${siteUrl}${path}`,
    lastModified: now,
    priority: path === "/" ? 1 : 0.5,
  }));
}
