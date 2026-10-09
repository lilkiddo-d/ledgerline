import type { Metadata } from "next";
import type { ReactNode } from "react";
import "./globals.css";
import { Providers } from "./providers";
import { Nav } from "@/components/Nav";
import { RiskGate } from "@/components/RiskGate";

export const metadata: Metadata = {
  title: "Ledgerline",
  description: "Pooled money market for stablecoins and tokenized equities.",
};

export default function RootLayout({ children }: { children: ReactNode }) {
  return (
    <html lang="en">
      <body>
        <Providers>
          <Nav />
          <main>
            <div className="container">{children}</div>
          </main>
          <footer>
            <div className="container">
              <span>Ledgerline: experimental, unaudited software. Not investment advice.</span>
              <span>
                <a href="/risk">Risk disclosure</a>
              </span>
            </div>
          </footer>
          <RiskGate />
        </Providers>
      </body>
    </html>
  );
}
