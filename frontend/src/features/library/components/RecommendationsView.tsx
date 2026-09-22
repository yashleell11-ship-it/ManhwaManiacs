"use client";

import Link from "next/link";
import { Heart, TriangleAlert } from "lucide-react";
import {
  GlobalSearchResultCard,
  SearchResultCardSkeleton,
} from "@/features/library/components/GlobalSearchResultCard";
import { SuggestionPromptBox } from "@/features/library/components/SuggestionPromptBox";
import {
  droppedNotice,
  suggestionKey,
  suggestionsSubtitle,
} from "@/features/library/suggestions";
import {
  useRecommendations,
  useSuggest,
  useSuggestAvailability,
} from "@/features/library/hooks";
import { EmptyState } from "@/components/ui/empty-state";
import { OfflineState } from "@/components/ui/offline-state";
import { apiErrorMessage, resolveViewState } from "@/lib/view-state";

/**
 * "Describe what you feel like reading" → series this server can open.
 *
 * Grounded twice over. The server only ever picks from its own catalog cache,
 * so every card opens — a model asked to *recall* titles answers with
 * excellent books nothing here carries, and every one of those is a dead tap.
 * And the prompt carries what this profile has actually read, deepest first,
 * so the answer is this reader's rather than the same famous seven.
 *
 * The genre chips below are the old feature, kept: they are the cheapest start
 * when you do not feel like typing a sentence.
 */
export function RecommendationsView() {
  const recommendationsQuery = useRecommendations(20);
  const availabilityQuery = useSuggestAvailability();
  const suggest = useSuggest();

  const genres = recommendationsQuery.data ?? [];
  const suggestions = suggest.data?.items ?? [];
  const dropped = suggest.data?.dropped ?? 0;

  // An unconfigured server is a deployment state, not something to put in
  // front of a reader: the box is simply absent and the chips remain.
  const canAsk = availabilityQuery.data?.available === true;

  const viewState = resolveViewState({
    isLoading: recommendationsQuery.isLoading,
    error: recommendationsQuery.error,
    isEmpty: genres.length === 0,
  });

  return (
    <div className="page-shell">
      <div className="page-container">
        <div className="mb-8">
          <h1 className="page-title">Find something to read</h1>
          <p className="page-subtitle">
            {suggestionsSubtitle(canAsk, availabilityQuery.data?.reason)}
          </p>
        </div>

        {canAsk ? (
          <SuggestionPromptBox
            onSubmit={(prompt) => suggest.mutate({ prompt })}
            isPending={suggest.isPending}
            remainingToday={availabilityQuery.data?.remaining_today}
          />
        ) : null}

        {suggest.isPending ? (
          <div className="mb-10 space-y-3">
            {Array.from({ length: 4 }).map((_, i) => (
              <SearchResultCardSkeleton key={i} />
            ))}
          </div>
        ) : suggest.isError ? (
          <div className="mb-10">
            <EmptyState
              tone="error"
              icon={TriangleAlert}
              title="Couldn't suggest anything"
              description={apiErrorMessage(
                suggest.error,
                "Try describing it differently.",
              )}
            />
          </div>
        ) : suggestions.length > 0 ? (
          <div className="mb-10 space-y-3">
            {suggestions.map((item) => (
              <div key={suggestionKey(item)}>
                <GlobalSearchResultCard item={item} />
                {item.why ? (
                  <p className="mt-1.5 pl-1 text-sm text-muted">{item.why}</p>
                ) : null}
              </div>
            ))}
            {/* Said plainly rather than hidden: the model named things no
                source here carries, and those were thrown away rather than
                shown as cards that go nowhere. */}
            {droppedNotice(dropped) ? (
              <p className="pt-1 text-xs text-muted">{droppedNotice(dropped)}</p>
            ) : null}
          </div>
        ) : null}

        {canAsk && genres.length > 0 ? (
          <h2 className="mb-3 text-sm font-semibold uppercase tracking-wide text-muted">
            Or start from a genre
          </h2>
        ) : null}

        {viewState === "loading" ? (
          <div className="flex flex-wrap gap-3">
            {Array.from({ length: 8 }).map((_, i) => (
              <div key={i} className="h-9 w-28 animate-pulse rounded-full bg-surface-2" />
            ))}
          </div>
        ) : viewState === "offline" ? (
          <OfflineState
            reason="Recommendations need a connection to load."
            onRetry={() => void recommendationsQuery.refetch()}
          />
        ) : viewState === "error" ? (
          <EmptyState
            tone="error"
            icon={TriangleAlert}
            title="Couldn't load recommendations"
            description={apiErrorMessage(recommendationsQuery.error, "Something went wrong.")}
            action={{ label: "Try again", onClick: () => void recommendationsQuery.refetch() }}
          />
        ) : viewState === "empty" ? (
          <EmptyState
            icon={Heart}
            title="No recommendations yet"
            description="Follow a few series and their genres will show up here."
            action={{ label: "Browse Sources", href: "/sources" }}
          />
        ) : (
          <div className="flex flex-wrap gap-3">
            {genres.map((entry) => (
              <Link
                key={entry.genre}
                href={`/search?q=${encodeURIComponent(entry.genre)}`}
                className="inline-flex items-center gap-2 rounded-full border border-border/50 bg-white/[0.03] px-4 py-2 text-sm text-fg transition-colors hover:border-primary/40 hover:bg-primary/10 hover:text-primary"
              >
                <span className="capitalize">{entry.genre}</span>
                <span className="rounded-full bg-white/10 px-1.5 text-xs tabular-nums text-muted">
                  {entry.weight}
                </span>
              </Link>
            ))}
          </div>
        )}
      </div>
    </div>
  );
}
