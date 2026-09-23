export interface ChapterLabel {
  primary: string;
  secondary: string | null;
}

/**
 * Display label for a source chapter. The canonical chapter number always
 * leads; the source-provided title is separate metadata shown beneath it.
 * Only when a source has no chapter number does the title become the label.
 */
export function chapterLabel(chapter: {
  number: number | null;
  title: string | null;
}): ChapterLabel {
  const title = chapter.title?.trim() ?? "";
  if (chapter.number == null) {
    return { primary: title || "Chapter", secondary: null };
  }
  const primary = `Chapter ${chapter.number}`;
  return { primary, secondary: dedupeTitle(title, primary, chapter.number) };
}

/**
 * A title that is nothing but the chapter's own number, written without the
 * word in front of it: Royal Road serves "1. Good Morning Brother" for every
 * chapter of every fiction, and novelbin-family sources use "12 - " and "12: ".
 *
 * The lookahead is what keeps "12.5 Special" on chapter 12 intact: without it
 * the expression would take "12" and the "." as a separator and leave the row
 * reading "5 Special".
 */
export const BARE_ORDINAL_PREFIX = /^\s*(\d+(?:\.\d+)?)\s*[.):\-–—]\s*(?=\D|$)/;

/**
 * Sources often embed the chapter number in the title ("Chapter 134",
 * "Chapter 12: The Hunt", or Royal Road's bare "1. Good Morning Brother"). The
 * number line already shows it, so drop the redundant prefix — but never a
 * decimal continuation ("Chapter 12.5"), and never a number that is not this
 * chapter's ("125. …" on chapter 12 is a different chapter's title, and
 * "1000 Years" is a title that merely starts with digits).
 */
function dedupeTitle(title: string, primary: string, number: number): string | null {
  if (!title) {
    return null;
  }
  if (title.toLowerCase().startsWith(primary.toLowerCase())) {
    const rest = title.slice(primary.length);
    if (rest === "") {
      return null;
    }
    const separator = rest.match(/^\s*[:\-–—]\s*|^\s+/);
    if (separator) {
      return rest.slice(separator[0].length).trim() || null;
    }
    return title;
  }
  if (title.trim() === String(number)) {
    return null;
  }
  const bare = BARE_ORDINAL_PREFIX.exec(title);
  if (bare && Number(bare[1]) === number) {
    return title.slice(bare[0].length).trim() || null;
  }
  return title;
}
