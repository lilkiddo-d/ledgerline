"use client";

import { useEffect, useState } from "react";
import { usePathname } from "next/navigation";

const KEY = "ledgerline:risk-ack:v1";

/** First-visit acknowledgement of the risk disclosure. Stored per browser; never blocks /risk itself. */
export function RiskGate() {
  const path = usePathname();
  const [open, setOpen] = useState(false);
  const [checked, setChecked] = useState(false);

  useEffect(() => {
    let acked = false;
    try {
      acked = window.localStorage.getItem(KEY) === "1";
    } catch {
      acked = false;
    }
    setOpen(!acked);
  }, []);

  if (!open || path === "/risk") return null;

  const accept = () => {
    try {
      window.localStorage.setItem(KEY, "1");
    } catch {
      /* storage unavailable: acknowledgement lasts for this page view */
    }
    setOpen(false);
  };

  return (
    <div className="modal-backdrop" role="dialog" aria-modal="true" aria-labelledby="risk-title">
      <div className="modal">
        <h2 id="risk-title">Before you continue</h2>
        <p className="muted">
          Ledgerline is experimental, unaudited software for lending and borrowing stablecoins and tokenized
          equities. You can lose all deposited funds through liquidation, oracle failure, smart-contract bugs,
          weekend price gaps or bad-debt socialization. Tokenized equities may be restricted in your
          jurisdiction, including for U.S. persons. Nothing here is investment advice.
        </p>
        <p>
          <a href="/risk" target="_blank" rel="noreferrer">
            Read the full risk disclosure
          </a>
        </p>
        <label style={{ display: "flex", gap: 8, alignItems: "flex-start", margin: "14px 0" }}>
          <input type="checkbox" checked={checked} onChange={(e) => setChecked(e.target.checked)} />
          <span>I have read the risk disclosure and confirm I am permitted to use this protocol where I live.</span>
        </label>
        <button className="btn primary" disabled={!checked} onClick={accept} style={{ width: "100%" }}>
          Continue
        </button>
      </div>
    </div>
  );
}
