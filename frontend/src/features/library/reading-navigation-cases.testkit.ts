import { readFileSync } from "node:fs";
import type { SourceChapterSummary } from "@/features/sources/types";

/**
 * The shared Continue / "Go to chapter" table, as the web's tests read it.
 *
 * One JSON file (`backend/tests/fixtures/reading_navigation_cases.json`) is read
 * by the backend, the web and the phone, so the continue-reading strip, both
 * clients' series pages and the history shelf cannot quietly answer the same
 * reading history differently again — which is how four resume rules came to
 * exist in the first place.
 */

interface CaseChapter {
  key: string;
  number: number | null;
  title: string;
}

export interface CaseProgressRow {
  chapter_key: string;
  chapter_number: number | null;
  last_page: number;
  page_count: number;
  is_completed: boolean;
  last_read_at: string;
}

export interface ContinueCase {
  name: string;
  book: string;
  progress: CaseProgressRow[];
  expect: { chapter_key: string; page: number } | "caught_up" | "start";
}

export interface PrintedNumberCase {
  title: string;
  number: number | null;
  expect: number | null;
}

export interface GotoCase {
  book: string;
  query: string;
  expect: string[];
}

interface Cases {
  books: Record<string, CaseChapter[]>;
  continue: ContinueCase[];
  printed_numbers: PrintedNumberCase[];
  goto: GotoCase[];
}

export const readingNavigationCases: Cases = JSON.parse(
  readFileSync(
    new URL(
      "../../../../backend/tests/fixtures/reading_navigation_cases.json",
      import.meta.url,
    ),
    "utf8",
  ),
) as Cases;

/** A fixture book as the chapter list the source endpoint serves. */
export function caseBook(name: string): SourceChapterSummary[] {
  const book = readingNavigationCases.books[name];
  if (!book) throw new Error(`no fixture book "${name}"`);
  return book.map((chapter) => ({
    id: chapter.key,
    source_id: "fixture",
    series_id: name,
    title: chapter.title,
    number: chapter.number,
    page_count: 0,
    release_date: null,
  }));
}
