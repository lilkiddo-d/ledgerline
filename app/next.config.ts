import type { NextConfig } from "next";
import path from "node:path";

// Optional deps of @coinbase/cdp-sdk (via RainbowKit -> @wagmi/connectors -> @base-org/account).
const OPTIONAL_STUBS = [
  "@x402/core/client",
  "@x402/evm",
  "@x402/evm/exact/client",
  "@x402/evm/upto/client",
  "@x402/svm/exact/client",
];

const nextConfig: NextConfig = {
  reactStrictMode: true,
  // The monorepo root holds /config (chain addresses shared with the contracts).
  outputFileTracingRoot: path.join(__dirname, ".."),
  turbopack: {
    root: path.join(__dirname, ".."),
    resolveAlias: Object.fromEntries(OPTIONAL_STUBS.map((m) => [m, "./src/stubs/empty.cjs"])),
  },
  experimental: { externalDir: true },
  webpack: (config) => {
    // wagmi/RainbowKit optional peer deps that are never used in the browser bundle
    config.externals.push("pino-pretty", "lokijs", "encoding");
    for (const m of OPTIONAL_STUBS) config.resolve.alias[m] = path.join(__dirname, "src/stubs/empty.cjs");
    return config;
  },
};

export default nextConfig;
