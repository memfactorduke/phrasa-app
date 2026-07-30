"use client";

import { useEffect } from "react";

/**
 * Root layout errors replace the entire document. Inline styles only —
 * globals.css and fonts are unavailable here.
 */
export default function GlobalError({
  error,
  reset,
}: {
  error: Error & { digest?: string };
  reset: () => void;
}) {
  useEffect(() => {
    console.error(error);
  }, [error]);

  return (
    <html lang="en">
      <body
        style={{
          margin: 0,
          minHeight: "100dvh",
          display: "grid",
          placeItems: "center",
          backgroundColor: "#000000",
          color: "#ffffff",
          fontFamily:
            "ui-sans-serif, system-ui, -apple-system, Segoe UI, sans-serif",
          padding: "1.25rem",
          textAlign: "center",
        }}
      >
        <div style={{ maxWidth: "28rem" }}>
          <p
            style={{
              color: "#a3a3a3",
              fontSize: "0.75rem",
              letterSpacing: "0.18em",
              textTransform: "uppercase",
              fontWeight: 500,
            }}
          >
            Error
          </p>
          <h1
            style={{
              margin: "1rem 0 0",
              fontSize: "1.875rem",
              fontWeight: 500,
              letterSpacing: "-0.02em",
            }}
          >
            Something went wrong
          </h1>
          <p style={{ marginTop: "0.75rem", color: "#a3a3a3" }}>
            Please reload. If it keeps happening, try again shortly.
          </p>
          <button
            type="button"
            onClick={reset}
            style={{
              marginTop: "1.75rem",
              border: "none",
              borderRadius: "8px",
              backgroundColor: "#ffffff",
              color: "#000000",
              padding: "0.7rem 1.5rem",
              fontSize: "0.875rem",
              fontWeight: 500,
              cursor: "pointer",
              minHeight: "44px",
            }}
          >
            Reload
          </button>
        </div>
      </body>
    </html>
  );
}
