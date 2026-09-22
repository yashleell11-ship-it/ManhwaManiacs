import { describe, expect, it } from "vitest";

import { searchResultsHeader } from "./search-header";

describe("searchResultsHeader", () => {
  it("says it is searching while tier 1 is out", () => {
    expect(
      searchResultsHeader({
        searching: true,
        isLoadingRest: true,
        resultCount: 12,
        sourcesDeferred: 87,
      }),
    ).toBe("Searching sources…");
  });

  it("does not call tier 1 alone the finished answer", () => {
    // The regression: tier 1 had settled, tier 2 was eight seconds out, and
    // the header read "4 results found".
    expect(
      searchResultsHeader({
        searching: false,
        isLoadingRest: true,
        resultCount: 4,
        sourcesDeferred: 87,
      }),
    ).toBe("4 results so far · searching 87 more sources…");
  });

  it("still says more is coming when the deferred count is unknown", () => {
    expect(
      searchResultsHeader({
        searching: false,
        isLoadingRest: true,
        resultCount: 1,
        sourcesDeferred: undefined,
      }),
    ).toBe("1 result so far · searching more sources…");
  });

  it("reports the total once both tiers are in", () => {
    expect(
      searchResultsHeader({
        searching: false,
        isLoadingRest: false,
        resultCount: 1234,
        sourcesDeferred: 0,
      }),
    ).toBe(`${(1234).toLocaleString()} results found`);
  });
});
