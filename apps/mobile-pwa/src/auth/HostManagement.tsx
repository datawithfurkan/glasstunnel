import { useEffect, useId, useRef, useState, type FormEvent, type KeyboardEvent as ReactKeyboardEvent } from 'react';
import type { AccountHost } from '../lib/accountApi';
import {
  HOST_LABEL_MAX_LENGTH,
  deviceFingerprint,
  sanitizeHostLabelInput,
  validateHostLabel,
} from '../lib/hostManagement';
import { Dialog } from '../ui/Dialog';

export type HostMenuAction = 'rename' | 'details' | 'remove';

export const HOST_MENU_ITEMS: ReadonlyArray<{ action: HostMenuAction; label: string }> = [
  { action: 'rename', label: 'Rename' },
  { action: 'details', label: 'Details' },
  { action: 'remove', label: 'Remove from account' },
];

export const HOST_DIALOG_COPY = {
  renameTitle: 'Rename Mac',
  renameField: 'Mac name',
  renameHint: `Shown in Your Macs and in the Mac app. Up to ${HOST_LABEL_MAX_LENGTH} characters.`,
  save: 'Save',
  saving: 'Saving…',
  cancel: 'Cancel',
  done: 'Done',
  copy: 'Copy',
  copied: 'Copied',
  copyLabel: 'Copy device ID',
  copiedAnnouncement: 'Device ID copied.',
  copyFallback: 'Copying is not available here. Select the full ID to copy it.',
  fullDeviceId: 'Full device ID',
  deviceId: 'Device ID',
  removeBody:
    'Phones and browsers signed in to this account lose access to this Mac right away. The Mac is signed out of your account. To use it again, link it from the Mac.',
  removeConfirm: 'Remove Mac',
  removing: 'Removing…',
} as const;

export function hostMenuButtonLabel(label: string): string {
  return `More actions for ${label}`;
}

export function removeMacTitle(label: string): string {
  return `Remove ${label}?`;
}

/** The ⋯ button of a Mac's card, found again to return focus to it. */
export function hostMenuButtonSelector(deviceId: string): string {
  const escaped = typeof CSS !== 'undefined' && CSS.escape ? CSS.escape(deviceId) : deviceId.replace(/["\\]/g, '\\$&');
  return `[data-host-menu-button="${escaped}"]`;
}

export function formatHostTimestamp(unixMs: number, style: 'date' | 'date-time' = 'date-time'): string {
  try {
    return new Intl.DateTimeFormat(
      undefined,
      style === 'date' ? { dateStyle: 'medium' } : { dateStyle: 'medium', timeStyle: 'short' },
    ).format(new Date(unixMs));
  } catch {
    const date = new Date(unixMs);
    return style === 'date' ? date.toLocaleDateString() : date.toLocaleString();
  }
}

export interface HostDetailRow {
  label: string;
  value: string;
}

/** The read-only facts the details sheet lists for a Mac, in order. The app version shows only when known. */
export function hostDetailsRows(
  host: AccountHost,
  format: (unixMs: number, style: 'date' | 'date-time') => string = formatHostTimestamp,
): HostDetailRow[] {
  const addedAt = host.addedAtUnixMs || host.pairedAtUnixMs;
  const rows: HostDetailRow[] = [
    { label: 'Status', value: host.online ? 'Online' : 'Offline' },
    {
      label: 'Last seen',
      value: host.lastSeenAtUnixMs
        ? format(host.lastSeenAtUnixMs, 'date-time')
        : host.online
          ? 'Now'
          : 'Not available',
    },
    { label: 'Added', value: addedAt ? format(addedAt, 'date') : 'Not available' },
  ];
  const appVersion = host.appVersion?.trim();
  if (appVersion) rows.push({ label: 'Mac app version', value: appVersion });
  return rows;
}

/**
 * The "⋯" button on a Mac's card and its menu: Rename, Details, Remove from
 * account. Arrow keys, Home and End move between items; Escape closes and
 * returns focus to the button; a tap outside or Tab closes it.
 */
export function HostActionsMenu({
  host,
  open,
  onOpenChange,
  onSelect,
}: {
  host: AccountHost;
  open: boolean;
  onOpenChange: (open: boolean) => void;
  onSelect: (action: HostMenuAction) => void;
}) {
  const triggerId = useId();
  const menuId = useId();
  const containerRef = useRef<HTMLDivElement>(null);
  const triggerRef = useRef<HTMLButtonElement>(null);
  const itemRefs = useRef<Array<HTMLButtonElement | null>>([]);
  const focusOnOpen = useRef<'first' | 'last'>('first');
  const onOpenChangeRef = useRef(onOpenChange);
  onOpenChangeRef.current = onOpenChange;

  const menuItems = () => itemRefs.current.filter((item): item is HTMLButtonElement => item !== null);

  // Focus moves into the menu once, when it opens.
  useEffect(() => {
    if (!open) return;
    const items = menuItems();
    (focusOnOpen.current === 'last' ? items[items.length - 1] : items[0])?.focus();
    focusOnOpen.current = 'first';
  }, [open]);

  useEffect(() => {
    if (!open) return;
    const closeOnOutsidePress = (event: Event) => {
      const container = containerRef.current;
      if (container && event.target instanceof Node && container.contains(event.target)) return;
      onOpenChangeRef.current(false);
    };
    const closeOnEscape = (event: KeyboardEvent) => {
      if (event.key !== 'Escape') return;
      event.preventDefault();
      onOpenChangeRef.current(false);
      triggerRef.current?.focus();
    };
    document.addEventListener('pointerdown', closeOnOutsidePress);
    document.addEventListener('keydown', closeOnEscape);
    return () => {
      document.removeEventListener('pointerdown', closeOnOutsidePress);
      document.removeEventListener('keydown', closeOnEscape);
    };
  }, [open]);

  const onTriggerKeyDown = (event: ReactKeyboardEvent<HTMLButtonElement>) => {
    if (event.key !== 'ArrowDown' && event.key !== 'ArrowUp') return;
    event.preventDefault();
    focusOnOpen.current = event.key === 'ArrowUp' ? 'last' : 'first';
    if (open) {
      const items = menuItems();
      (event.key === 'ArrowUp' ? items[items.length - 1] : items[0])?.focus();
      return;
    }
    onOpenChange(true);
  };

  const onMenuKeyDown = (event: ReactKeyboardEvent<HTMLDivElement>) => {
    const items = menuItems();
    if (!items.length) return;
    const index = items.indexOf(document.activeElement as HTMLButtonElement);
    const focusAt = (next: number) => items[(next + items.length) % items.length]?.focus();
    switch (event.key) {
      case 'ArrowDown':
        event.preventDefault();
        focusAt(index + 1);
        break;
      case 'ArrowUp':
        event.preventDefault();
        focusAt(index < 0 ? items.length - 1 : index - 1);
        break;
      case 'Home':
        event.preventDefault();
        focusAt(0);
        break;
      case 'End':
        event.preventDefault();
        focusAt(items.length - 1);
        break;
      case 'Tab':
        // Focus moves on as usual; the menu does not stay open behind it.
        onOpenChange(false);
        break;
      default:
        break;
    }
  };

  return (
    <div ref={containerRef} className="relative shrink-0">
      <button
        ref={triggerRef}
        id={triggerId}
        type="button"
        aria-label={hostMenuButtonLabel(host.label)}
        aria-haspopup="menu"
        aria-expanded={open}
        aria-controls={open ? menuId : undefined}
        title="More actions"
        data-host-menu-button={host.deviceId}
        onClick={() => onOpenChange(!open)}
        onKeyDown={onTriggerKeyDown}
        className="gt-button gt-button-ghost h-11 w-11 px-0"
      >
        <svg aria-hidden="true" viewBox="0 0 24 24" className="h-5 w-5" fill="currentColor">
          <circle cx="5" cy="12" r="2" />
          <circle cx="12" cy="12" r="2" />
          <circle cx="19" cy="12" r="2" />
        </svg>
      </button>
      {open && (
        <div
          id={menuId}
          role="menu"
          aria-labelledby={triggerId}
          onKeyDown={onMenuKeyDown}
          className="absolute right-0 top-full z-30 mt-2 w-56 max-w-[calc(100vw-2rem)] rounded-[12px] border border-[color:var(--gt-border)] bg-surface-1 p-1.5 shadow-2xl"
        >
          {HOST_MENU_ITEMS.map((item, index) => (
            <button
              key={item.action}
              ref={(element) => {
                itemRefs.current[index] = element;
              }}
              type="button"
              role="menuitem"
              tabIndex={-1}
              onClick={() => {
                onOpenChange(false);
                onSelect(item.action);
              }}
              className={`gt-menu-item ${item.action === 'remove' ? 'text-err' : ''}`}
            >
              {item.label}
            </button>
          ))}
        </div>
      )}
    </div>
  );
}

/** Renames a Mac. Save checks the name first; the server checks it again. */
export function RenameMacDialog({
  host,
  rename,
  onRenamed,
  onClose,
  returnFocus,
  initialError = null,
}: {
  host: AccountHost;
  rename: (deviceId: string, label: string) => Promise<string>;
  onRenamed: (label: string) => void;
  onClose: () => void;
  returnFocus?: () => HTMLElement | null;
  /** For fixtures and tests: the dialog as it shows a failed save. */
  initialError?: string | null;
}) {
  // A name stored before the name rule (or proposed by a Mac) may hold hidden
  // characters; the field starts without them, so Save is not refused for
  // something no one can see.
  const [draft, setDraft] = useState(() => sanitizeHostLabelInput(host.label));
  const [error, setError] = useState<string | null>(initialError);
  const [saving, setSaving] = useState(false);
  const inputRef = useRef<HTMLInputElement>(null);
  const inputId = useId();
  const messageId = useId();

  useEffect(() => {
    inputRef.current?.select();
  }, []);

  const submit = async (event: FormEvent<HTMLFormElement>) => {
    event.preventDefault();
    if (saving) return;
    const validation = validateHostLabel(draft);
    if (!validation.ok) {
      setError(validation.error);
      inputRef.current?.focus();
      return;
    }
    if (validation.label === host.label) {
      // Nothing changed: no request, no status.
      onClose();
      return;
    }
    setSaving(true);
    setError(null);
    try {
      const label = await rename(host.deviceId, validation.label);
      onRenamed(label);
    } catch (err) {
      setError((err as Error).message);
      setSaving(false);
      inputRef.current?.focus();
    }
  };

  return (
    <Dialog
      title={HOST_DIALOG_COPY.renameTitle}
      onClose={onClose}
      dismissible={!saving}
      initialFocusRef={inputRef}
      returnFocus={returnFocus}
    >
      <form onSubmit={(event) => void submit(event)} noValidate className="mt-4">
        <label htmlFor={inputId} className="text-sm font-medium">
          {HOST_DIALOG_COPY.renameField}
        </label>
        <input
          ref={inputRef}
          id={inputId}
          value={draft}
          onChange={(event) => {
            setDraft(sanitizeHostLabelInput(event.target.value));
            if (error) setError(null);
          }}
          readOnly={saving}
          aria-invalid={error ? true : undefined}
          aria-describedby={messageId}
          autoComplete="off"
          autoCapitalize="words"
          spellCheck={false}
          enterKeyHint="done"
          className="gt-input mt-2"
        />
        {error ? (
          <p id={messageId} role="alert" className="mt-2 text-sm text-err">
            {error}
          </p>
        ) : (
          <p id={messageId} className="gt-dim mt-2 text-sm">
            {HOST_DIALOG_COPY.renameHint}
          </p>
        )}
        <div className="mt-5 flex flex-col-reverse gap-2 sm:flex-row sm:justify-end">
          <button type="button" onClick={onClose} disabled={saving} className="gt-button gt-button-secondary">
            {HOST_DIALOG_COPY.cancel}
          </button>
          <button type="submit" disabled={saving} aria-busy={saving} className="gt-button gt-button-primary">
            {saving ? HOST_DIALOG_COPY.saving : HOST_DIALOG_COPY.save}
          </button>
        </div>
      </form>
    </Dialog>
  );
}

/** What the account knows about a Mac, read-only, with a way to copy its full device ID. */
export function MacDetailsDialog({
  host,
  onClose,
  returnFocus,
}: {
  host: AccountHost;
  onClose: () => void;
  returnFocus?: () => HTMLElement | null;
}) {
  const [copyState, setCopyState] = useState<'idle' | 'copied' | 'failed'>('idle');
  const fullIdRef = useRef<HTMLInputElement>(null);
  const deviceIdLabelId = useId();

  useEffect(() => {
    if (copyState === 'failed') {
      fullIdRef.current?.focus();
      fullIdRef.current?.select();
      return;
    }
    if (copyState !== 'copied') return;
    const timer = window.setTimeout(() => setCopyState('idle'), 2_500);
    return () => window.clearTimeout(timer);
  }, [copyState]);

  const copyDeviceId = async () => {
    try {
      if (!navigator.clipboard?.writeText) throw new Error('Clipboard unavailable');
      await navigator.clipboard.writeText(host.deviceId);
      setCopyState('copied');
    } catch {
      setCopyState('failed');
    }
  };

  return (
    <Dialog title={host.label} onClose={onClose} returnFocus={returnFocus}>
      <dl className="mt-4 divide-y divide-[color:var(--gt-border)] border-y border-[color:var(--gt-border)]">
        {hostDetailsRows(host).map((row) => (
          <div key={row.label} className="flex items-baseline justify-between gap-4 py-3">
            <dt className="gt-muted shrink-0 text-sm">{row.label}</dt>
            <dd className="min-w-0 text-right text-sm font-medium [overflow-wrap:anywhere]">{row.value}</dd>
          </div>
        ))}
        <div className="flex items-center justify-between gap-4 py-2">
          <dt id={deviceIdLabelId} className="gt-muted shrink-0 text-sm">
            {HOST_DIALOG_COPY.deviceId}
          </dt>
          <dd className="flex min-w-0 items-center justify-end gap-2">
            <code className="truncate font-mono text-sm" title={host.deviceId}>
              {deviceFingerprint(host.deviceId)}
            </code>
            <button
              type="button"
              onClick={() => void copyDeviceId()}
              aria-label={HOST_DIALOG_COPY.copyLabel}
              className="gt-button gt-button-secondary shrink-0 px-3"
            >
              {copyState === 'copied' ? HOST_DIALOG_COPY.copied : HOST_DIALOG_COPY.copy}
            </button>
          </dd>
        </div>
      </dl>
      {copyState === 'failed' && (
        <div className="mt-3">
          <input
            ref={fullIdRef}
            readOnly
            value={host.deviceId}
            aria-label={HOST_DIALOG_COPY.fullDeviceId}
            onFocus={(event) => event.currentTarget.select()}
            className="gt-input font-mono text-sm"
          />
          <p className="gt-dim mt-2 text-sm">{HOST_DIALOG_COPY.copyFallback}</p>
        </div>
      )}
      <p role="status" aria-live="polite" className="sr-only">
        {copyState === 'copied' ? HOST_DIALOG_COPY.copiedAnnouncement : ''}
      </p>
      <div className="mt-5 flex sm:justify-end">
        <button type="button" onClick={onClose} className="gt-button gt-button-primary w-full sm:w-auto">
          {HOST_DIALOG_COPY.done}
        </button>
      </div>
    </Dialog>
  );
}

/** Confirms removing a Mac from the account; nothing changes until the server agrees. */
export function RemoveMacDialog({
  host,
  remove,
  onRemoved,
  onClose,
  returnFocus,
  initialError = null,
}: {
  host: AccountHost;
  remove: (deviceId: string) => Promise<void>;
  onRemoved: () => void;
  onClose: () => void;
  returnFocus?: () => HTMLElement | null;
  /** For fixtures and tests: the dialog as it shows a failed removal. */
  initialError?: string | null;
}) {
  const [removing, setRemoving] = useState(false);
  const [error, setError] = useState<string | null>(initialError);
  const cancelRef = useRef<HTMLButtonElement>(null);
  const confirmRef = useRef<HTMLButtonElement>(null);

  const confirm = async () => {
    if (removing) return;
    setRemoving(true);
    setError(null);
    try {
      await remove(host.deviceId);
      onRemoved();
    } catch (err) {
      setError((err as Error).message);
      setRemoving(false);
      // The button was disabled while the request ran; focus comes back to it.
      window.setTimeout(() => confirmRef.current?.focus(), 0);
    }
  };

  return (
    <Dialog
      role="alertdialog"
      title={removeMacTitle(host.label)}
      description={HOST_DIALOG_COPY.removeBody}
      onClose={onClose}
      dismissible={!removing}
      initialFocusRef={cancelRef}
      returnFocus={returnFocus}
    >
      {error && (
        <p role="alert" className="mt-3 text-sm text-err">
          {error}
        </p>
      )}
      <div className="mt-5 flex flex-col-reverse gap-2 sm:flex-row sm:justify-end">
        <button
          ref={cancelRef}
          type="button"
          onClick={onClose}
          disabled={removing}
          className="gt-button gt-button-secondary"
        >
          {HOST_DIALOG_COPY.cancel}
        </button>
        <button
          ref={confirmRef}
          type="button"
          onClick={() => void confirm()}
          disabled={removing}
          aria-busy={removing}
          className="gt-button gt-button-destructive"
        >
          {removing ? HOST_DIALOG_COPY.removing : HOST_DIALOG_COPY.removeConfirm}
        </button>
      </div>
    </Dialog>
  );
}
