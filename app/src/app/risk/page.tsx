export const metadata = { title: "Risk disclosure · Ledgerline" };

export default function RiskPage() {
  return (
    <div className="prose">
      <h1>Risk disclosure</h1>
      <p className="sub">Last updated 2026-10-09. Read this in full before supplying or borrowing.</p>

      <div className="notice warn">
        Ledgerline is experimental, unaudited software. You can lose some or all of the assets you deposit. Nothing on
        this site is investment, legal or tax advice, and no one associated with Ledgerline is acting as your broker,
        adviser or fiduciary.
      </div>

      <h2>1. Eligibility and jurisdiction</h2>
      <ul>
        <li>
          Tokenized equities on this network are issued by a third party under its own terms. Those terms state the
          tokens are not offered to U.S. persons and are restricted in other jurisdictions (including Canada, the United
          Kingdom and Switzerland). You are responsible for ensuring your use is lawful where you live.
        </li>
        <li>Stock tokens do not give you shareholder voting rights, and their issuer may pause transfers.</li>
        <li>This interface may block access from some regions. The smart contracts can include an allowlist that governance can switch on.</li>
      </ul>

      <h2>2. Liquidation risk</h2>
      <ul>
        <li>If your health factor falls below 1.00, anyone can repay part of your debt and take your collateral plus a liquidation bonus (5–10% depending on the asset).</li>
        <li>Below a health factor of 0.95 your entire debt in an asset can be repaid in one transaction.</li>
        <li>Borrowing a stock token is a <b>short position</b>: if its price rises, your debt grows in value and you can be liquidated.</li>
      </ul>

      <h2>3. Market hours and price gaps</h2>
      <ul>
        <li>Tokens trade around the clock, but the underlying stocks do not. Prices published while the US market is closed can be stale, and the price can jump (&quot;gap&quot;) when trading resumes.</li>
        <li>While the US market is closed, Ledgerline lowers the borrowing limit (LTV) on stock collateral and caps new stock borrowing. That reduces gap risk but does not remove it: a gap can move your position from healthy to liquidatable with no chance to react.</li>
        <li>Holiday and early-close schedules are maintained by governance and may be wrong.</li>
      </ul>

      <h2>4. Oracle risk</h2>
      <ul>
        <li>Prices come from Chainlink feeds through a swappable adapter. Staleness, deviation and sanity checks reduce, but do not eliminate, the risk of a bad price.</li>
        <li>If a feed is stale or paused, for example during a stock split, borrowing, withdrawing collateral and liquidations for affected accounts stop until prices resume.</li>
        <li>No L2 sequencer-uptime feed exists for this network today. If the sequencer halts, prices can move a lot when it resumes.</li>
      </ul>

      <h2>5. Bad debt and socialized losses</h2>
      <ul>
        <li>If a borrower&apos;s collateral is exhausted while debt remains, the protocol Reserve covers what it can. Any remainder is <b>socialized</b>: the value of every supplier&apos;s receipt tokens in that market is reduced.</li>
        <li>Suppliers may be unable to withdraw while utilization is high (most of the pool is lent out).</li>
      </ul>

      <h2>6. Smart-contract and governance risk</h2>
      <ul>
        <li>The contracts may contain bugs. Static analysis and tests do not guarantee safety.</li>
        <li>A 48-hour Timelock controls parameters such as LTVs, caps, oracles and interest-rate models. A guardian can pause the protocol or freeze markets instantly.</li>
        <li>Interest rates are variable and change with utilization; rates above 60% APR are possible when a market is fully used.</li>
      </ul>

      <h2>7. Token-specific risk</h2>
      <ul>
        <li>Stock tokens reflect corporate actions (dividends, splits) through a multiplier. During those events oracle updates may pause.</li>
        <li>USDG is a third-party stablecoin. A depeg directly affects the value of stablecoin collateral and debt.</li>
      </ul>

      <h2>8. No guarantees</h2>
      <p>
        The protocol is provided &quot;as is&quot;. APYs shown are estimates from current utilization and change every
        block. Past rates do not predict future rates.
      </p>
    </div>
  );
}
