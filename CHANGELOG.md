# FlashLink 更新日志

## v1.1.1 — 2026-08-28

### 概述

本次更新聚焦 **系统分享面板兼容性修复**。应用"闪连"在部分华为机型/系统版本的系统分享面板中不可见，经过系统性排查和修复，解决了 skills 配置缺失 entities、多文件 action 遗漏、MIME 类型匹配粒度不足、华为机型元数据缺失、文件读取权限不全等问题。

---

### 🐛 问题修复

#### 1. 系统分享面板不可见（核心修复）

**根因**：API 12+ Stage 模型下，系统分享面板通过 `entities` 字段筛选分享目标应用。缺少 `"entities": ["entity.system.share"]` 导致匹配失败。

**修复项**：

| 修复点 | 文件 | 说明 |
|--------|------|------|
| 新增 `entities: ["entity.system.share"]` | `module.json5` | 🔴 核心根因 |
| 新增 `ohos.want.action.sendMultipleData` + `ohos.want.action.viewData` | `module.json5` | 🟠 多文件+备用匹配 |
| 展开 MIME 类型为 6 条（image/video/audio/application/text/*/*） | `module.json5` | 🟡 提高匹配命中率 |
| 新增 `metadata: ohos.ability.share.target=true` | `module.json5` | 🟠 华为机型兼容 |
| 新增 `READ_MEDIA` + `READ_DOCUMENT` 权限及说明字符串 | `module.json5` + `string.json` | 🟠 文件访问必须 |

#### 2. URI 提取策略增强

**问题**：部分系统版本使用 `parameters['uris']`（复数 key）传递文件 URI，或通过其他参数路径传递，原逻辑仅检查 `parameters['uri']` 导致漏处理。

**修复**：将 `handleShareData` 改造为 `async`，新增三级 URI 提取策略：

```
策略 1: parameters['uri']       → 传统单/多文件 key
策略 2: parameters['uris']      → 部分系统复数 key（新增）
策略 3: 全量 parameters 扫描    → 遍历所有 key 找 file:// 开头的值（兜底）
```

#### 3. 运行时调试诊断增强

- 新增 `logWantDetail(want)` 方法，打印 `want.action`、`want.entities`、`want.parameters` 全量 keys 及各关键字段值
- `onCreate` / `onNewWant` 中添加 `.catch()` 异步异常安全处理

---

### 🔧 文件变更明细

| 文件 | 状态 | 变更内容 |
|------|------|----------|
| `module.json5` | 修改 | 新增 entities、sendMultipleData/viewData 动作、展开 MIME 规则、新增 metadata、新增 READ_MEDIA+READ_DOCUMENT 权限 |
| `resources/base/element/string.json` | 修改 | 新增 2 条权限说明字符串 |
| `entryability/EntryAbility.ets` | 修改 | 新增 extractUrisFromWant 三级提取、trySystemShareApi 全量扫描替补、logWantDetail 诊断日志、async 改造 + .catch 安全调用 |
| `docs/share-panel-inspection-log.md` | 新增 | 系统性排查修复日志（v2.0, 220行） |

---

### 📊 代码统计

- **4 个文件修改**，横跨配置、资源、代码、文档四层
- 修复 **7 项**问题（3 项致命/重要，4 项推荐/增强）

---

## v1.1.0 — 2026-08-28

### 概述

本次更新将 FlashLink 手机端协议升级至 **v1.1**，引入了双向握手确认机制、多文件分享支持、设备发现版本校验、以及更清晰的错误传达能力。

---

### 🚀 新特性

#### 1. 协议升级 v1.1（TransferEngine / Types）

- **新增协议头魔数与版本号**：`ProtocolConstants` 定义了魔数 `0x464C`、协议版本 `0x01`、保留字段。
- **新增双向确认机制**：
  - `waitForConfirm()` — 发送协议头后等待接收端回复：`0x01`（允许）/ `0x02`（拒绝）/ `0x03`（超时）。
  - `waitForComplete()` — 文件内容发送完毕后等待接收端 `0x04` 完成确认。
- **协议头格式重写**：从 2+变长+4 字节变为 4+变长+8 字节（含魔数、版本、保留字段、Uint64 文件大小）。
- **新增错误码枚举**：`TransferErrorCode` 定义了 `VERSION_MISMATCH`、`RECEIVER_REJECTED`、`RECEIVER_TIMEOUT` 等 7 种错误码。

#### 2. 多文件分享支持（EntryAbility）

- `handleShareData()` 现在支持 `want.parameters['uri']` 为 **string 数组**（系统分享多文件）。
- 每个 URI 单独解析为 `SharedFileInfo`，存入 `AppStorage('sharedFiles')` 驱动 UI 列表渲染。
- 文件列表**串行传输**，任一文件失败即终止后续传输并透传错误信息。

#### 3. 设备发现版本校验（DeviceDiscoverer）

- mDNS 发现时读取 TXT 记录中的 `version` 键，与预期版本 `1.1.0` 比对。
- 版本不匹配的设备将被忽略，并输出警告日志。

#### 4. 错误信息透传（EntryAbility → Index UI）

- 传输引擎抛出的错误（Receiver rejected、Receiver timeout、协议版本不兼容等）通过 `AppStorage.setOrCreate('transferError', msg)` 传递到 UI 层。
- UI 层优先展示 `viewModel.errorMsg` 中的具体错误文案。

---

### 🎨 UI 改进

#### 1. WAITING_CONFIRM 状态渲染（Index）

- **状态图标**：显示 `⏳` 沙漏图标（橙色 `#F5A623`）。
- **状态文案**：`⏳ 等待电脑端确认...`。
- **进度条**：`value=0` 空进度条（橙色），下方显示 `LoadingProgress` 加载动画，确保不被填充。
- **百分比文本**：显示 `--`。
- **设备名称**：在 WAITING_CONFIRM 状态下也展示目标设备名。

#### 2. 失败状态增强（Index）

- 错误文案从 13px/浅红 升级为 **14px/深红 `#D32F2F`/加粗**，最多显示 4 行。
- 新增操作按钮：
  - **「返回」** 按钮：灰色背景，重置状态到 IDLE。
  - **「重试」** 按钮：蓝色主题，重置状态到 IDLE（用户重新分享文件触发实际传输）。

---

### 🔧 文件变更明细

| 文件 | 状态 | 变更内容 |
|------|------|----------|
| `model/Types.ets` | 修改 | 新增 `TransferErrorCode` 枚举、`ProtocolConstants` 静态常量、`TransferStatus.WAITING_CONFIRM` 状态 |
| `utils/TransferEngine.ets` | 修改 | 实现 v1.1 协议头编码、`waitForConfirm()`、`waitForComplete()`、增强 `abort()` 中断等待 |
| `utils/DeviceDiscoverer.ets` | 修改 | 新增 TXT 版本校验、端口解析优化 |
| `entryability/EntryAbility.ets` | 修改 | 多 URI 数组解析、文件列表串行传输、逐文件异常捕获、`transferError` 透传 |
| `pages/Index.ets` | 修改 | WAITING_CONFIRM 全状态渲染、增强失败提示 + 操作按钮、辅助方法更新 |

---

### 📊 代码统计

- **5 个文件修改**，新增 **566 行**，删除 **103 行**。
- 核心传输协议完全升级至 v1.1，新增双向握手确认流程。
- 多文件分享从单 URI 扩展至 URI 数组支持。

---

### ⚠️ 已知问题 / 后续计划

- [ ] PC 端接收程序需同步升级至 v1.1 协议（含魔数校验、确认回复、完成确认）。
- [ ] 「重试」按钮当前仅重置 UI 状态，实际重试需用户重新触发系统分享。
- [ ] 多文件传输进度目前为串行，后续可考虑并行传输优化。

---

## v1.2.0 — 2026-08-28

### 概述

新增 **手动文件选择** 功能。在首页「等待分享文件」空闲状态下，用户可通过点击「选择分享」按钮主动打开系统文件管理器（DocumentViewPicker），选取文件后自动进入设备发现与传输管道。至此，应用同时支持「系统分享唤起」和「应用内手动选择」两种文件触发方式。

---

### 🚀 新特性

#### 1. 手动选择文件按钮

**描述**：在 IDLE 空闲状态页面，`等待分享文件` 文字下方新增居中蓝色圆角 **「选择分享」** 按钮。

| 属性 | 值 |
|------|-----|
| 文字 | `选择分享` |
| 圆角 | 20px |
| 颜色 | `#3A86FF`（品牌蓝） |
| 尺寸 | 160×44px |
| 显示条件 | 仅 `TransferStatus.IDLE` 状态下可见 |

**交互流程**：
1. 用户点击「选择分享」按钮
2. 系统文件管理器（DocumentViewPicker）打开，支持多文件选择
3. 选择完成后自动解析为 `SharedFileInfo` 列表
4. 调用传输管道 → 设备发现（mDNS）→ TCP 文件传输

---

### 🔧 文件变更明细

| 文件 | 状态 | 变更内容 |
|------|------|----------|
| `entry/src/main/ets/pages/Index.ets` | 🔧 修改 | 新增 `picker` / `fileIo` / `common` 等导入；新增 `handleFilePicker()` 方法调用 DocumentViewPicker；在 `buildStatusArea()` 的 IDLE 区域新增「选择分享」按钮 |
| `entry/src/main/ets/entryability/EntryAbility.ets` | 🔧 修改 | 新增模块级 `entryAbilityInstance` 变量；新增公共方法 `handleManualFiles()`；导出 `triggerManualTransfer()` 函数供 UI 层调用 |

---

### 📊 代码统计

| 指标 | 数值 |
|------|------|
| 新增文件 | 0 |
| 修改文件 | 2 |
| Index.ets 新增代码 | ~80 行 |
| EntryAbility.ets 新增代码 | ~50 行 |
| 合计净增 | ~130 行 |

---

### 🔮 待办事项

- [ ] PC 端接收程序需同步升级至 v1.1 协议（含魔数校验、确认回复、完成确认）。
- [ ] 「重试」按钮当前仅重置 UI 状态，实际重试需用户重新触发系统分享。
- [ ] 多文件传输进度目前为串行，后续可考虑并行传输优化。
