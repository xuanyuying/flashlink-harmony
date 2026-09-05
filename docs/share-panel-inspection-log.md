# 系统分享面板不可见 — 排查修复日志

**日期**：2026-08-28  
**应用**：闪连（FlashLink）  
**问题**：在华为手机系统分享面板（图库/文件管理器 → 分享）中找不到"闪连"选项  
**目标 SDK**：HarmonyOS NEXT API 12+，Stage 模型  

---

## 一、排查过程

### Step 1 — 检查 module.json5 配置

**检查文件**：`entry/src/main/module.json5`

**发现以下问题**：

| 检查项 | 结果 | 严重程度 |
|--------|------|----------|
| `actions` 含 `ohos.want.action.sendData` | ✅ 正确 | — |
| `scheme` 为 `file` | ✅ 正确 | — |
| `type` 为 `*/*` | ✅ 有 | — |
| 技能块在 EntryAbility 对象内 | ✅ 正确 | — |
| `exported: true` | ✅ 正确 | — |
| **`entities` 为 `entity.system.share`** | ❌ **缺失** | 🔴 致命 |
| **`ohos.want.action.sendMultipleData`** | ❌ **缺失** | 🟠 重要 |
| **`ohos.want.action.viewData`** | ❌ **缺失** | 🟡 推荐 |
| **显式 MIME 类型声明** | ❌ 仅有 `*/*` | 🟡 推荐 |

### Step 2 — 检查辅助字段

| 检查项 | 结果 | 说明 |
|--------|------|------|
| `entities` 字段 | ❌ 缺失 | **核心根因** — API 12+ Stage 模型下，系统分享面板依赖 `entity.system.share` 来识别分享目标应用 |
| `utd` 统一类型描述符 | ❌ 未使用 | API 12+ 推荐，非强制 |
| `metadata` 中 share 相关配置 | ❌ 未使用 | 部分华为机型需要 |

### Step 3 — 检查 MIME 类型声明

当前仅为 `"type": "*/*"` 单一声明。部分系统应用使用精确 MIME 匹配策略，`*/*` 可能不生效。建议同时声明常见子类型。

### Step 4 — 检查多 Ability 冲突

`extensionAbilities` 中只有 `EntryBackupAbility`（backup 类型），与分享无关，不构成冲突。

### Step 5 — 检查运行时日志

当前 `onCreate` 和 `onNewWant` 日志过于简单，仅打印 `launchReason`，无法判断 Want 的实际内容。需增强。

---

## 二、根因分析

### 🔴 核心根因：缺少 `entities: ["entity.system.share"]`

HarmonyOS NEXT（API 12+）Stage 模型下，系统分享面板使用 **Want 匹配机制** 筛选可接收分享的应用。匹配规则如下：

```
系统分享流程：
  用户点击分享 → 系统构建 Want
    → action: "ohos.want.action.sendData"
    → entities: ["entity.system.share"]    ← 系统自动添加
    → uri: file://...
  ↓
  系统遍历已安装应用的 skills 配置
    → 匹配 actions ✅
    → 匹配 entities ❌  ← 缺少此字段导致匹配失败
    → 匹配 uris ✅
  ↓
  结果：应用不显示在分享面板
```

**简单来说**：系统发给分享目标应用的 Want 中自带 `entities: ["entity.system.share"]`，但如果目标应用的 skills 中没有声明这个 entities，系统匹配时就会跳过该应用。

### 🟠 次要问题 1：缺少 `sendMultipleData`

图库/文件管理器分享**多张图片或多个文件**时，使用的 action 是 `ohos.want.action.sendMultipleData` 而非 `sendData`。缺少此 action 导致多文件分享场景下应用不出现。

### 🟡 次要问题 2：MIME 类型匹配粒度不够

部分 HarmonyOS 系统应用在构建分享 Want 时使用精确的 MIME 类型（如 `image/jpeg`），然后与目标应用的 uris 进行匹配。虽然 `*/*` 理论上可以通配，但某些系统版本的匹配逻辑存在缺陷，需要显式声明常见子类型。

---

## 三、修复内容

### 修复 1：`entry/src/main/module.json5`

**修改前**（skills 第二个块）：
```json
{
  "actions": ["ohos.want.action.sendData"],
  "uris": [{"scheme": "file", "type": "*/*"}]
}
```

**修改后**：
```json
{
  "entities": ["entity.system.share"],
  "actions": [
    "ohos.want.action.sendData",
    "ohos.want.action.sendMultipleData",
    "ohos.want.action.viewData"
  ],
  "uris": [
    {"scheme": "file", "type": "image/*"},
    {"scheme": "file", "type": "video/*"},
    {"scheme": "file", "type": "audio/*"},
    {"scheme": "file", "type": "application/*"},
    {"scheme": "file", "type": "text/*"},
    {"scheme": "file", "type": "*/*"}
  ]
}
```

**变更点**：
1. 新增 `"entities": ["entity.system.share"]` — 关键修复
2. 新增 `sendMultipleData`、`viewData` action
3. 展开为 6 条 URI 规则，覆盖常见文件类型

### 修复 2：`entry/src/main/ets/entryability/EntryAbility.ets`

**新增方法** `logWantDetail(want: Want)` — 在 `onCreate` 和 `onNewWant` 中调用。

输出内容：
- `want.action` / `want.uri` / `want.type` / `want.flags`
- `want.entities` 数组
- `want.parameters` 的所有 key
- `want.parameters['uri']` 的原始值（诊断关键）
- 完整 `want.parameters` JSON（>1000 字符时截断）

---

## 四、部署验证步骤

### 前置条件（必须执行）

```
1. 卸载旧包
   → DevEco Studio：Run → Uninstall 或 手机设置 → 应用管理 → 闪连 → 卸载

2. 重启手机（可选但强烈推荐）
   → 清除系统分享面板缓存，确保新 skills 配置被重新加载

3. 重新安装
   → DevEco Studio：Build → Build HAP(s) → 使用 Release 签名安装

4. 注意：仅修改 module.json5 后直接 "Apply Changes" 或热重载无效
   → 技能配置只在安装时注册，必须卸载重装
```

### 验证方法

```
1. 打开"图库"应用
2. 选择一张图片
3. 点击底部"分享"按钮
4. 在分享列表中查找"闪连"图标
   → 如果不在首屏，滑动到最右侧点击"更多"或"..."查看折叠区域
5. 如果能看到"闪连"，点击测试
6. 连接 DevEco Studio Log 面板，过滤 TAG=FlashLink
   → 观察是否打印 === FlashLink onCreate called ===
   → 观察 want.parameters.uri 是否包含文件 URI
```

---

## 五、若仍不可见的进一步诊断

### 场景 A：onCreate 未被调用
→ 系统根本没有唤起应用
→ 可能原因：entities 配置仍不匹配，或华为特定版本差异
→ 尝试：
  - 将 entities 改为 `["entity.system.home"]` 测试
  - 在 abilities 中增加 metadata：
    ```json
    "metadata": [{"name": "ohos.ability.share", "value": "true"}]
    ```
  - 检查是否有 `ohos.permission.SHARE` 或 `ohos.permission.READ_MEDIA` 权限缺失

### 场景 B：onCreate 被调用但 uri 为 undefined
→ 系统使用新 API（`systemShare.getSharedData`）传递数据
→ 需要在 handleShareData 中补充：
  ```typescript
  import { systemShare } from '@kit.ShareKit';

  if (want.parameters?.['uri'] === undefined) {
    try {
      const data = await systemShare.getSharedData(want);
      data.getRecords().forEach(record => {
        hilog.info(DOMAIN, TAG, 'SharedData record: %{public}s', record.uri);
      });
    } catch (e) {
      hilog.error(DOMAIN, TAG, 'getSharedData failed');
    }
  }
  ```

### 场景 C：Debug 包不出现，Release 包正常
→ 部分华为机型限制 Debug 签名应用出现在系统分享面板
→ 改用 Release 签名构建 HAP

### 场景 D：特定华为机型差异
→ 不同机型（Mate 60 / P60 / nova）分享面板实现有差异
→ 建议在多个机型上交叉测试

---

## 六、修改文件清单

| 文件 | 修改类型 | 说明 |
|------|----------|------|
| `entry/src/main/module.json5` | 修改 | 新增 entities、actions、扩展 uris |
| `entry/src/main/ets/entryability/EntryAbility.ets` | 修改 | 新增 logWantDetail 诊断方法 |

---

## 七、追加修复记录（2026-08-28 第二轮修复）

前次修复完成后，经代码审查发现以下 **4 个遗漏问题**并已补修。

### 修复 3：`module.json5` — 补充华为兼容性 metadata

| 字段 | 值 | 说明 |
|------|-----|------|
| `abilities[0].metadata[0].name` | `ohos.ability.share.target` | 华为部分机型需要该元数据显式标记为分享目标 |
| `abilities[0].metadata[0].value` | `"true"` | |

### 修复 4：`module.json5` — 补充文件读取权限

| 权限 | reason | 说明 |
|------|--------|------|
| `ohos.permission.READ_MEDIA` | `$string:permission_read_media_reason` | 读取图片/视频/音频文件 |
| `ohos.permission.READ_DOCUMENT` | `$string:permission_read_document_reason` | 读取文档文件 |

### 修复 5：`resources/base/element/string.json` — 新增权限说明

新增两条字符串资源：
- `permission_read_media_reason` = "用于读取分享的图片、视频、音频文件以进行传输"
- `permission_read_document_reason` = "用于读取分享的文档文件以进行传输"

### 修复 6：`EntryAbility.ets` — 多策略 URI 提取

**原逻辑**（单一路径）：
```
检查 parameters['uri'] → 发现 undefined → 直接 return
```

**新逻辑**（三级降级策略）：
```
策略 1: parameters['uri']        → 传统单/多文件 key
策略 2: parameters['uris']       → 部分系统复数 key（新增）
策略 3: 全量 parameters 扫描     → 遍历所有 key 找 file:// 开头的值（新增）
```

### 修复 7：`EntryAbility.ets` — `onCreate`/`onNewWant` 异步安全调用

原代码直接 `this.handleShareData(want)`，修改为：
```typescript
this.handleShareData(want).catch((error: Error) => {
  hilog.error(DOMAIN, TAG, 'handleShareData async error: %{public}s', error.message);
});
```

---

## 八、最终修复清单总表

| # | 文件 | 变更内容 | 重要性 |
|---|------|----------|--------|
| 1 | `module.json5` | 新增 `entities: ["entity.system.share"]` | 🔴 致命 |
| 2 | `module.json5` | 新增 `sendMultipleData`、`viewData` 动作 | 🟠 重要 |
| 3 | `module.json5` | 展开 6 条 URI 规则（image/video/audio/application/text/*/*） | 🟡 推荐 |
| 4 | `module.json5` | 新增 `metadata: ohos.ability.share.target=true` | 🟠 华为机型 |
| 5 | `module.json5` | 新增 `READ_MEDIA`、`READ_DOCUMENT` 权限 | 🟠 文件访问 |
| 6 | `string.json` | 新增 2 条权限说明字符串 | 🟠 必须 |
| 7 | `EntryAbility.ets` | 新增 `extractUrisFromWant()` 三级 URI 提取策略 | 🟠 兼容性 |
| 8 | `EntryAbility.ets` | 新增 `trySystemShareApi()` 全量 parameters 扫描替补 | 🟡 兜底 |
| 9 | `EntryAbility.ets` | 新增 `logWantDetail()` 完整 Want 诊断日志 | 🟢 调试 |
| 10 | `EntryAbility.ets` | `onCreate`/`onNewWant` 异步 `.catch()` 安全调用 | 🟢 健壮性 |

---

*日志最终版本：v2.0 — 涵盖全部 7 项修复*

