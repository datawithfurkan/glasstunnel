type BrandImageProps = {
  className?: string;
  alt?: string;
};

function ariaProps(alt?: string) {
  if (alt && alt.length > 0) {
    return { role: 'img', 'aria-label': alt };
  }
  return { 'aria-hidden': true as const };
}

export function BrandMark({ className = '', alt }: BrandImageProps) {
  return (
    <span
      className={`inline-flex items-center justify-center rounded-[16px] border border-accent/25 bg-accent/10 text-accent ${className}`}
      {...ariaProps(alt)}
    >
      <svg viewBox="0 0 40 40" className="h-[68%] w-[68%]" fill="none" aria-hidden="true">
        <path
          d="M12 25V15c0-4.4 3.6-8 8-8h2c4.4 0 8 3.6 8 8v10"
          stroke="currentColor"
          strokeWidth="2.4"
          strokeLinecap="round"
        />
        <path
          d="M11 25h20v6H11z"
          stroke="currentColor"
          strokeWidth="2.4"
          strokeLinejoin="round"
        />
        <path
          d="M6 20h13M4 25h15M8 30h11"
          stroke="currentColor"
          strokeWidth="2.4"
          strokeLinecap="round"
          opacity="0.72"
        />
      </svg>
    </span>
  );
}

export function BrandWordmark({ className = '', alt = 'Glasstunnel' }: BrandImageProps) {
  return (
    <span
      className={`inline-flex items-center font-semibold text-[color:var(--gt-text)] ${className}`}
      {...ariaProps(alt)}
    >
      Glasstunnel
    </span>
  );
}

export function BrandLockup({ className = '', alt = 'Glasstunnel' }: BrandImageProps) {
  return (
    <span className={`inline-flex items-center gap-3 ${className}`} {...ariaProps(alt)}>
      <BrandMark className="h-9 w-9 shrink-0 rounded-xl" />
      <span className="font-semibold text-[color:var(--gt-text)]">Glasstunnel</span>
    </span>
  );
}
