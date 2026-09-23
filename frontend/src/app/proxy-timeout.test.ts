import { readFileSync } from "node:fs";
import { join } from "node:path";
import { describe, expect, it } from "vitest";
import nextConfig from "../../next.config";

// The browser reaches the backend only through the /api rewrite, and Next
// answers 500 for any request it has waited on longer than proxyTimeout. An
// AI suggestion is paid for when DeepSeek answers, so a rewrite that gives up
// first charges the reader's allowance and shows them "Couldn't suggest
// anything". Read from the backend's own source so raising its deadline
// without this one fails here rather than in production.
const SUGGESTION_SERVICE = join(
  __dirname,
  "../../../backend/services/suggestion_service.py",
);

// deepseek_client pauses this long before its one retry.
const RETRY_PAUSE_MS = 2_000;

function suggestionDeadlineMs(): number {
  const source = readFileSync(SUGGESTION_SERVICE, "utf8");
  const match = /^TIMEOUT_SECONDS = ([\d.]+)$/m.exec(source);
  if (!match) throw new Error("TIMEOUT_SECONDS not found in suggestion_service.py");
  return Number(match[1]) * 1000;
}

describe("the /api rewrite", () => {
  it("waits out the whole AI suggestion call, retry included", () => {
    const proxyTimeout = nextConfig.experimental?.proxyTimeout ?? 30_000;
    expect(proxyTimeout).toBeGreaterThan(suggestionDeadlineMs() + RETRY_PAUSE_MS);
  });
});
