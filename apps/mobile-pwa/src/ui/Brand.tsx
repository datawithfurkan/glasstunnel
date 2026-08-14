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
      className={`inline-flex items-center justify-center rounded-[16px] border border-accent/25 bg-accent/12 text-accent ${className}`}
      {...ariaProps(alt)}
    >
      {/* Geometry matches the Mac app's BrandMarkView (GlasstunnelBrand.swift)
          and the marketing site's brand/glasstunnel-mark.svg, scaled to 40u,
          so all three surfaces render the identical mark. */}
      <svg viewBox="0 0 40 40" className="h-[68%] w-[68%]" fill="none" aria-hidden="true">
        <path
          d="M12 26.4V15.2C12 7.2 28.8 7.2 28.8 15.2V26.4"
          stroke="currentColor"
          strokeWidth="2.2"
          strokeLinecap="round"
          strokeLinejoin="round"
        />
        <path
          d="M4.8 19.2H19.2M3.2 23.2H19.2M6.4 27.2H19.2"
          stroke="currentColor"
          strokeWidth="2.2"
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
