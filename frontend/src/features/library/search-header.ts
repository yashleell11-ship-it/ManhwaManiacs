/**
 * The line over the search results: still searching, still waiting on the
 * rest, or done.
 *
 * A search is two requests: the reader's pinned and followed sources, then
 * everything else about eight seconds behind. Between the two the header used
 * to read "N results found" as though the answer were complete, while ~87
 * sources had not yet said anything. Saying "so far" there is the difference
 * between "nothing else matched" and "the rest is still coming".
 */
export function searchResultsHeader({
  searching,
  isLoadingRest,
  resultCount,
  sourcesDeferred,
}: {
  /** Tier 1 is in flight, or the typed query has not been sent yet. */
  searching: boolean;
  /** Tier 1 has answered and said there is a tier 2 still to come. */
  isLoadingRest: boolean;
  resultCount: number;
  /** How many sources tier 1 left for tier 2; absent on an untiered response. */
  sourcesDeferred: number | undefined;
}): string {
  if (searching) return "Searching sources…";
  const count = `${resultCount.toLocaleString()} ${resultCount === 1 ? "result" : "results"}`;
  if (!isLoadingRest) return `${count} found`;
  const more =
    sourcesDeferred && sourcesDeferred > 0
      ? `${sourcesDeferred.toLocaleString()} more ${sourcesDeferred === 1 ? "source" : "sources"}`
      : "more sources";
  return `${count} so far · searching ${more}…`;
}
