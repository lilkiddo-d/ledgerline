"use client";

import Link from "next/link";
import { usePathname } from "next/navigation";
import { ConnectButton } from "@rainbow-me/rainbowkit";
import { useAccount, useConnect, useDisconnect } from "wagmi";
import { devMockAccount, tokenFeaturesEnabled } from "@/lib/config";

const links = [
  { href: "/", label: "Markets" },
  { href: "/account", label: "Account" },
  { href: "/liquidations", label: "Liquidations" },
  ...(tokenFeaturesEnabled ? [{ href: "/stake", label: "Stake" }] : []),
  { href: "/risk", label: "Risk" },
];

function DevAccountButton() {
  const { connectors, connect } = useConnect();
  const { isConnected, connector } = useAccount();
  const { disconnect } = useDisconnect();
  const mock = connectors.find((c) => c.type === "mock");
  if (!devMockAccount || !mock) return null;
  if (isConnected && connector?.type === "mock") {
    return (
      <button className="btn small" onClick={() => disconnect()} title="Local fork dev account">
        Dev ✓
      </button>
    );
  }
  return (
    <button className="btn small" onClick={() => connect({ connector: mock })} title="Connect the impersonated anvil account">
      Dev account
    </button>
  );
}

export function Nav() {
  const path = usePathname();
  return (
    <nav className="nav">
      <div className="container nav-inner">
        <Link href="/" className="brand">
          <span className="brand-mark" aria-hidden />
          Ledgerline
        </Link>
        <div className="nav-links">
          {links.map((l) => (
            <Link key={l.href} href={l.href} className={path === l.href ? "active" : ""}>
              {l.label}
            </Link>
          ))}
        </div>
        <div className="nav-right">
          <DevAccountButton />
          <ConnectButton showBalance={false} chainStatus="icon" accountStatus="address" />
        </div>
      </div>
    </nav>
  );
}
