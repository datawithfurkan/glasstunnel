import { describe, expect, it } from 'vitest';
import { AccountApiError } from './accountApi';
import {
  HOST_MANAGEMENT_COPY,
  deviceFingerprint,
  duplicateHostLabels,
  hostActionErrorCopy,
  hostLabelKey,
  isHostNotInAccount,
  isNetworkFailure,
  removedStatus,
  renamedStatus,
  sanitizeHostLabelInput,
  validateHostLabel,
} from './hostManagement';

describe('Mac names', () => {
  it('trims a name and accepts 1 to 40 characters', () => {
    expect(validateHostLabel('  Studio Mac mini  ')).toEqual({ ok: true, label: 'Studio Mac mini' });
    expect(validateHostLabel('M')).toEqual({ ok: true, label: 'M' });
    expect(validateHostLabel('x'.repeat(40))).toEqual({ ok: true, label: 'x'.repeat(40) });
    // Spaces around a 40-character name do not count.
    expect(validateHostLabel(`  ${'x'.repeat(40)}  `)).toEqual({ ok: true, label: 'x'.repeat(40) });
  });

  it('asks for a name when it is empty or only spaces', () => {
    expect(validateHostLabel('')).toEqual({ ok: false, error: 'Enter a name.' });
    expect(validateHostLabel('    ')).toEqual({ ok: false, error: 'Enter a name.' });
  });

  it('refuses names over 40 characters', () => {
    expect(validateHostLabel('x'.repeat(41))).toEqual({ ok: false, error: 'Use 40 characters or fewer.' });
  });

  it('refuses control characters, which the name field also strips as they are typed or pasted', () => {
    for (const name of ['Mac\nmini', 'Mac\tmini', 'Mac\u0000mini', 'Mac\u007fmini', 'Mac\u0085mini', 'Mac\u2028mini', 'Mac\u2029mini']) {
      expect(validateHostLabel(name)).toEqual({ ok: false, error: HOST_MANAGEMENT_COPY.labelHiddenCharacters });
    }
    expect(sanitizeHostLabelInput('Studio\r\nMac\tmini\u0007\u2028')).toBe('StudioMacmini');
    // Everything printable stays, emoji and accents included.
    expect(sanitizeHostLabelInput("Zoë's Mac ☕")).toBe("Zoë's Mac ☕");
    expect(validateHostLabel("Zoë's Mac ☕")).toEqual({ ok: true, label: "Zoë's Mac ☕" });
  });

  it('counts the length in code points, so an emoji is one character', () => {
    const desktop = '\u{1F5A5}';
    expect(desktop.length).toBe(2);
    expect(validateHostLabel(desktop.repeat(40))).toEqual({ ok: true, label: desktop.repeat(40) });
    expect(validateHostLabel(desktop.repeat(41))).toEqual({ ok: false, error: 'Use 40 characters or fewer.' });
  });

  it('accepts the joiners that emoji sequences and Persian names need', () => {
    // Woman technologist: U+1F469 U+200D U+1F4BB.
    const technologist = '\u{1F469}\u200D\u{1F4BB}';
    expect(validateHostLabel(`${technologist} Studio Mac mini`)).toEqual({
      ok: true,
      label: `${technologist} Studio Mac mini`,
    });
    // A Persian word with a zero-width non-joiner (U+200C).
    const persian = '\u0645\u06CC\u200C\u062E\u0648\u0627\u0647\u0645';
    expect(validateHostLabel(persian)).toEqual({ ok: true, label: persian });
    expect(sanitizeHostLabelInput(`${technologist} ${persian}`)).toBe(`${technologist} ${persian}`);
  });

  it('refuses bidirectional controls and invisible characters, which the name field also strips', () => {
    const hidden = [
      '\u200B', '\u200E', '\u200F', '\u202A', '\u202B', '\u202C', '\u202D', '\u202E',
      '\u2066', '\u2067', '\u2068', '\u2069', '\u2060', '\uFEFF',
    ];
    for (const character of hidden) {
      expect(validateHostLabel(`Studio${character}Mac mini`)).toEqual({
        ok: false,
        error: 'Remove hidden characters from the name.',
      });
      expect(sanitizeHostLabelInput(`Studio${character}Mac mini`)).toBe('StudioMac mini');
    }
    // A right-to-left override would show "Studio Mac mini" reversed around it.
    expect(validateHostLabel('Studio Mac mini\u202Einim')).toEqual({
      ok: false,
      error: 'Remove hidden characters from the name.',
    });
    // An invisible character is refused even when the name is also too long.
    expect(validateHostLabel(`${'x'.repeat(41)}\u200B`)).toEqual({
      ok: false,
      error: 'Remove hidden characters from the name.',
    });
  });

  it('stores the composed (NFC) form and counts its length after composing', () => {
    // "e" followed by a combining acute accent becomes one "é" (U+00E9).
    expect(validateHostLabel("Zoe\u0301's Mac")).toEqual({ ok: true, label: "Zo\u00E9's Mac" });
    // 39 letters and a decomposed "é" are 41 code points as typed, 40 once composed.
    expect(validateHostLabel(`${'x'.repeat(39)}e\u0301`)).toEqual({ ok: true, label: `${'x'.repeat(39)}\u00E9` });
    // A name that cannot compose further keeps its combining marks and their count.
    expect(validateHostLabel(`${'x'.repeat(39)}q\u0301`)).toEqual({ ok: false, error: 'Use 40 characters or fewer.' });
  });

  it('words the outcome of a rename or removal with the Mac name', () => {
    expect(renamedStatus('Desk Mac')).toBe('Renamed to Desk Mac.');
    expect(removedStatus('Desk Mac')).toBe('Removed Desk Mac from your account.');
  });
});

describe('telling Macs apart', () => {
  it('shortens a device ID to its first 12 characters', () => {
    expect(deviceFingerprint('gt-4a1b7e3ac0d2f915')).toBe('gt-4a1b7e3ac');
    expect(deviceFingerprint('gt-short')).toBe('gt-short');
  });

  it('finds names shared by more than one Mac, ignoring case and outer spaces', () => {
    const duplicates = duplicateHostLabels([
      { label: "Studio Mac mini" },
      { label: 'studio mac mini ' },
      { label: 'MacBook Pro' },
    ]);
    expect([...duplicates]).toEqual(['studio mac mini']);
    expect(duplicateHostLabels([{ label: 'A' }, { label: 'B' }]).size).toBe(0);
  });

  it('finds names that look the same on screen: composed alike, invisible characters left out', () => {
    // Stored before the name rule, or proposed by a Mac: the cards would look identical.
    const duplicates = duplicateHostLabels([
      { label: 'Zo\u00E9 Mac' },
      { label: 'zoe\u0301 mac' },
      { label: 'Zo\u00E9 Mac\u200B' },
      { label: '\u202AZO\u00C9 MAC\u202C' },
      { label: 'Zoe Mac' },
    ]);
    expect([...duplicates]).toEqual(['zo\u00E9 mac']);
    expect(hostLabelKey(' Studio\u2060 Mac mini\uFEFF ')).toBe('studio mac mini');
    // Joiners are part of what is shown, so they stay in the key.
    expect(hostLabelKey('\u{1F469}\u200D\u{1F4BB} Mac')).toBe('\u{1F469}\u200D\u{1F4BB} mac');
    expect(duplicateHostLabels([{ label: '\u{1F469}\u200D\u{1F4BB}' }, { label: '\u{1F469}\u{1F4BB}' }]).size).toBe(0);
  });
});

describe('rename and removal failures', () => {
  it('says a Mac outside the account is no longer there, whatever the reason', () => {
    const error = new AccountApiError('Mac not found', 404);
    expect(isHostNotInAccount(error)).toBe(true);
    expect(hostActionErrorCopy('rename', error)).toBe('This Mac is no longer in your account.');
    expect(hostActionErrorCopy('remove', error)).toBe('This Mac is no longer in your account.');
  });

  it('treats any other 404 as a plain failure, as from an older Worker without the route', () => {
    for (const error of [
      new AccountApiError('not found', 404),
      new AccountApiError('Request failed with 404', 404),
      new AccountApiError('mac not found', 404),
      // A plain-text 404 page is not JSON: the request helper throws a plain Error.
      new Error('Request failed with 404: Not found'),
    ]) {
      expect(isHostNotInAccount(error)).toBe(false);
      expect(hostActionErrorCopy('rename', error)).toBe("Couldn't rename this Mac. Try again.");
      expect(hostActionErrorCopy('remove', error)).toBe("Couldn't remove this Mac. Try again.");
    }
    // The exact message only counts with a 404.
    expect(isHostNotInAccount(new AccountApiError('Mac not found', 400))).toBe(false);
    expect(isHostNotInAccount(new Error('Mac not found'))).toBe(false);
  });

  it('shows the server name rules it knows, and a general line for anything else', () => {
    expect(hostActionErrorCopy('rename', new AccountApiError('Enter a name.', 400))).toBe('Enter a name.');
    expect(hostActionErrorCopy('rename', new AccountApiError('Use 40 characters or fewer.', 400))).toBe(
      'Use 40 characters or fewer.',
    );
    expect(hostActionErrorCopy('rename', new AccountApiError('label: invalid_label', 400))).toBe(
      HOST_MANAGEMENT_COPY.invalidLabelFallback,
    );
    expect(hostActionErrorCopy('remove', new AccountApiError('bad request', 400))).toBe(
      HOST_MANAGEMENT_COPY.removeFailed,
    );
  });

  it('asks to try again later when the account service is unavailable or busy', () => {
    expect(hostActionErrorCopy('remove', new AccountApiError('account plane unavailable', 503))).toBe(
      HOST_MANAGEMENT_COPY.unavailable,
    );
    expect(hostActionErrorCopy('rename', new AccountApiError('Request failed with 500', 500))).toBe(
      HOST_MANAGEMENT_COPY.unavailable,
    );
    expect(hostActionErrorCopy('rename', new AccountApiError('slow down', 429))).toBe(HOST_MANAGEMENT_COPY.busy);
  });

  it('sends an expired session back to sign-in', () => {
    expect(hostActionErrorCopy('rename', new AccountApiError('browser session expired', 401))).toBe(
      HOST_MANAGEMENT_COPY.sessionExpired,
    );
    expect(hostActionErrorCopy('remove', new Error('Sign in again to continue.'))).toBe(
      HOST_MANAGEMENT_COPY.sessionExpired,
    );
  });

  it('tells a missing connection or timeout apart from a refusal', () => {
    const timeout = Object.assign(new Error('The operation was aborted.'), { name: 'AbortError' });
    expect(isNetworkFailure(new TypeError('Failed to fetch'))).toBe(true);
    expect(isNetworkFailure(timeout)).toBe(true);
    expect(isNetworkFailure({ name: 'AbortError' })).toBe(true);
    expect(isNetworkFailure(new AccountApiError('Mac not found', 404))).toBe(false);
    expect(hostActionErrorCopy('remove', new TypeError('Load failed'))).toBe(HOST_MANAGEMENT_COPY.offline);
    expect(hostActionErrorCopy('rename', timeout)).toBe(HOST_MANAGEMENT_COPY.offline);
    expect(hostActionErrorCopy('rename', new Error('something odd'))).toBe(HOST_MANAGEMENT_COPY.renameFailed);
  });
});
