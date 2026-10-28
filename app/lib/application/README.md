# application 层（顶层，跨特性共享占位）

用例 / 状态 Provider 层。M9.1 占位。

M9.2+ 落地（详见 M9 方案 §3.4）：
`authProvider`（B1 续期/onResumed）、`bootstrapProvider`（GET /api/bootstrap + 写 SnapshotStore）、
`containerListProvider(filter)`、`alertCenterProvider`（B7 共享已读态）、`jobTrackerProvider`（202+jobId→SSE→被杀续接）、
`logSessionProvider`（WsLogClient 生命周期）、`connectivityProvider`（OfflineBanner）、`settingsProvider`、`updateCheckProvider`（B8/B9）。
