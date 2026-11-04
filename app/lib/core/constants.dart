// 兼容入口：设计令牌的唯一真源是 core/theme/design_tokens.dart（由
// design/tokens.json 生成，禁止手工改）。这里只做再导出，保证现有
// `import '../constants.dart'` 的引用点全部不用改。
//
// 色板 AppColors / 字体 AppFonts 仍从 app_theme.dart 导出（历史引用路径），
// 因此这里不重复导出，避免同名符号冲突。
export 'theme/design_tokens.dart'
    show AppSpacing, AppRadius, AppMotion, touchMin;
