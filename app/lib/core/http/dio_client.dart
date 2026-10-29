import 'dart:async';

import 'package:dio/dio.dart';

import 'auth_interceptor.dart';
import 'envelope.dart';

/// dio 实例档位（M11+M12 地基）。
///
/// 为什么分四个实例而不是一个：
///  - 普通 CRUD 与上传/下载/SSE 的超时语义天然冲突。给 CRUD 设 15s `receiveTimeout`
///    是对的（弱网快速失败），但同样的设置会让 4MiB 分片上传、大文件下载、长连接 SSE
///    在传输途中被 dio 主动掐断——报错文案还是「请求超时」，排查时极具误导性。
///  - 401 重放对「已消费的响应体」有副作用：上传/下载的 body 是流，重放会产生半包。
///    所以流式实例必须关闭重放，让 401 直接冒泡给调用方重新发起。
///  - 探活（health / 升级轮询）要求 3s 内必有结论：升级期间面板会停机，
///    用 15s 超时会让「发现服务已停」慢 5 倍，App 的升级进度条会长时间卡住。
enum DioProfile {
  /// 全部 JSON CRUD。10/20/20s，401 允许重放一次。
  json,

  /// 上传 / 下载 / SSE。无 `receiveTimeout`（改由空闲看门狗兜底），401 禁止重放。
  stream,

  /// 登录 / refresh 等无 Bearer 的端点。只挂信封解包，不挂鉴权、不触发刷新回路。
  plain,

  /// health / 升级状态轮询。3s 全超时，不挂任何拦截器（连信封都不解析）。
  probe,
}

/// 各档位的超时与行为矩阵，集中在此避免散落在各 repository 里。
class DioProfileSpec {
  const DioProfileSpec({
    required this.connectTimeout,
    required this.sendTimeout,
    required this.receiveTimeout,
    required this.allowReplay,
    required this.withAuth,
    required this.withEnvelope,
  });

  final Duration connectTimeout;
  final Duration? sendTimeout;
  final Duration? receiveTimeout;

  /// 401 后是否允许「刷新令牌 + 重放原请求」。
  ///
  /// 流式请求必须为 false：重放一个已部分消费的 body 会得到半包，
  /// 表现为文件损坏或 JSON 解析异常，而不是可读的错误。
  final bool allowReplay;
  final bool withAuth;
  final bool withEnvelope;

  static const DioProfileSpec json = DioProfileSpec(
    connectTimeout: Duration(seconds: 10),
    sendTimeout: Duration(seconds: 20),
    receiveTimeout: Duration(seconds: 20),
    allowReplay: true,
    withAuth: true,
    withEnvelope: true,
  );

  static const DioProfileSpec stream = DioProfileSpec(
    connectTimeout: Duration(seconds: 10),
    sendTimeout: null,
    receiveTimeout: null,
    allowReplay: false,
    withAuth: true,
    withEnvelope: true,
  );

  static const DioProfileSpec plain = DioProfileSpec(
    connectTimeout: Duration(seconds: 10),
    sendTimeout: Duration(seconds: 15),
    receiveTimeout: Duration(seconds: 15),
    allowReplay: false,
    withAuth: false,
    withEnvelope: true,
  );

  static const DioProfileSpec probe = DioProfileSpec(
    connectTimeout: Duration(seconds: 3),
    sendTimeout: Duration(seconds: 3),
    receiveTimeout: Duration(seconds: 3),
    allowReplay: false,
    withAuth: false,
    withEnvelope: false,
  );

  static DioProfileSpec of(DioProfile profile) => switch (profile) {
        DioProfile.json => json,
        DioProfile.stream => stream,
        DioProfile.plain => plain,
        DioProfile.probe => probe,
      };
}

/// 创建一个 dio 实例。
///
/// 拦截器顺序固定为 `[EnvelopeInterceptor, AuthInterceptor]`：
/// 信封先解包（把业务失败转成 ApiException 挂在 DioException.error 上），
/// 鉴权后处理（才能识别 code==401 并触发刷新）。
Dio createProfileDio(
  DioProfile profile, {
  Future<String?> Function()? getToken,
  Future<String?> Function()? getBaseUrl,
  Future<void> Function()? onUnauthorized,
}) {
  final spec = DioProfileSpec.of(profile);
  final dio = Dio(
    BaseOptions(
      connectTimeout: spec.connectTimeout,
      sendTimeout: spec.sendTimeout,
      receiveTimeout: spec.receiveTimeout,
      // 状态码一律放行给拦截器：让 401/409 的**信封文案**（后端中文提示）
      // 能透到 UI，而不是被 dio 统一换成「服务异常」。
      validateStatus: (_) => true,
      followRedirects: true,
      maxRedirects: 5,
    ),
  );
  if (spec.withEnvelope) {
    dio.interceptors
        .add(EnvelopeInterceptor(isStream: profile == DioProfile.stream));
  }
  if (spec.withAuth && getToken != null && getBaseUrl != null) {
    dio.interceptors.add(
      AuthInterceptor(
        dio,
        getToken,
        getBaseUrl,
        onUnauthorized ?? () async {},
        allowReplay: spec.allowReplay,
      ),
    );
  } else if (!spec.withAuth && getBaseUrl != null) {
    // 探活档位同样需要动态 base_url（用户可在隐藏入口改址），但不带令牌：
    // 一个匿名请求失败就该立刻判定「服务不可达」，而不是挂在刷新回路里。
    dio.interceptors.add(BaseUrlInterceptor(getBaseUrl));
  }
  return dio;
}

/// 只注入 base_url、不注入令牌、不处理 401 的极简拦截器（探活专用）。
class BaseUrlInterceptor extends Interceptor {
  BaseUrlInterceptor(this._getBaseUrl);

  final Future<String?> Function() _getBaseUrl;

  @override
  Future<void> onRequest(
    RequestOptions options,
    RequestInterceptorHandler handler,
  ) async {
    final baseUrl = await _getBaseUrl();
    if (baseUrl != null && baseUrl.isNotEmpty) {
      options.baseUrl = baseUrl.endsWith('/')
          ? baseUrl.substring(0, baseUrl.length - 1)
          : baseUrl;
    }
    handler.next(options);
  }
}

/// 签名向后兼容的构造函数（鉴权 JSON 档）。
Dio createDio({
  required Future<String?> Function() getToken,
  required Future<String?> Function() getBaseUrl,
  required Future<void> Function() onUnauthorized,
}) =>
    createProfileDio(
      DioProfile.json,
      getToken: getToken,
      getBaseUrl: getBaseUrl,
      onUnauthorized: onUnauthorized,
    );

/// 流式请求的空闲看门狗。
///
/// 为什么不用 `receiveTimeout`：它约束的是**单次 socket 读**的间隔，而不是
/// 「整体是否还在动」。SSE 每 15s 有 keepalive 注释帧、下载会持续有字节，
/// 两者都合法但不能共用同一个固定阈值；反过来，连接被中间设备半开挂起时，
/// socket 上永远等不到数据，只有看门狗能发现。
///
/// 用法：`final guard = StreamWatchdog(token); guard.touch(); ...; guard.dispose();`
/// 每次收到进度回调时 `touch()`，超过 [idleTimeout] 无触摸即取消请求。
class StreamWatchdog {
  StreamWatchdog(
    this._token, {
    this.idleTimeout = const Duration(seconds: 90),
  }) {
    _timer = Timer.periodic(const Duration(seconds: 5), (_) => _check());
  }

  final CancelToken _token;
  final Duration idleTimeout;
  late final Timer _timer;
  DateTime _last = DateTime.now();

  void touch() => _last = DateTime.now();

  void _check() {
    if (DateTime.now().difference(_last) >= idleTimeout && !_token.isCancelled) {
      _token.cancel('传输空闲超时（${idleTimeout.inSeconds}s 内无数据）');
    }
  }

  void dispose() => _timer.cancel();
}
