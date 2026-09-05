# FlashLink · 闪连

> 📡 鸿蒙手机端文件传输助手 — 接收系统分享，通过局域网极速传送到 PC 端

[![HarmonyOS](https://img.shields.io/badge/HarmonyOS-NEXT-0078D7?style=flat-square)](https://developer.harmonyos.com/)
[![API](https://img.shields.io/badge/API-12+-blueviolet?style=flat-square)](https://developer.harmonyos.com/)
[![License](https://img.shields.io/badge/License-MIT-green?style=flat-square)](LICENSE)

---

## 📖 简介

**FlashLink（闪连）** 是一款基于 HarmonyOS NEXT 开发的文件传输工具。它集成在系统分享面板中，当你从任意应用分享文件时，FlashLink 会被唤起并自动扫描局域网内的 PC 接收端（通过 mDNS 发现），建立 TCP Socket 连接完成文件传输。整个过程中手机无需数据线，无需手动输入 IP 地址。

> 💡 **设计理念**：零配置、极速传输、资源安全释放

---

## ✨ 功能特性

| 特性 | 说明 |
|------|------|
| 🎯 **系统分享集成** | 注册 `ohos.want.action.sendData` Skill，可从任意应用（图库、文件管理器等）接收文件 |
| 📡 **mDNS 自动发现** | 扫描局域网内 `_filetransfer._tcp` 服务类型，自动发现 PC 接收端，无需手动配 IP |
| 🔒 **安全 TCP 传输** | 基于 Socket 直连，传输内容不经过第三方服务器 |
| 📊 **实时进度反馈** | 显示文件名、文件大小、传输进度条、实时速度（KB/s / MB/s） |
| 🧩 **模块化架构** | ShareReceiver → DeviceDiscoverer → TransferEngine → ViewModel，职责清晰，资源安全释放 |
| 🔌 **即插即用** | 安装后通过系统分享即可使用，无需打开应用主界面 |

---

## 🏗️ 架构设计

```
┌─────────────────────────────────────────────────────────┐
│                    系统分享面板                           │
│              (ohos.want.action.sendData)                │
└─────────────────────┬───────────────────────────────────┘
                      │ Want 对象
                      ▼
┌─────────────────────────────────────────────────────────┐
│  EntryAbility                                           │
│  ├─ onCreate / onNewWant → handleShareData(want)        │
│  └─ 协调各模块工作流                                     │
└──┬──────────────┬──────────────┬────────────────────────┘
   │              │              │
   ▼              ▼              ▼
┌─────────┐ ┌────────────┐ ┌───────────────┐
│Share    │ │Device      │ │Transfer       │
│Receiver │ │Discoverer  │ │Engine         │
│         │ │(mDNS)      │ │(TCP Socket)   │
│解析 Want│ │发现 PC 设备│ │发送二进制协议 │
│提取文件 │ │_filetrans- │ │[头+数据流]    │
│信息     │ │fer._tcp    │ │进度回调       │
└─────────┘ └────────────┘ └───────────────┘
      │              │              │
      └──────────────┴──────────────┘
                     │
                     ▼
┌─────────────────────────────────────────────────────────┐
│  TransferViewModel (全局状态管理)                        │
│  @Observed + AppStorage 驱动 UI 自动刷新                │
│  状态: IDLE → DISCOVERING → CONNECTING →                │
│        TRANSFERRING → COMPLETED / FAILED                │
└─────────────────────────────────────────────────────────┘
```

### 通信协议（二进制）

```
[2字节 文件名长度(大端Uint16)] +
[文件名 UTF-8 字节] +
[4字节 文件大小(大端Uint32)] +
[文件原始二进制流 (分块发送, 每块 1MB)]
```

---

## 📁 项目结构

```
FlashLink/
├── AppScope/
│   └── app.json5                      # 应用配置 (bundleName, version 等)
├── art/                               # 图标资源
├── entry/
│   └── src/main/
│       ├── ets/
│       │   ├── model/
│       │   │   └── Types.ets          # 数据模型 (DeviceInfo, SharedFileInfo, TransferStatus)
│       │   ├── utils/
│       │   │   ├── ShareReceiver.ets  # 系统分享解析
│       │   │   ├── DeviceDiscoverer.ets # mDNS 设备发现
│       │   │   └── TransferEngine.ets # TCP Socket 传输引擎
│       │   ├── viewmodel/
│       │   │   └── TransferViewModel.ets # 全局状态管理
│       │   ├── entryability/
│       │   │   └── EntryAbility.ets   # Ability 入口，协调工作流
│       │   └── pages/
│       │       └── Index.ets          # 主页面 UI
│       ├── resources/                 # 国际化资源
│       └── module.json5               # 模块配置 (权限、Skill)
├── oh-package.json5
├── build-profile.json5                # 构建配置 (签名信息)
├── CHANGELOG.md                       # 变更日志
└── README.md                          # 本文件
```

---

## 🚀 快速开始

### 前置条件

- 设备：HarmonyOS NEXT 手机（API 12+）
- 电脑：局域网内的 PC 端（需运行对应的 TCP 接收服务端程序，监听 `_filetransfer._tcp` 服务）

### 安装方式

#### 方式一：直接安装 HAP（推荐）

1. 从 [Releases](https://github.com/xuanyuying/FlashLink-hap/releases) 页面下载最新版本的 `entry-default-signed.hap`
2. 将 HAP 文件传输到手机上
3. 在手机上打开文件管理器，点击 HAP 文件进行安装
4. 安装完成后，FlashLink 将出现在应用列表中

#### 方式二：通过 DevEco Studio 构建安装

```bash
# 克隆仓库
git clone https://github.com/xuanyuying/FlashLink-hap.git

# 使用 DevEco Studio 打开项目
# 配置签名 → 构建 → 运行到真机
```

### 使用流程

1. **确保 PC 端运行接收服务**：PC 端需启动支持 `_filetransfer._tcp` 的 TCP 服务端
2. **从任意应用分享文件**：
   - 在图库中选择照片 → 点击「分享」→ 选择「闪连」
   - 或在文件管理器中选择文件 → 点击「分享」→ 选择「闪连」
3. **自动传输**：应用自动扫描 PC 端 → 建立连接 → 传输文件 → 完成

---

## 🛠️ 技术栈

| 技术 | 用途 |
|------|------|
| ArkTS | 应用开发语言（严格模式） |
| ArkUI | 声明式 UI 框架 |
| `@kit.CoreFileKit` (fileIo) | 文件读取操作 |
| `@kit.NetworkKit` (socket) | TCP Socket 传输 |
| `@kit.NetworkKit` (mdns) | mDNS 局域网设备发现 |
| `@kit.AbilityKit` | Ability 生命周期 & 系统分享 Want |
| `@Observed` / `@StorageLink` | 全局状态管理 & UI 自动刷新 |

---

## 📜 变更日志

详见 [CHANGELOG.md](./CHANGELOG.md)

### 版本历史

| 版本 | 日期 | 说明 |
|------|------|------|
| v1.0.0 | 2026-08-27 | 初始版本：系统分享接收、mDNS 设备发现、TCP 文件传输 |

---

## 🔒 权限说明

| 权限 | 用途 |
|------|------|
| `ohos.permission.INTERNET` | 建立局域网 TCP Socket 连接 |

---

## 🧪 开发与构建

```bash
# 构建 HAP（Debug）
hvigorw assembleHap

# 构建 HAP（Release）
hvigorw assembleHap --mode module -p product=default --release

# 运行到设备
hvigorw run
```

---

## 🤝 贡献指南

欢迎提交 Issue 和 Pull Request 来帮助改进 FlashLink！

1. Fork 本仓库
2. 创建你的特性分支 (`git checkout -b feature/amazing-feature`)
3. 提交你的修改 (`git commit -m 'feat: add amazing feature'`)
4. 推送到分支 (`git push origin feature/amazing-feature`)
5. 提交 Pull Request

---

## 📄 许可证

本项目基于 MIT 许可证开源 — 详见 [LICENSE](LICENSE) 文件

---

## 📬 联系方式

- 项目主页：[https://github.com/xuanyuying/FlashLink-hap](https://github.com/xuanyuying/FlashLink-hap)
- 作者：[@xuanyuying](https://github.com/xuanyuying)

---

<p align="center">Made with ❤️ for HarmonyOS NEXT</p>
