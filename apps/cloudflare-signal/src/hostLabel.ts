// The account name rule for a Mac, as the Worker applies it before calling
// Convex. convex/hostLabel.ts holds Convex's copy; test/hostLabel.test.ts checks
// that both give the same answer. The PWA and the Mac app apply the same rule.

/** Longest account name for a Mac, counted in Unicode code points. */
export const HOST_LABEL_MAX_CHARACTERS = 40;

/**
 * Characters a Mac's name may not contain: control characters (Cc), the line
 * and paragraph separators, the bidi controls (U+202A-U+202E, U+2066-U+2069,
 * U+200E, U+200F), and the invisible U+200B, U+2060 and U+FEFF. The zero width
 * joiner and non-joiner (U+200D, U+200C) are allowed: emoji sequences and
 * Persian names need them.
 */
export const HOST_LABEL_HIDDEN_CHARACTERS =
  /[\p{Cc}\u2028\u2029\u202A-\u202E\u2066-\u2069\u200E\u200F\u200B\u2060\uFEFF]/u;
const HOST_LABEL_HIDDEN_CHARACTERS_ALL = new RegExp(HOST_LABEL_HIDDEN_CHARACTERS.source, "gu");
/** Hidden characters that separate words or lines; a proposed name keeps a space for them. */
const HOST_LABEL_BREAKS = /[\t\n\v\f\r\u0085\u2028\u2029]+/gu;

/** The name a Mac gets when the name it proposes has nothing visible left. */
export const PROPOSED_HOST_LABEL_FALLBACK = "This Mac";

/** The messages a rename answers with (HTTP 400); the PWA shows them as they are. */
export const HOST_LABEL_ERRORS = {
  empty: "Enter a name.",
  hiddenCharacters: "Remove hidden characters from the name.",
  tooLong: `Use ${HOST_LABEL_MAX_CHARACTERS} characters or fewer.`,
} as const;

export type HostLabelResult = { ok: true; label: string } | { ok: false; error: string };

/**
 * A Mac's account name from a rename request: normalized to NFC and trimmed,
 * then refused if it is empty (or not text), has a hidden character, or is
 * longer than 40 code points, in that order. On success `label` is the value
 * Convex stores.
 */
export function hostLabelFromInput(value: unknown): HostLabelResult {
  const label = typeof value === "string" ? value.normalize("NFC").trim() : "";
  if (!label) return { ok: false, error: HOST_LABEL_ERRORS.empty };
  if (HOST_LABEL_HIDDEN_CHARACTERS.test(label)) return { ok: false, error: HOST_LABEL_ERRORS.hiddenCharacters };
  if (Array.from(label).length > HOST_LABEL_MAX_CHARACTERS) return { ok: false, error: HOST_LABEL_ERRORS.tooLong };
  return { ok: true, label };
}

/**
 * The name a Mac proposes for itself when it asks for a link code (its
 * computer name), made to follow the same rule instead of being refused, so a
 * newly linked Mac never shows hidden or direction-changing characters in the
 * account: normalized to NFC, line breaks and tabs turned into spaces, the
 * other hidden characters removed, trimmed, and cut to 40 code points without
 * splitting a character (an emoji sequence or an accented letter). A name with
 * nothing visible left becomes "This Mac". The result always passes
 * hostLabelFromInput.
 */
export function proposedHostLabel(value: unknown): string {
  if (typeof value !== "string") return PROPOSED_HOST_LABEL_FALLBACK;
  const visible = value
    .normalize("NFC")
    .replace(HOST_LABEL_BREAKS, " ")
    .replace(HOST_LABEL_HIDDEN_CHARACTERS_ALL, "")
    .trim();
  const label = withinCodePoints(visible, HOST_LABEL_MAX_CHARACTERS).trim();
  return label || PROPOSED_HOST_LABEL_FALLBACK;
}

/** The longest start of `value` of whole characters (grapheme clusters) that fits in `max` code points. */
function withinCodePoints(value: string, max: number): string {
  if (Array.from(value).length <= max) return value;
  let kept = "";
  let count = 0;
  for (const character of graphemes(value)) {
    const size = Array.from(character).length;
    if (count + size > max) break;
    kept += character;
    count += size;
  }
  return kept;
}

function graphemes(value: string): string[] {
  // workerd has Intl.Segmenter; code points are the fallback without it.
  if (typeof Intl.Segmenter !== "function") return Array.from(value);
  return Array.from(new Intl.Segmenter(undefined, { granularity: "grapheme" }).segment(value), (part) => part.segment);
}
