import {
  useEffect,
  useId,
  useRef,
  type KeyboardEvent as ReactKeyboardEvent,
  type MouseEvent as ReactMouseEvent,
  type ReactNode,
  type RefObject,
} from 'react';

const FOCUSABLE = [
  'a[href]',
  'button:not([disabled])',
  'input:not([disabled]):not([type="hidden"])',
  'select:not([disabled])',
  'textarea:not([disabled])',
  '[tabindex]:not([tabindex="-1"])',
].join(',');

export interface DialogProps {
  title: string;
  /** Escape, a tap outside, or the dialog's own Cancel/Done. */
  onClose: () => void;
  /** False while a request runs: Escape and taps outside do nothing then. */
  dismissible?: boolean;
  /** `alertdialog` for a confirmation of something that cannot be undone. */
  role?: 'dialog' | 'alertdialog';
  /** The control focused when the dialog opens; the dialog itself otherwise. */
  initialFocusRef?: RefObject<HTMLElement>;
  /**
   * Where focus goes when the dialog closes: the control that opened it, or
   * a fallback when that control is gone (a removed Mac's card).
   */
  returnFocus?: () => HTMLElement | null;
  /** Read with the title when the dialog opens. */
  description?: ReactNode;
  children?: ReactNode;
}

/**
 * A modal dialog: a bottom sheet on phones, a centred panel on wider screens.
 * Focus moves in on open, stays inside (Tab and Shift+Tab wrap), and returns
 * to the opener on close. Rendered in place, without a portal, so it also
 * renders on the server in tests.
 */
export function Dialog({
  title,
  onClose,
  dismissible = true,
  role = 'dialog',
  initialFocusRef,
  returnFocus,
  description,
  children,
}: DialogProps) {
  const panelRef = useRef<HTMLDivElement>(null);
  const titleId = useId();
  const descriptionId = useId();
  // Read on close, so the latest callbacks apply without re-running the effect.
  const returnFocusRef = useRef(returnFocus);
  returnFocusRef.current = returnFocus;
  const dismissibleRef = useRef(dismissible);
  dismissibleRef.current = dismissible;
  const onCloseRef = useRef(onClose);
  onCloseRef.current = onClose;

  useEffect(() => {
    const opener = document.activeElement instanceof HTMLElement ? document.activeElement : null;
    const panel = panelRef.current;
    (initialFocusRef?.current ?? panel)?.focus();

    // Focus that leaves the dialog (a screen reader's cursor, a click on the
    // page behind) comes back to it.
    const keepFocusInside = (event: FocusEvent) => {
      const current = panelRef.current;
      if (!current || !(event.target instanceof Node) || current.contains(event.target)) return;
      (focusableIn(current)[0] ?? current).focus();
    };
    // Escape closes wherever focus is, even after a tap left it on the page body.
    const closeOnEscape = (event: KeyboardEvent) => {
      if (event.key !== 'Escape') return;
      event.preventDefault();
      if (dismissibleRef.current) onCloseRef.current();
    };
    document.addEventListener('focusin', keepFocusInside);
    document.addEventListener('keydown', closeOnEscape);
    return () => {
      document.removeEventListener('focusin', keepFocusInside);
      document.removeEventListener('keydown', closeOnEscape);
      const target = returnFocusRef.current?.() ?? opener;
      if (target && target.isConnected) target.focus();
    };
    // Focus moves once per opening; initialFocusRef is a stable ref object.
  }, [initialFocusRef]);

  const onKeyDown = (event: ReactKeyboardEvent<HTMLDivElement>) => {
    if (event.key !== 'Tab') return;
    const panel = panelRef.current;
    if (!panel) return;
    // Every Tab moves within the dialog, wrapping at either end. Handling it
    // here (not leaving it to the browser) also keeps Safari, whose default
    // Tab skips buttons, from tabbing out of the page.
    event.preventDefault();
    const focusable = focusableIn(panel);
    if (!focusable.length) {
      panel.focus();
      return;
    }
    const index = focusable.indexOf(document.activeElement as HTMLElement);
    const step = event.shiftKey ? -1 : 1;
    const next = index < 0 ? (event.shiftKey ? focusable.length - 1 : 0) : (index + step + focusable.length) % focusable.length;
    focusable[next].focus();
  };

  const onBackdropClick = (event: ReactMouseEvent<HTMLDivElement>) => {
    if (event.target !== event.currentTarget) return;
    if (dismissibleRef.current) onClose();
  };

  return (
    <div
      className="fixed inset-0 z-50 flex items-end justify-center bg-black/60 sm:items-center sm:px-4"
      onClick={onBackdropClick}
      data-testid="dialog-backdrop"
    >
      <div
        ref={panelRef}
        role={role}
        aria-modal="true"
        aria-labelledby={titleId}
        aria-describedby={description ? descriptionId : undefined}
        tabIndex={-1}
        onKeyDown={onKeyDown}
        className="gt-dialog gt-panel max-h-[90dvh] w-full max-w-md overflow-y-auto px-5 pt-5 shadow-2xl focus:outline-none"
      >
        <h2 id={titleId} className="break-words text-xl font-semibold [overflow-wrap:anywhere]">
          {title}
        </h2>
        {description && (
          <p id={descriptionId} className="gt-muted mt-2 text-sm leading-relaxed">
            {description}
          </p>
        )}
        {children}
      </div>
    </div>
  );
}

function focusableIn(container: HTMLElement): HTMLElement[] {
  return Array.from(container.querySelectorAll<HTMLElement>(FOCUSABLE)).filter(
    (element) => !element.hasAttribute('inert') && element.getClientRects().length > 0,
  );
}
