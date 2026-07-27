interface TimestampFormatOptions {
  locale?: string;
  now?: Date;
  timeZone?: string;
}

export interface MessageTimestamp {
  label: string;
  full: string;
  iso: string;
}

export function formatMessageTimestamp(
  atUnixMs: number,
  options: TimestampFormatOptions = {},
): MessageTimestamp | null {
  if (!Number.isFinite(atUnixMs) || atUnixMs <= 0) return null;

  const createdAt = new Date(atUnixMs);
  if (Number.isNaN(createdAt.getTime())) return null;

  const now = options.now ?? new Date();
  const locale = options.locale;
  const timeZone = options.timeZone;
  const createdParts = dateParts(createdAt, locale, timeZone);
  const nowParts = dateParts(now, locale, timeZone);

  const sameDay =
    createdParts.year === nowParts.year &&
    createdParts.month === nowParts.month &&
    createdParts.day === nowParts.day;
  const sameYear = createdParts.year === nowParts.year;

  const timeFormatter = new Intl.DateTimeFormat(locale, {
    hour: '2-digit',
    hour12: false,
    minute: '2-digit',
    timeZone,
  });
  const labelFormatter = sameDay
    ? timeFormatter
    : new Intl.DateTimeFormat(locale, {
        month: 'short',
        day: 'numeric',
        ...(sameYear ? {} : { year: 'numeric' }),
        hour: '2-digit',
        hour12: false,
        minute: '2-digit',
        timeZone,
      });
  const fullFormatter = new Intl.DateTimeFormat(locale, {
    dateStyle: 'medium',
    hour12: false,
    timeStyle: 'short',
    timeZone,
  });

  return {
    label: labelFormatter.format(createdAt),
    full: fullFormatter.format(createdAt),
    iso: createdAt.toISOString(),
  };
}

function dateParts(date: Date, locale?: string, timeZone?: string) {
  const parts = new Intl.DateTimeFormat(locale, {
    day: '2-digit',
    month: '2-digit',
    year: 'numeric',
    timeZone,
  }).formatToParts(date);

  return {
    day: parts.find((part) => part.type === 'day')?.value,
    month: parts.find((part) => part.type === 'month')?.value,
    year: parts.find((part) => part.type === 'year')?.value,
  };
}
