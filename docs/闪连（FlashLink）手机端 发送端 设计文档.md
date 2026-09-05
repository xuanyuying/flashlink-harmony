# 闪连（FlashLink）手机端 发送端 设计文档

> 版本：v1.0.0  
> 更新日期：2026-08-27  
> 开发平台：HarmonyOS NEXT（API 12+）  
> 开发语言：ArkTS（Stage 模型）

---

## 1. 引言

### 1.1 项目背景

本项目旨在开发一款鸿蒙（HarmonyOS NEXT）手机端应用，实现用户通过系统分享功能将文件发送到同一局域网内的电脑端。应用接收系统分享的文件后，通过 mDNS 自动发现电脑端服务，建立 TCP 连接完成文件传输。

### 1.2 项目目标

- 接收系统分享面板传递的文件 URI
- 通过 mDNS 自动发现局域网内的电脑端服务
- 建立 TCP Socket 连接，按约定协议传输文件
- 提供传输进度和状态反馈

### 1.3 适用范围

本设计文档适用于 HarmonyOS NEXT（API 12 及以上版本）应用开发，使用 DevEco Studio 作为开发工具，采用 ArkTS 语言和 Stage 模型。

---

## 2. 总体架构

### 2.1 架构分层

```
┌─────────────────────────────────────────────────────┐
│                     UI 层                            │
│  ┌──────────────┐  ┌──────────────┐  ┌───────────┐ │
│  │  主页面       │  │  传输进度页   │  │  设备列表  │ │
│  └──────────────┘  └──────────────┘  └───────────┘ │
├─────────────────────────────────────────────────────┤
│                   业务逻辑层                         │
│  ┌──────────────┐  ┌──────────────┐  ┌───────────┐ │
│  │  分享接收器   │  │  设备发现器   │  │  传输引擎  │ │
│  │ (ShareReceiver)│  │(DeviceDiscoverer)│ │(TransferEngine)│
│  └──────────────┘  └──────────────┘  └───────────┘ │
├─────────────────────────────────────────────────────┤
│                   基础能力层                         │
│  ┌──────────────┐  ┌──────────────┐  ┌───────────┐ │
│  │  CoreFileKit │  │  NetworkKit  │  │  Socket   │ │
│  │  (文件操作)   │  │  (mDNS)      │  │  (TCP)    │ │
│  └──────────────┘  └──────────────┘  └───────────┘ │
└─────────────────────────────────────────────────────┘
```

### 2.2 核心模块

| 模块名称 | 职责 |
|----------|------|
| ShareReceiver | 接收系统分享的 Want，解析文件 URI |
| DeviceDiscoverer | 通过 mDNS 发现局域网内的电脑端服务 |
| TransferEngine | 建立 TCP 连接，执行文件发送 |
| ProgressManager | 管理传输进度和状态 |

---

## 3. 模块详细设计

### 3.1 分享接收模块 (ShareReceiver)

#### 3.1.1 功能描述

接收其他应用通过系统分享面板传递的文件数据，获取文件的 URI 和元信息。

#### 3.1.2 配置文件声明

在 `module.json5` 中声明接收分享的能力：

```json
{
  "module": {
    "abilities": [
      {
        "name": "EntryAbility",
        "skills": [
          {
            "actions": [
              "ohos.want.action.sendData"
            ],
            "uris": [
              {
                "scheme": "file",
                "type": "*/*"
              }
            ]
          }
        ]
      }
    ]
  }
}
```

`ohos.want.action.sendData` 用于接收被分享方应用传递的单个数据记录。`uris` 字段声明本应用接收所有 `file` 类型的文件 URI。

#### 3.1.3 数据处理流程

在 `EntryAbility` 的 `onCreate()` 或 `onNewWant()` 回调中处理分享数据：

```typescript
// EntryAbility.ets
import { UIAbility } from '@kit.AbilityKit';
import { Want } from '@kit.AbilityKit';
import { fileIo as fs } from '@kit.CoreFileKit';

export default class EntryAbility extends UIAbility {
  onCreate(want: Want, launchParam: AbilityConstant.LaunchParam): void {
    // 解析分享数据
    this.handleShareData(want);
  }

  onNewWant(want: Want, launchParam: AbilityConstant.LaunchParam): void {
    this.handleShareData(want);
  }

  private handleShareData(want: Want): void {
    // 获取分享的文件 URI
    const uri = want.parameters?.['uri'] as string;
    if (uri) {
      // 获取文件信息
      const stat = fs.statSync(uri);
      const fileName = uri.split('/').pop() || 'unknown';
      // 将文件信息传递给 UI 层，触发传输流程
      AppStorage.setOrCreate('sharedFileUri', uri);
      AppStorage.setOrCreate('sharedFileName', fileName);
      AppStorage.setOrCreate('sharedFileSize', stat.size);
    }
  }
}
```

> **说明**：HarmonyOS NEXT 中跨应用文件传递通过 CoreFileKit 的 URI 机制实现，接收方通过 `fs.openSync` 读取文件内容。

---

### 3.2 设备发现模块 (DeviceDiscoverer)

#### 3.2.1 功能描述

通过 mDNS（多播 DNS）在局域网内发现电脑端注册的服务，获取其 IP 地址和端口号。

#### 3.2.2 技术方案

使用 `@kit.NetworkKit` 中的 `mdns` 命名空间创建发现服务：

```typescript
// DeviceDiscoverer.ets
import { mdns } from '@kit.NetworkKit';
import { BusinessError } from '@kit.BasicServicesKit';
import { common } from '@kit.AbilityKit';

export class DeviceDiscoverer {
  private discoveryService: mdns.DiscoveryService | null = null;
  private context: common.UIAbilityContext;
  private readonly SERVICE_TYPE = '_filetransfer._tcp';

  constructor(context: common.UIAbilityContext) {
    this.context = context;
  }

  startDiscovery(onDeviceFound: (ip: string, port: number) => void): void {
    // 创建 DiscoveryService 对象
    this.discoveryService = mdns.createDiscoveryService(
      this.context,
      this.SERVICE_TYPE
    );

    // 订阅服务发现事件
    this.discoveryService.on('serviceFound', (data: mdns.LocalServiceInfo) => {
      // 解析服务获取 IP 地址
      mdns.resolveLocalService(this.context, data, (error, resolveData) => {
        if (!error && resolveData.host) {
          onDeviceFound(resolveData.host.address, resolveData.port);
        }
      });
    });

    // 订阅服务丢失事件
    this.discoveryService.on('serviceLost', (data: mdns.LocalServiceInfo) => {
      // 通知 UI 设备已离线
    });

    // 开始搜索
    this.discoveryService.startSearchingMDNS();
  }

  stopDiscovery(): void {
    if (this.discoveryService) {
      this.discoveryService.stopSearchingMDNS();
      this.discoveryService.off('serviceFound');
      this.discoveryService.off('serviceLost');
      this.discoveryService = null;
    }
  }
}
```

#### 3.2.3 服务类型约定

手机端与电脑端约定统一的 mDNS 服务类型：`_filetransfer._tcp`。

---

### 3.3 文件传输引擎 (TransferEngine)

#### 3.3.1 功能描述

建立 TCP Socket 连接，按照约定的协议格式将文件数据发送给电脑端。

#### 3.3.2 传输协议设计

采用二进制协议格式：

```
[2字节文件名长度][文件名(UTF-8)][4字节文件大小][文件内容]
```

| 字段 | 长度 | 编码 |
|------|------|------|
| 文件名长度 | 2 字节 | 无符号整数（大端序） |
| 文件名 | 可变 | UTF-8 编码 |
| 文件大小 | 4 字节 | 无符号整数（大端序） |
| 文件内容 | 可变 | 原始二进制数据 |

#### 3.3.3 核心实现

```typescript
// TransferEngine.ets
import { socket } from '@kit.NetworkKit';
import { fileIo as fs } from '@kit.CoreFileKit';

export class TransferEngine {
  private tcpSocket: socket.TCPSocket | null = null;
  private isSending: boolean = false;

  async sendFile(
    serverIp: string,
    serverPort: number,
    fileUri: string,
    fileName: string,
    fileSize: number,
    onProgress: (sent: number, total: number) => void
  ): Promise<void> {
    if (this.isSending) {
      throw new Error('Already sending');
    }
    this.isSending = true;

    try {
      // 1. 创建并连接 TCP Socket
      const netAddress: socket.NetAddress = {
        address: serverIp,
        port: serverPort,
        family: 1 // IPv4
      };
      this.tcpSocket = socket.constructTCPSocketInstance();
      await this.tcpSocket.connect(netAddress);

      // 2. 打开文件
      const file = await fs.open(fileUri, fs.OpenMode.READ_ONLY);

      // 3. 发送文件头
      const fileNameBytes = new TextEncoder().encode(fileName);
      const header = new ArrayBuffer(2 + fileNameBytes.length + 4);
      const view = new DataView(header);
      let offset = 0;
      // 文件名长度（2字节，大端序）
      view.setUint16(offset, fileNameBytes.length);
      offset += 2;
      // 文件名
      new Uint8Array(header, offset, fileNameBytes.length).set(fileNameBytes);
      offset += fileNameBytes.length;
      // 文件大小（4字节，大端序）
      view.setUint32(offset, fileSize);
      await this.tcpSocket.send({ data: header });

      // 4. 分块发送文件内容
      const CHUNK_SIZE = 1024 * 1024; // 1MB
      let totalSent = 0;
      const buffer = new ArrayBuffer(CHUNK_SIZE);

      while (totalSent < fileSize) {
        const bytesRead = await fs.read(file.fd, buffer, {
          offset: totalSent,
          length: Math.min(CHUNK_SIZE, fileSize - totalSent)
        });
        if (bytesRead <= 0) break;
        const chunk = buffer.slice(0, bytesRead);
        await this.tcpSocket.send({ data: chunk });
        totalSent += bytesRead;
        onProgress(totalSent, fileSize);
      }

      // 5. 关闭资源
      await fs.close(file);
      await this.tcpSocket.close();
      this.tcpSocket = null;

    } finally {
      this.isSending = false;
    }
  }

  abort(): void {
    if (this.tcpSocket) {
      this.tcpSocket.close();
      this.tcpSocket = null;
    }
    this.isSending = false;
  }
}
```

#### 3.3.4 注意事项

- **线程处理**：文件传输为耗时操作，必须在 Worker 或 TaskPool 中执行，不能在 UI 线程操作。
- **超时处理**：大文件发送时 send 方法可能因发送缓冲区满而阻塞，需设置超时。
- **分块大小**：建议 1MB 作为分块大小，平衡内存占用和传输效率。

---

### 3.4 进度管理模块 (ProgressManager)

#### 3.4.1 功能描述

管理文件传输的进度状态，通过 `@State` 或 `AppStorage` 驱动 UI 更新。

#### 3.4.2 状态定义

```typescript
// ProgressManager.ets
export enum TransferStatus {
  IDLE = 'idle',
  DISCOVERING = 'discovering',
  CONNECTING = 'connecting',
  TRANSFERRING = 'transferring',
  COMPLETED = 'completed',
  FAILED = 'failed'
}

export interface TransferProgress {
  status: TransferStatus;
  fileName: string;
  fileSize: number;
  sentBytes: number;
  speed: number; // bytes per second
  errorMessage?: string;
}
```

---

## 4. 接口设计

### 4.1 UI 交互流程

1. 用户在其他应用中选择文件，点击「分享」
2. 在分享面板中选择本应用
3. 应用自动启动，进入传输页面
4. 自动开始 mDNS 设备发现
5. 发现电脑端后自动建立连接并开始传输
6. 传输完成或失败时给出明确提示

### 4.2 页面设计

| 页面 | 功能 |
|------|------|
| 主页面 | 显示「等待分享文件」提示，展示已接收的文件信息 |
| 传输页面 | 显示设备发现状态、传输进度条、文件名、传输速度 |
| 完成页面 | 显示「传输完成」或「传输失败」状态 |

---

## 5. 数据模型

### 5.1 文件信息

```typescript
interface SharedFileInfo {
  uri: string;        // 文件 URI
  name: string;       // 文件名
  size: number;       // 文件大小（字节）
  mimeType?: string;  // MIME 类型
}
```

### 5.2 设备信息

```typescript
interface DeviceInfo {
  name: string;       // 设备名称
  ip: string;         // IP 地址
  port: number;       // 服务端口
  serviceType: string; // mDNS 服务类型
}
```

---

## 6. 异常处理

| 异常场景 | 处理方式 |
|----------|----------|
| 未获取到分享文件 URI | 提示用户重新分享 |
| mDNS 未发现设备 | 显示「未发现电脑端，请确认电脑端已启动」 |
| TCP 连接超时 | 重试 3 次，失败后提示检查网络 |
| 文件读取失败 | 提示文件不存在或权限不足 |
| 传输中断 | 记录已传输进度，支持断点续传（进阶功能） |

---

## 7. 性能与安全

### 7.1 性能优化

- 使用 1MB 分块传输，避免内存溢出
- 异步 I/O 操作，不阻塞主线程
- 使用 TaskPool 处理大文件传输
- 传输过程中及时释放文件句柄和 Socket 资源

### 7.2 安全考虑

- 仅在同一局域网内传输，不经过公网
- 文件 URI 通过系统分享机制传递，具有沙箱隔离
- 不存储用户文件，传输完成后清理临时数据
- 传输前无需额外认证，依赖局域网物理隔离

---

## 8. 开发环境与依赖

| 项目 | 版本 |
|------|------|
| DevEco Studio | 5.0.0 及以上 |
| HarmonyOS SDK | API 12 及以上 |
| 开发语言 | ArkTS |
| 应用模型 | Stage 模型 |
| 核心 Kit | CoreFileKit, NetworkKit, AbilityKit |

---

> **文档版本历史**

| 版本 | 日期 | 变更说明 |
|------|------|----------|
| v1.0.0 | 2026-08-27 | 初始版本，完成整体架构与模块设计 |
