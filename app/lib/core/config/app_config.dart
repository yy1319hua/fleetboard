/// 客户端静态配置（M10.2 落地）。
///
/// 背景：自分发 App 早期要求用户在登录页手填服务器地址（base_url）。自 M10.2 起改为
/// 「内置默认地址 + 登录页只留用户名/密码」，改址走登录页标题连点 7 次的隐藏入口。
///
/// 仓库内**不保存真实服务器地址**（`credscan` 规则禁止内网域名入库），默认地址由
/// 发布流水线在打包时经 `--dart-define=FLEETBOARD_BASE_URL` 注入（见 release.yml）。
///
/// 地址生效优先级（见 [AuthNotifier.effectiveBaseUrl]）：
///   1. 已存值（SecureStore 里的 base_url）—— refresh 续期绑死签发域名，必须最高优先
///   2. 编译期注入 `--dart-define=FLEETBOARD_BASE_URL`
///   3. 代码内置常量 [fallbackBaseUrl]（默认为空 = 未配置）
class AppConfig {
  const AppConfig._();

  /// 编译期注入的地址；CI 未定义该变量时展开为空串。
  ///
  /// 注意：`String.fromEnvironment` 必须是 const 上下文，否则 AOT 构建下会静默取默认值。
  static const String injectedBaseUrl =
      String.fromEnvironment('FLEETBOARD_BASE_URL');

  /// 代码内置兜底地址：**故意留空**。
  ///
  /// 真实地址属部署环境信息，不入仓库；由发布流水线注入。为空时 App 会在登录前
  /// 明确提示「客户端未配置服务器地址」，而不是静默连一个不存在的域名。
  static const String fallbackBaseUrl = '';

  /// 出厂默认地址：注入值优先，空串回退内置常量。
  static String get defaultBaseUrl =>
      injectedBaseUrl.isEmpty ? fallbackBaseUrl : injectedBaseUrl;

  /// 是否已配置到可用地址（未配置时登录页给出明确提示，而非发起必败请求）。
  static bool get hasDefaultBaseUrl => normalize(defaultBaseUrl).isNotEmpty;

  /// 仅主机名，用于登录页只读提示（不带 scheme/path，避免误导）。
  static String get defaultHost => _hostOf(defaultBaseUrl);

  /// 规范化：去首尾空白 + 去尾部斜杠。**不补 https**（内网 http 部署必须原样保留）。
  static String normalize(String value) {
    final trimmed = value.trim();
    if (trimmed.isEmpty) return trimmed;
    return trimmed.replaceAll(RegExp(r'/+$'), '');
  }

  /// 地址是否形如可达的 URL（仅做轻量格式校验，不发起网络请求）。
  static bool looksValid(String value) {
    final normalized = normalize(value);
    if (normalized.isEmpty) return false;
    final uri = Uri.tryParse(normalized);
    return uri != null &&
        uri.hasScheme &&
        (uri.scheme == 'http' || uri.scheme == 'https') &&
        uri.host.isNotEmpty;
  }

  /// 取 host 用于展示；解析失败时原样返回。
  static String _hostOf(String baseUrl) {
    final uri = Uri.tryParse(baseUrl);
    return (uri != null && uri.host.isNotEmpty) ? uri.host : baseUrl;
  }

  /// 展示用主机名（与 [defaultHost] 同构，供登录页对任意地址复用）。
  static String hostOf(String baseUrl) => _hostOf(baseUrl);
}
