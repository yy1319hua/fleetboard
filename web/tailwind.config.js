/** @type {import('tailwindcss').Config} */
export default {
  darkMode: "class",
  content: ["./index.html", "./src/**/*.{ts,tsx}"],
  theme: {
    extend: {
      colors: {
        bg: "var(--bg)",
        "surface-1": "var(--surface-1)",
        "surface-2": "var(--surface-2)",
        "surface-3": "var(--surface-3)",
        border: "var(--border)",
        "border-strong": "var(--border-strong)",
        text: "var(--text)",
        "text-muted": "var(--text-muted)",
        "text-faint": "var(--text-faint)",
        "text-inverse": "var(--text-inverse)",
        accent: "var(--accent)",
        "accent-hover": "var(--accent-hover)",
        "accent-soft": "var(--accent-soft)",
        ok: "var(--ok)",
        warn: "var(--warn)",
        danger: "var(--danger)",
        info: "var(--info)",
        idle: "var(--idle)",
      },
      fontFamily: {
        sans: ["Geist Variable", "-apple-system", "Segoe UI", "Noto Sans SC", "sans-serif"],
        mono: ["JetBrains Mono Variable", "Menlo", "Consolas", "monospace"],
      },
      fontSize: {
        // 对应 DESIGN.md 第 3 节的字号层级
        display: ["30px", { lineHeight: "1.2", fontWeight: "600" }],
        h1: ["22px", { lineHeight: "1.3", fontWeight: "600" }],
        h2: ["18px", { lineHeight: "1.35", fontWeight: "600" }],
        h3: ["15px", { lineHeight: "1.4", fontWeight: "600" }],
        body: ["14px", { lineHeight: "1.5" }],
        "body-sm": ["13px", { lineHeight: "1.5" }],
        caption: ["12px", { lineHeight: "1.4", fontWeight: "500" }],
        eyebrow: ["11px", { lineHeight: "1.4", fontWeight: "600", letterSpacing: "0.06em" }],
        mono: ["13px", { lineHeight: "1.6" }],
        "mono-sm": ["12px", { lineHeight: "1.6" }],
      },
      borderRadius: {
        badge: "4px",
        control: "6px",
        card: "8px",
        panel: "12px",
        pill: "999px",
      },
      spacing: {
        // 4px 基准，显式给出大间距语义
        section: "32px",
      },
      boxShadow: {
        // 唯一允许的投影：模态/命令面板
        modal: "0 8px 24px rgba(0,0,0,.4)",
      },
      transitionTimingFunction: {
        // 只做 ease-out，禁止回弹
        ui: "cubic-bezier(0.2, 0, 0, 1)",
      },
      transitionDuration: {
        ui: "160ms",
      },
    },
  },
  plugins: [],
};
