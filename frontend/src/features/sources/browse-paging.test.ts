import { describe, expect, it } from "vitest";

import { browsePaging, type BrowsePagingInput } from "./browse-paging";

const loaded: BrowsePagingInput = {
  itemCount: 24,
  hasNextPage: true,
  isFetchingNextPage: false,
  isFetchNextPageError: false,
  hasError: false,
};

describe("browsePaging", () => {
  it("scrolls on to the next page while pages keep loading", () => {
    expect(browsePaging(loaded)).toMatchObject({
      autoLoad: true,
      showFullError: false,
      showLoadMoreRetry: false,
    });
  });

  it("has nothing to load after the last page", () => {
    expect(browsePaging({ ...loaded, hasNextPage: false }).autoLoad).toBe(false);
  });

  describe("a next page that failed", () => {
    // What TanStack leaves behind: hasNextPage still true from page 1, the
    // query in error, and the error attributed to the forward fetch.
    const failed: BrowsePagingInput = {
      ...loaded,
      isFetchNextPageError: true,
      hasError: true,
    };

    it("stops asking for it by itself", () => {
      expect(browsePaging(failed).autoLoad).toBe(false);
    });

    it("keeps every series already shown", () => {
      expect(browsePaging(failed).showFullError).toBe(false);
    });

    it("offers a retry of that one page under them", () => {
      expect(browsePaging(failed)).toMatchObject({ showLoadMoreRetry: true, retry: "next-page" });
    });

    it("hides the retry while the retry itself is loading", () => {
      expect(browsePaging({ ...failed, isFetchingNextPage: true }).showLoadMoreRetry).toBe(false);
      // …and still does not let the sentinel pile a second request on top.
      expect(browsePaging({ ...failed, isFetchingNextPage: true }).autoLoad).toBe(false);
    });
  });

  it("a first page that failed shows the full error, retried by reloading", () => {
    const answer = browsePaging({
      itemCount: 0,
      hasNextPage: false,
      isFetchingNextPage: false,
      isFetchNextPageError: false,
      hasError: true,
    });
    expect(answer).toMatchObject({
      autoLoad: false,
      showFullError: true,
      showLoadMoreRetry: false,
      retry: "refetch",
    });
  });

  it("with nothing on screen a failed next page still shows the error, retrying only that page", () => {
    // An empty first page that claimed more: there is nothing to keep, but a
    // reload would still re-request the page that did load.
    const answer = browsePaging({
      itemCount: 0,
      hasNextPage: true,
      isFetchingNextPage: false,
      isFetchNextPageError: true,
      hasError: true,
    });
    expect(answer).toMatchObject({ autoLoad: false, showFullError: true, retry: "next-page" });
  });
});
