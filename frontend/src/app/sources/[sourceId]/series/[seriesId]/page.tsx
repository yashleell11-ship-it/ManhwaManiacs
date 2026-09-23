import { SourceSeriesDetailView } from "@/features/sources";
import { decodeRouteParam } from "@/lib/route-params";

interface SourceSeriesPageProps {
  params: Promise<{ sourceId: string; seriesId: string }>;
  /**
   * `chapter` is a chapter KEY to open the contents at — what the novel
   * reader's Contents button links with (`novelContentsHref`). A key, not a
   * number: novel keys are row ordinals and never a printed chapter number.
   */
  searchParams: Promise<{ chapter?: string }>;
}

export default async function SourceSeriesPage({
  params,
  searchParams,
}: SourceSeriesPageProps) {
  const { sourceId, seriesId } = await params;
  const { chapter } = await searchParams;

  return (
    <SourceSeriesDetailView
      sourceId={decodeRouteParam(sourceId)}
      seriesId={decodeRouteParam(seriesId)}
      focusChapterKey={chapter?.trim() ? chapter : null}
    />
  );
}
