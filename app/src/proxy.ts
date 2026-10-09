import { NextResponse, type NextRequest } from "next/server";

/**
 * Optional geoblock. GEOBLOCK_COUNTRIES is a comma-separated list of ISO-3166 alpha-2 codes
 * (e.g. "US,CA,GB,CH"). The country comes from Vercel's `x-vercel-ip-country` header; other
 * hosts can set the same header at their edge. Empty or unset = no blocking.
 * This is a best-effort interface control, not a substitute for the on-chain ComplianceRegistry.
 */
const blocked = new Set(
  (process.env.GEOBLOCK_COUNTRIES ?? "")
    .split(",")
    .map((c) => c.trim().toUpperCase())
    .filter(Boolean),
);

export function proxy(req: NextRequest) {
  if (blocked.size === 0) return NextResponse.next();
  const country = req.headers.get("x-vercel-ip-country")?.toUpperCase();
  if (country && blocked.has(country) && req.nextUrl.pathname !== "/blocked" && req.nextUrl.pathname !== "/risk") {
    return NextResponse.redirect(new URL("/blocked", req.url));
  }
  return NextResponse.next();
}

export const config = {
  matcher: ["/((?!_next/|favicon.ico|.*\\.(?:svg|png|jpg|ico|css|js)$).*)"],
};
