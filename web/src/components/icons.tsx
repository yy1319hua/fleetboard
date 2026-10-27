/** 内联 SVG 图标（不引图标库，控制体积；统一 16px、currentColor）。 */
type IconProps = { className?: string };

const base = "h-4 w-4 shrink-0";

export function IconGrid({ className }: IconProps) {
  return (
    <svg viewBox="0 0 16 16" fill="none" stroke="currentColor" strokeWidth="1.4" className={`${base} ${className ?? ""}`} aria-hidden="true">
      <rect x="2" y="2" width="5" height="5" rx="1" />
      <rect x="9" y="2" width="5" height="5" rx="1" />
      <rect x="2" y="9" width="5" height="5" rx="1" />
      <rect x="9" y="9" width="5" height="5" rx="1" />
    </svg>
  );
}

export function IconBox({ className }: IconProps) {
  return (
    <svg viewBox="0 0 16 16" fill="none" stroke="currentColor" strokeWidth="1.4" className={`${base} ${className ?? ""}`} aria-hidden="true">
      <path d="M8 1.8 13.5 4.6v6.8L8 14.2 2.5 11.4V4.6L8 1.8Z" />
      <path d="M2.7 4.7 8 7.4l5.3-2.7M8 7.4v6.6" />
    </svg>
  );
}

export function IconFolder({ className }: IconProps) {
  return (
    <svg viewBox="0 0 16 16" fill="none" stroke="currentColor" strokeWidth="1.4" className={`${base} ${className ?? ""}`} aria-hidden="true">
      <path d="M2 4.2c0-.6.4-1 1-1h3l1.3 1.6H13c.6 0 1 .4 1 1v6.2c0 .6-.4 1-1 1H3c-.6 0-1-.4-1-1V4.2Z" />
    </svg>
  );
}

export function IconChart({ className }: IconProps) {
  return (
    <svg viewBox="0 0 16 16" fill="none" stroke="currentColor" strokeWidth="1.4" className={`${base} ${className ?? ""}`} aria-hidden="true">
      <path d="M2 13.2h12" />
      <path d="M3.5 10.5V7M7 10.5V3.8M10.5 10.5V6M13 10.5V5" />
    </svg>
  );
}

export function IconBell({ className }: IconProps) {
  return (
    <svg viewBox="0 0 16 16" fill="none" stroke="currentColor" strokeWidth="1.4" className={`${base} ${className ?? ""}`} aria-hidden="true">
      <path d="M4 6.6a4 4 0 0 1 8 0c0 3 1 4.2 1 4.2H3s1-1.2 1-4.2Z" />
      <path d="M6.6 13a1.5 1.5 0 0 0 2.8 0" />
    </svg>
  );
}

export function IconGear({ className }: IconProps) {
  return (
    <svg viewBox="0 0 16 16" fill="none" stroke="currentColor" strokeWidth="1.4" className={`${base} ${className ?? ""}`} aria-hidden="true">
      <circle cx="8" cy="8" r="2.2" />
      <path d="M8 1.8v1.6M8 12.6v1.6M1.8 8h1.6M12.6 8h1.6M3.6 3.6l1.1 1.1M11.3 11.3l1.1 1.1M12.4 3.6l-1.1 1.1M4.7 11.3l-1.1 1.1" />
    </svg>
  );
}

export function IconTerminal({ className }: IconProps) {
  return (
    <svg viewBox="0 0 16 16" fill="none" stroke="currentColor" strokeWidth="1.4" className={`${base} ${className ?? ""}`} aria-hidden="true">
      <rect x="2" y="2.8" width="12" height="10.4" rx="1.4" />
      <path d="m4.8 6.4 1.8 1.8-1.8 1.8M8.6 10.2h2.6" />
    </svg>
  );
}

export function IconLogout({ className }: IconProps) {
  return (
    <svg viewBox="0 0 16 16" fill="none" stroke="currentColor" strokeWidth="1.4" className={`${base} ${className ?? ""}`} aria-hidden="true">
      <path d="M6 2.8H3.4c-.5 0-.9.4-.9.9v8.6c0 .5.4.9.9.9H6" />
      <path d="M10.2 5 13 8l-2.8 3M13 8H6" />
    </svg>
  );
}

export function IconServer({ className }: IconProps) {
  return (
    <svg viewBox="0 0 16 16" fill="none" stroke="currentColor" strokeWidth="1.4" className={`${base} ${className ?? ""}`} aria-hidden="true">
      <rect x="2" y="2.6" width="12" height="4.4" rx="1.2" />
      <rect x="2" y="9" width="12" height="4.4" rx="1.2" />
      <path d="M4.4 4.8h.01M4.4 11.2h.01" strokeLinecap="round" strokeWidth="1.8" />
    </svg>
  );
}
