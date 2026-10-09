export const metadata = { title: "Unavailable · Ledgerline" };

export default function BlockedPage() {
  return (
    <div className="prose">
      <h1>Not available in your region</h1>
      <p className="sub">
        This interface is not available from your location. Tokenized equities are restricted in several jurisdictions.
      </p>
      <p>
        <a href="/risk">Read the risk disclosure</a>
      </p>
    </div>
  );
}
