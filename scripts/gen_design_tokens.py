#!/usr/bin/env python3
"""fleetboard 设计令牌生成器 / 校验器。

唯一真源： design/tokens.json
生成物（三处，全部带 GENERATED 标记，禁止手工改）：
  - web/src/index.css                 的 GENERATED TOKENS 区间（CSS 变量）
  - web/tailwind.config.js           的 GENERATED TOKENS 区间（theme.extend）
  - app/lib/core/theme/design_tokens.dart（Dart 常量，constants.dart / app_theme.dart 均 re-export）

用法：
  python3 scripts/gen_design_tokens.py --write   # 重新生成
  python3 scripts/gen_design_tokens.py --check   # CI：校验生成物未漂移 + WCAG 对比度

CI 里跑 --check。任何一项不满足都以非 0 退出。
"""

from __future__ import annotations

import argparse
import json
import re
import sys
from pathlib import Path

ROOT = Path(__file__).resolve().parent.parent
TOKENS = ROOT / "design" / "tokens.json"
INDEX_CSS = ROOT / "web" / "src" / "index.css"
TAILWIND = ROOT / "web" / "tailwind.config.js"
DART_TOKENS = ROOT / "app" / "lib" / "core" / "theme" / "design_tokens.dart"

BEGIN = "/* === BEGIN GENERATED TOKENS (design/tokens.json) === */"
END = "/* === END GENERATED TOKENS === */"

# tokens.json 键 -> (CSS 变量名, Dart 字段名)
COLOR_MAP = {
    "bg": ("--bg", "bg"),
    "surface-1": ("--surface-1", "s1"),
    "surface-2": ("--surface-2", "s2"),
    "surface-3": ("--surface-3", "s3"),
    "border": ("--border", "border"),
    "border-strong": ("--border-strong", "borderStrong"),
    "terminal": ("--terminal", "terminal"),
    "text": ("--text", "text"),
    "text-muted": ("--text-muted", "muted"),
    "text-faint": ("--text-faint", "faint"),
    "text-inverse": ("--text-inverse", "textInverse"),
    "accent": ("--accent", "accent"),
    "accent-hover": ("--accent-hover", "accentHover"),
    "accent-soft": ("--accent-soft", "accentSoft"),
    "ok": ("--ok", "ok"),
    "warn": ("--warn", "warn"),
    "danger": ("--danger", "danger"),
    "info": ("--info", "info"),
    "idle": ("--idle", "idle"),
}

# 圆角：tokens.json 键 -> tailwind 键
RADIUS_TW = {
    "badge": "badge",
    "sm": "control",
    "md": "card",
    "lg": "panel",
    "pill": "pill",
}


def load() -> dict:
    return json.loads(TOKENS.read_text(encoding="utf-8"))


def hex_rgb(value: str) -> tuple[int, int, int]:
    h = value.lstrip("#")
    return tuple(int(h[i : i + 2], 16) for i in (0, 2, 4))  # type: ignore[return-value]


def css_color(value) -> str:
    if isinstance(value, list):
        r, g, b, a = value
        return f"rgba({r}, {g}, {b}, {a})"
    return value.lower()


def dart_color(value) -> str:
    if isinstance(value, list):
        r, g, b, a = value
        alpha = round(a * 255)
        return f"Color(0x{alpha:02X}{r:02X}{g:02X}{b:02X})"
    return f"Color(0xFF{value.lstrip('#').upper()})"


def q(s: str) -> str:
    """JS 对象键（含空格/连字符的加引号）。"""
    return f'"{s}"' if (" " in s or "-" in s or "." in s) else s


def css_font(s: str) -> str:
    """CSS 字体族名：只有含空格的才加引号（-apple-system 是关键字，不能加引号）。"""
    return f'"{s}"' if " " in s else s


# ---------------------------------------------------------------- CSS --------

def render_css(t: dict) -> str:
    L = [BEGIN, ":root {"]
    for key, (css_var, _) in COLOR_MAP.items():
        L.append(f"  {css_var}: {css_color(t['colors'][key])};")
    L.append("")
    f = t["fonts"]
    ui_stack = ", ".join([f'"{f["ui"]}"'] + [css_font(x) for x in f["ui_fallback"]])
    mono_stack = ", ".join([f'"{f["mono"]}"'] + [css_font(x) for x in f["mono_fallback"]])
    L.append(f"  --font-ui: {ui_stack};")
    L.append(f"  --font-mono: {mono_stack};")
    L.append("")
    for name, s in t["type_scale"].items():
        L.append(f"  --fs-{name}: {s['size']}px;")
        L.append(f"  --lh-{name}: {s['line_height']};")
    L.append("")
    for name, v in t["radius"].items():
        L.append(f"  --radius-{name}: {v}px;")
    L.append("")
    for name, v in t["spacing"].items():
        L.append(f"  --space-{name}: {v}px;")
    L.append("")
    m = t["motion"]
    L.append(f"  --motion-short: {m['short_ms']}ms;")
    L.append(f"  --motion-medium: {m['medium_ms']}ms;")
    L.append(f"  --motion-ui: {m['web_ui_ms']}ms;")
    L.append(f"  --touch-min: {t['touch_min']}px;")
    L.append("")
    # 派生变量：图表配色 / 遮罩 / 编辑器高亮。页面不再硬编码 hex 或 rgba，
    # 都从这几个派生值取，值仍由 tokens.json 的色板算出。
    ar, ag, ab = hex_rgb(t["colors"]["accent"])
    tr, tg, tb = hex_rgb(t["colors"]["terminal"])
    L.append(f"  --chart-accent: rgb({ar}, {ag}, {ab});")
    L.append(f"  --chart-info: {css_color(t['colors']['info'])};")
    L.append(f"  --chart-ok: {css_color(t['colors']['ok'])};")
    L.append(f"  --chart-grid: {css_color(t['colors']['border'])};")
    L.append(f"  --chart-axis: {css_color(t['colors']['faint'] if 'faint' in t['colors'] else t['colors']['text-faint'])};")
    L.append(f"  --chart-tick: {css_color(t['colors']['text-muted'])};")
    L.append(f"  --chart-tooltip-bg: {css_color(t['colors']['surface-2'])};")
    L.append(f"  --chart-tooltip-border: {css_color(t['colors']['border-strong'])};")
    L.append(f"  --scrim: rgba({tr}, {tg}, {tb}, 0.60);")
    L.append(f"  --scrim-strong: rgba({tr}, {tg}, {tb}, 0.70);")
    L.append(f"  --accent-wash-06: rgba({ar}, {ag}, {ab}, 0.06);")
    L.append(f"  --accent-wash-10: rgba({ar}, {ag}, {ab}, 0.10);")
    L.append(f"  --accent-wash-20: rgba({ar}, {ag}, {ab}, 0.20);")
    L.append("")
    L.append("  color-scheme: dark;")
    L += ["}", END]
    return "\n".join(L)


# ----------------------------------------------------------- tailwind --------

def render_tailwind(t: dict) -> str:
    # 必须自带 extend 包装：若把生成块直接放在 theme 下，会覆盖 Tailwind 默认
    # 调色板 / spacing / 圆角 / 阴影，导致 p-3、w-16、h-14 等默认工具类全部消失。
    L = [BEGIN, "    extend: {", "      colors: {"]
    for key in COLOR_MAP:
        css_var = COLOR_MAP[key][0]
        L.append(f'        {q(key)}: "var({css_var})",')
    # 派生遮罩色：Tailwind 3 对 var() 颜色加 /opacity 修饰符不生效，
    # 所以遮罩直接用带 alpha 的完整 rgba 值，写法是 bg-scrim / bg-scrim-strong。
    L.append('        scrim: "var(--scrim)",')
    L.append('        "scrim-strong": "var(--scrim-strong)",')
    L.append("      },")
    f = t["fonts"]
    ui = ", ".join(f'"{x}"' for x in [f["ui"]] + f["ui_fallback"])
    mono = ", ".join(f'"{x}"' for x in [f["mono"]] + f["mono_fallback"])
    L.append("      fontFamily: {")
    L.append(f"        sans: [{ui}],")
    L.append(f"        mono: [{mono}],")
    L.append("      },")
    L.append("      fontSize: {")
    for name, s in t["type_scale"].items():
        extra = ""
        if s["weight"] != 400:
            extra += f', fontWeight: "{s["weight"]}"'
        if "letter_spacing" in s:
            extra += f', letterSpacing: "{s["letter_spacing"]}em"'
        L.append(f'        {q(name)}: ["{s["size"]}px", {{ lineHeight: "{s["line_height"]}"{extra} }}],')
    L.append("      },")
    L.append("      borderRadius: {")
    for name, v in t["radius"].items():
        L.append(f'        {q(RADIUS_TW[name])}: "{v}px",')
    L.append("      },")
    L.append("      spacing: {")
    L.append(f'        section: "{t["spacing"]["xxl"]}px",')
    L.append("      },")
    L.append("      boxShadow: {")
    L.append('        modal: "0 8px 24px rgba(0,0,0,.4)",')
    L.append("      },")
    L.append("      transitionTimingFunction: {")
    L.append('        ui: "cubic-bezier(0.2, 0, 0, 1)",')
    L.append("      },")
    L.append("      transitionDuration: {")
    L.append(f'        ui: "{t["motion"]["web_ui_ms"]}ms",')
    L.append("      },")
    L.append("    },")
    L.append("    " + END)
    return "\n".join(L)


# --------------------------------------------------------------- Dart --------

def render_dart(t: dict) -> str:
    L = [
        "// GENERATED FILE — DO NOT EDIT.",
        "// 由 scripts/gen_design_tokens.py 从 design/tokens.json 生成。",
        "// 唯一真源是 design/tokens.json；CI 以 --check 校验本文件未漂移。",
        "",
        "import 'package:flutter/material.dart';",
        "",
        "/// 色板。值与 web/DESIGN.md §2、web/src/index.css 完全同源。",
        "class AppColors {",
        "  const AppColors._();",
        "",
    ]
    for key, (_, field) in COLOR_MAP.items():
        L.append(f"  static const Color {field} = {dart_color(t['colors'][key])};")
    L += ["}", ""]
    f = t["fonts"]
    L += [
        "/// 字体栈。字体文件未随包分发（省 2–4MB），运行时走 fontFamilyFallback。",
        "/// 有意的偏差：契约要求 Geist/JetBrains Mono，当前仅声明优先名 + 回退链。",
        "class AppFonts {",
        "  const AppFonts._();",
        f"  static const String ui = '{f['ui']}';",
        f"  static const String mono = '{f['mono']}';",
        "  static const List<String> uiFallback = <String>[" + ", ".join(f"'{x}'" for x in f["ui_fallback"]) + "];",
        "  static const List<String> monoFallback = <String>[" + ", ".join(f"'{x}'" for x in f["mono_fallback"]) + "];",
        "}",
        "",
        "/// 间距系统，基准 4px。",
        "class AppSpacing {",
        "  const AppSpacing._();",
    ]
    for k, v in t["spacing"].items():
        L.append(f"  static const double {k} = {v};")
    L += ["}", "", "/// 圆角。", "class AppRadius {", "  const AppRadius._();"]
    for k, v in t["radius"].items():
        L.append(f"  static const double {k} = {v};")
    L += ["}", ""]
    m = t["motion"]
    L += [
        "/// 动效：120–200ms ease-out，禁用 bounce/elastic。",
        "class AppMotion {",
        "  const AppMotion._();",
        f"  static const Duration short = Duration(milliseconds: {m['short_ms']});",
        f"  static const Duration medium = Duration(milliseconds: {m['medium_ms']});",
        "  static const Curve easing = Curves.easeOut;",
        "}",
        "",
        "/// 触控最小目标（移动端硬指标，DESIGN.md §7）。",
        f"const double touchMin = {t['touch_min']};",
        "",
        "/// 字阶 10 档（DESIGN.md §3）。供 ThemeData.textTheme 及页面直接引用。",
        "class AppTextStyles {",
        "  const AppTextStyles._();",
    ]
    for name, s in t["type_scale"].items():
        field = re.sub(r"-([a-z])", lambda mo: mo.group(1).upper(), name)
        weight = f"FontWeight.w{s['weight']}"
        ls = f", letterSpacing: {s['letter_spacing'] * s['size']:.2f}" if "letter_spacing" in s else ""
        mono = ", fontFamily: AppFonts.mono, fontFamilyFallback: AppFonts.monoFallback" if name.startswith("mono") else ""
        L.append(
            f"  static const TextStyle {field} = TextStyle("
            f"fontSize: {s['size']}, height: {s['line_height']}, fontWeight: {weight}{ls}{mono});"
        )
    L += [
        "",
        "  /// 数字等宽对齐（表格/监控/文件大小/时间戳），契约 §3。",
        "  static const TextStyle numeric = TextStyle(",
        "    fontFeatures: <FontFeature>[FontFeature.tabularFigures()],",
        "  );",
        "}",
        "",
        "/// 字号常量（字阶 10 档的唯一真源入口，DESIGN.md §3）。",
        "/// 页面禁止再写裸 fontSize 数字：CI 以 --check 扫描 lib/ 断言无硬编码，",
        "/// 所有局部微调也必须引用这里的常量，避免同一语义出现多种字号。",
        "class AppFontSizes {",
        "  const AppFontSizes._();",
    ]
    for name, s in t["type_scale"].items():
        field = re.sub(r"-([a-z])", lambda mo: mo.group(1).upper(), name)
        L.append(f"  static const double {field} = {s['size']};")
    L += ["}", ""]
    return "\n".join(L)


# ---------------------------------------------------------- 对比度 --------

def wcag_luminance(hex_color: str) -> float:
    h = hex_color.lstrip("#")
    c = [int(h[i : i + 2], 16) / 255 for i in (0, 2, 4)]
    c = [x / 12.92 if x <= 0.03928 else ((x + 0.055) / 1.055) ** 2.4 for x in c]
    return 0.2126 * c[0] + 0.7152 * c[1] + 0.0722 * c[2]


def contrast(a: str, b: str) -> float:
    l1, l2 = sorted([wcag_luminance(a), wcag_luminance(b)], reverse=True)
    return (l1 + 0.05) / (l2 + 0.05)


def check_contrast(t: dict) -> list[str]:
    colors = t["colors"]
    errors = []
    for fg, bg in t["contrast_pairs"]:
        a, b = colors[fg], colors[bg]
        if isinstance(a, list) or isinstance(b, list):
            continue
        v = contrast(a, b)
        if v < 4.5:
            errors.append(f"对比度不足: {fg}/{bg} = {v:.2f}:1 (< 4.5:1)")
    return errors


# ------------------------------------------------------------ I/O --------

def replace_block(path: Path, rendered: str, legacy_pattern: str | None = None) -> None:
    cur = path.read_text(encoding="utf-8")
    if BEGIN in cur and END in cur:
        cur = re.sub(re.escape(BEGIN) + r".*?" + re.escape(END), lambda _: rendered, cur, flags=re.S)
    else:
        # 首次生成：用旧的手写块定位替换
        new, n = re.subn(legacy_pattern, lambda _: rendered, cur, count=1, flags=re.S)
        if n != 1:
            raise RuntimeError(f"{path} 找不到可替换的手写块")
        cur = new
    path.write_text(cur, encoding="utf-8")


def write(t: dict) -> None:
    replace_block(INDEX_CSS, render_css(t), r":root\s*\{.*?\}")
    replace_block(TAILWIND, render_tailwind(t), r"extend:\s*\{.*?\n    \},")
    DART_TOKENS.write_text(render_dart(t), encoding="utf-8")
    print("生成完成：index.css / tailwind.config.js / design_tokens.dart")


def check(t: dict) -> list[str]:
    errors: list[str] = []
    for path, rendered in (
        (INDEX_CSS, render_css(t)),
        (TAILWIND, render_tailwind(t)),
    ):
        cur = path.read_text(encoding="utf-8")
        if BEGIN not in cur or END not in cur:
            errors.append(f"{path.relative_to(ROOT)} 缺少 GENERATED TOKENS 标记区间")
        elif rendered not in cur:
            errors.append(f"{path.relative_to(ROOT)} 生成区间与 tokens.json 不一致（需 --write）")
    if not DART_TOKENS.exists():
        errors.append("缺少 app/lib/core/theme/design_tokens.dart（需 --write）")
    elif DART_TOKENS.read_text(encoding="utf-8").strip() != render_dart(t).strip():
        errors.append("design_tokens.dart 与 tokens.json 不一致（需 --write）")
    errors.extend(check_contrast(t))
    errors.extend(check_font_sizes())
    errors.extend(check_table_columns())
    return errors


def check_table_columns() -> list[str]:
    """CI 断言：Web 表格的响应式列 th/td 必须成对，否则列会错位。

    加了 `hidden lg:table-cell` / `hidden xl:table-cell` 的表头，
    tbody 里必须有同样数量的单元格使用同一断点类。
    """
    pages = ROOT / "web" / "src" / "pages"
    if not pages.is_dir():
        return []
    errors: list[str] = []
    for path in sorted(pages.rglob("*.tsx")):
        text = path.read_text(encoding="utf-8")
        for bp in ("lg:table-cell", "xl:table-cell"):
            n_th = sum(
                1 for line in text.splitlines()
                if bp in line and ("<th" in line or "th(" in line)
            )
            n_td = sum(
                1 for line in text.splitlines()
                if bp in line and "<td" in line
            )
            if n_th != n_td:
                errors.append(
                    f"{path.relative_to(ROOT)}: {bp} 表头 {n_th} 个 / "
                    f"单元格 {n_td} 个，不成对会列错位"
                )
    return errors


def check_font_sizes() -> list[str]:
    """CI 断言：lib/ 下业务代码不得再写裸 fontSize 数字（生成物除外）。

    字号必须引用 AppFontSizes，值由 tokens.json 的 10 档字阶统一给出，
    避免同一语义在不同页面出现多种字号、以及低于 11px 下限的写法回潮。
    """
    lib = ROOT / "app" / "lib"
    if not lib.is_dir():
        return []
    excluded = {"design_tokens.dart"}
    bare = re.compile(r"fontSize:\s*\d")
    errors: list[str] = []
    for path in sorted(lib.rglob("*.dart")):
        if path.name in excluded or path.name.endswith((".freezed.dart", ".g.dart")):
            continue
        for lineno, line in enumerate(path.read_text(encoding="utf-8").splitlines(), 1):
            if bare.search(line):
                errors.append(
                    f"{path.relative_to(ROOT)}:{lineno} 仍有裸 fontSize 数字，"
                    f"应引用 AppFontSizes：{line.strip()[:80]}"
                )
    return errors


def main() -> int:
    ap = argparse.ArgumentParser()
    ap.add_argument("--write", action="store_true")
    ap.add_argument("--check", action="store_true")
    args = ap.parse_args()
    t = load()
    if args.write:
        write(t)
        return 0
    errors = check(t)
    if errors:
        print("设计令牌校验失败：", file=sys.stderr)
        for e in errors:
            print(f"  - {e}", file=sys.stderr)
        return 1
    print("设计令牌校验通过：三处生成物一致 / 对比度全部 >= 4.5:1")
    return 0


if __name__ == "__main__":
    sys.exit(main())
