# features 层

按业务域拆分模块，每个模块含四层：
- `presentation/`：页面与组件（M9.1 仅空壳 ConsumerWidget 占位页）。
- `application/`：用例 / 状态。
- `domain/`：实体 / 仓储接口。
- `data/`：仓储实现 / DTO / Mapper。

模块清单：auth / overview / alerts / emergency / settings。
M9.1 不写业务逻辑，仅建立目录与占位页。
