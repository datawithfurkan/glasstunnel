import { describe, expect, it } from 'vitest';
import { checkHostLabel } from '../../../convex/hostLabel';
import {
  HOST_LABEL_ERRORS,
  PROPOSED_HOST_LABEL_FALLBACK,
  hostLabelFromInput,
  proposedHostLabel,
} from '../src/hostLabel';

// Characters are built from code points so the cases stay readable and no
// editor or tool can silently turn an escape into the invisible character.
const cp = (...codePoints: number[]) => String.fromCodePoint(...codePoints);
const DESKTOP = cp(0x1f5a5);
const TECHNOLOGIST = cp(0x1f9d1, 0x200d, 0x1f4bb); // a ZWJ emoji sequence
const E_ACUTE_DECOMPOSED = `e${cp(0x301)}`;
const E_ACUTE = cp(0xe9);

type Expected = { label: string } | { error: string };

const cases: Array<[string, unknown, Expected]> = [
  ['a plain name', 'Studio Mac mini', { label: 'Studio Mac mini' }],
  ['outer spaces', '  Studio Mac  ', { label: 'Studio Mac' }],
  ['a ZWJ emoji sequence', `Dev ${TECHNOLOGIST} Mac`, { label: `Dev ${TECHNOLOGIST} Mac` }],
  ['a Persian name with ZWNJ', `${cp(0x6a9, 0x62a, 0x627, 0x628)}${cp(0x200c)}${cp(0x62e, 0x627, 0x646, 0x647)}`, {
    label: `${cp(0x6a9, 0x62a, 0x627, 0x628)}${cp(0x200c)}${cp(0x62e, 0x627, 0x646, 0x647)}`,
  }],
  ['an emoji with a variation selector', `Mac ${cp(0x2764, 0xfe0f)}`, { label: `Mac ${cp(0x2764, 0xfe0f)}` }],
  ['a decomposed accent (stored as NFC)', `Caf${E_ACUTE_DECOMPOSED}`, { label: `Caf${E_ACUTE}` }],
  ['40 ASCII characters', 'x'.repeat(40), { label: 'x'.repeat(40) }],
  ['40 astral code points', DESKTOP.repeat(40), { label: DESKTOP.repeat(40) }],
  ['80 code points that are 40 after NFC', E_ACUTE_DECOMPOSED.repeat(40), { label: E_ACUTE.repeat(40) }],
  ['a byte order mark at the start (trimmed)', `${cp(0xfeff)}Studio`, { label: 'Studio' }],
  ['an empty name', '', { error: HOST_LABEL_ERRORS.empty }],
  ['only spaces', '   ', { error: HOST_LABEL_ERRORS.empty }],
  ['not text', 42, { error: HOST_LABEL_ERRORS.empty }],
  ['41 ASCII characters', 'x'.repeat(41), { error: HOST_LABEL_ERRORS.tooLong }],
  ['41 astral code points', DESKTOP.repeat(41), { error: HOST_LABEL_ERRORS.tooLong }],
  ['41 code points after NFC', E_ACUTE_DECOMPOSED.repeat(41), { error: HOST_LABEL_ERRORS.tooLong }],
  ['a line break', 'Studio\nMac', { error: HOST_LABEL_ERRORS.hiddenCharacters }],
  ['a tab', 'Studio\tMac', { error: HOST_LABEL_ERRORS.hiddenCharacters }],
  ['a NUL character', `Studio${cp(0)}Mac`, { error: HOST_LABEL_ERRORS.hiddenCharacters }],
  ['a C1 control', `Studio${cp(0x85)}Mac`, { error: HOST_LABEL_ERRORS.hiddenCharacters }],
  ['a line separator', `Studio${cp(0x2028)}Mac`, { error: HOST_LABEL_ERRORS.hiddenCharacters }],
  ['a paragraph separator', `Studio${cp(0x2029)}Mac`, { error: HOST_LABEL_ERRORS.hiddenCharacters }],
  ['a right-to-left override', `Studio${cp(0x202e)}Mac`, { error: HOST_LABEL_ERRORS.hiddenCharacters }],
  ['a left-to-right embedding', `Studio${cp(0x202a)}Mac`, { error: HOST_LABEL_ERRORS.hiddenCharacters }],
  ['a left-to-right isolate', `Studio${cp(0x2066)}Mac`, { error: HOST_LABEL_ERRORS.hiddenCharacters }],
  ['a pop directional isolate', `Studio${cp(0x2069)}Mac`, { error: HOST_LABEL_ERRORS.hiddenCharacters }],
  ['a left-to-right mark', `Studio Mac${cp(0x200e)}`, { error: HOST_LABEL_ERRORS.hiddenCharacters }],
  ['a right-to-left mark', `Studio${cp(0x200f)}Mac`, { error: HOST_LABEL_ERRORS.hiddenCharacters }],
  ['a zero width space', `Studio Mac mini${cp(0x200b)}`, { error: HOST_LABEL_ERRORS.hiddenCharacters }],
  ['a word joiner', `Studio${cp(0x2060)}Mac`, { error: HOST_LABEL_ERRORS.hiddenCharacters }],
  ['a byte order mark inside', `Studio${cp(0xfeff)}Mac`, { error: HOST_LABEL_ERRORS.hiddenCharacters }],
  // A hidden character is named before the length.
  ['too long and hidden', `${'x'.repeat(41)}${cp(0x200b)}`, { error: HOST_LABEL_ERRORS.hiddenCharacters }],
];

describe('Mac name rule', () => {
  it.each(cases)('the Worker handles %s', (_label, input, expected) => {
    const result = hostLabelFromInput(input);
    expect(result).toEqual({ ok: 'label' in expected, ...expected });
  });

  it.each(cases.filter(([, input]) => typeof input === 'string'))(
    'Convex gives the same answer for %s',
    (_label, input, expected) => {
      const result = checkHostLabel(input as string);
      if ('label' in expected) expect(result).toEqual({ ok: true, label: expected.label });
      else expect(result.ok).toBe(false);
    },
  );

  it('uses the messages the PWA shows', () => {
    expect(HOST_LABEL_ERRORS).toEqual({
      empty: 'Enter a name.',
      hiddenCharacters: 'Remove hidden characters from the name.',
      tooLong: 'Use 40 characters or fewer.',
    });
  });
});

// The name a Mac proposes for itself (its computer name) is made to follow the
// rule instead of being refused, so a newly linked Mac lists no hidden characters.
const proposals: Array<[string, unknown, string]> = [
  ['a plain computer name', 'Studio Mac mini', 'Studio Mac mini'],
  ['outer spaces', '  Studio Mac  ', 'Studio Mac'],
  ['a decomposed accent (NFC)', `Caf${E_ACUTE_DECOMPOSED} Mac`, `Caf${E_ACUTE} Mac`],
  ['a right-to-left override', `Studio${cp(0x202e)}Mac`, 'StudioMac'],
  ['isolates and marks', `${cp(0x2066)}Studio${cp(0x2069)} Mac${cp(0x200e)}`, 'Studio Mac'],
  ['invisible characters', `Studio${cp(0x200b)} ${cp(0x2060)}Mac${cp(0xfeff)}`, 'Studio Mac'],
  ['a line break', 'Studio\nMac', 'Studio Mac'],
  ['a tab and a line separator', `Studio\t${cp(0x2028)}Mac`, 'Studio Mac'],
  ['controls', `Studio${cp(0)}${cp(0x7f)}${cp(0x9b)} Mac`, 'Studio Mac'],
  ['a ZWJ emoji sequence (kept)', `Dev ${TECHNOLOGIST} Mac`, `Dev ${TECHNOLOGIST} Mac`],
  ['a Persian ZWNJ (kept)', `${cp(0x6a9, 0x62a, 0x627, 0x628)}${cp(0x200c)}${cp(0x62e, 0x627, 0x646, 0x647)}`,
    `${cp(0x6a9, 0x62a, 0x627, 0x628)}${cp(0x200c)}${cp(0x62e, 0x627, 0x646, 0x647)}`],
  ['41 ASCII characters', 'x'.repeat(41), 'x'.repeat(40)],
  ['41 astral code points', DESKTOP.repeat(41), DESKTOP.repeat(40)],
  ['a long name ending in a space', `${'x'.repeat(39)} yz`, 'x'.repeat(39)],
  // 38 code points, then a 3-code-point emoji sequence: cut before it, not inside it.
  ['an emoji sequence across the limit', `${'x'.repeat(38)}${TECHNOLOGIST}`, 'x'.repeat(38)],
  ['an accent across the limit', `${'x'.repeat(39)}q${cp(0x301)}`, 'x'.repeat(39)],
  ['nothing visible', `${cp(0x202e)}${cp(0x200b)}  `, PROPOSED_HOST_LABEL_FALLBACK],
  ['an empty name', '', PROPOSED_HOST_LABEL_FALLBACK],
  ['not text', 42, PROPOSED_HOST_LABEL_FALLBACK],
];

describe('the name a Mac proposes', () => {
  it.each(proposals)('the Worker cleans %s', (_label, input, expected) => {
    expect(proposedHostLabel(input)).toBe(expected);
  });

  it.each(proposals)('the cleaned name for %s passes the rule in the Worker and Convex', (_label, input) => {
    const label = proposedHostLabel(input);
    expect(hostLabelFromInput(label)).toEqual({ ok: true, label });
    expect(checkHostLabel(label)).toEqual({ ok: true, label });
  });
});
