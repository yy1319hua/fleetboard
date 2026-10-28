# lib 架构

fleetboard App 分层（落地自 M9 方案 §2.1）：

```
features → application → domain → data → core
```

- `core/`：横切（设计令牌、常量、错误信封、http 薄封装）。稳定层，不依赖任何业务层。
- `features/`：按业务域拆分（auth/overview/alerts/emergency/settings），每个含
  `data / domain / application / presentation` 四层子目录（M9.1 仅占位）。
- 顶层 `application/ domain/ data/`：跨特性共享的分层职责目录（M9.1 占位）。

依赖方向：`features → application → domain`；`data` 实现 `domain` 接口；
`data/application/features` 依赖 `core`；`domain` 与 `core` 互不依赖（稳定层）。
任何层不得反向依赖 features。

> M9.1 仅做「可编译工程地基 + 依赖清单 + 目录 + 主题/路由空壳」，不含业务实现。
