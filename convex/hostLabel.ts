// The account name rule for a Mac. Pure (no Convex imports), so the Worker's
// tests can check that its own copy of the rule (apps/cloudflare-signal/src/hostLabel.ts)
// gives the same answer for every input.

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

export type HostLabelCheck =
  | { ok: true; label: string }
  | { ok: false; problem: "empty" | "hidden_characters" | "too_long" };

/**
 * Normalizes a proposed name to NFC and trims it, then refuses it if it is
 * empty, has a hidden character, or is longer than 40 code points, in that
 * order. On success `label` is the value to store.
 */
export function checkHostLabel(raw: string): HostLabelCheck {
  const label = raw.normalize("NFC").trim();
  if (!label) return { ok: false, problem: "empty" };
  if (HOST_LABEL_HIDDEN_CHARACTERS.test(label)) return { ok: false, problem: "hidden_characters" };
  if (Array.from(label).length > HOST_LABEL_MAX_CHARACTERS) return { ok: false, problem: "too_long" };
  return { ok: true, label };
}
