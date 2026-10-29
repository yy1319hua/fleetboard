/// 在线编辑的硬上限（与后端 `maxTextBytes = 1 << 20` 对齐）。
///
/// 必须在**点之前**判断：后端超限返回 400，让用户等一次往返才知道
/// 「这个文件不能编辑」纯属浪费；大文件读进来再失败，内存也白花。
const int maxEditableBytes = 1 << 20;

/// 文件类型判断（决定「能不能在线编辑」）。
///
/// 为什么必须判断而不是「只要 ≤1MiB 就给编辑」：后端 `files/content` 是把文件
/// 字节直接塞进 JSON 字符串返回的，非 UTF-8 的字节在 JSON 编码时会被替换成
/// U+FFFD。对一张 JPEG 打开编辑器再保存，等于把这个文件彻底写坏——而用户
/// 完全看不出发生了什么。所以编辑入口只对文本类文件开放。
const Set<String> _textExtensions = <String>{
  'conf', 'cfg', 'ini', 'env', 'yml', 'yaml', 'json', 'toml', 'xml', 'txt',
  'log', 'md', 'sh', 'bash', 'zsh', 'service', 'properties', 'sql', 'js',
  'ts', 'py', 'go', 'rs', 'java', 'php', 'rb', 'html', 'css', 'csv', 'pem',
  'crt', 'key', 'pub', 'list', 'repo', 'rules', 'lua', 'pl', 'gradle',
  'mod', 'sum', 'lock', 'gitignore', 'dockerignore', 'editorconfig',
};

/// 常见无扩展名但确定是文本的文件。
const Set<String> _textNames = <String>{
  'dockerfile', 'makefile', 'readme', 'license', 'crontab', 'hosts',
  'fstab', 'passwd', 'group', 'resolv.conf', 'authorized_keys',
};

bool looksLikeTextFile(String name) {
  final lower = name.toLowerCase();
  if (_textNames.contains(lower)) return true;
  final dot = lower.lastIndexOf('.');
  if (dot < 0 || dot == lower.length - 1) return false;
  return _textExtensions.contains(lower.substring(dot + 1));
}
