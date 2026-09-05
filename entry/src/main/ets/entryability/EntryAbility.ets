/**
 * 文件传输助手 - Ability 入口
 *
 * 生命周期管理：
 * - onCreate / onNewWant：接收系统分享的 Want，调用 handleShareData 异步处理
 * - onDestroy：中断传输并停止设备发现
 *
 * handleShareData 流程（v1.1 多文件支持）：
 *   want.parameters['uri']（string | string[]）→ 统一转为 URI 数组
 *       └─> 每个 URI 解析为 SharedFileInfo → 存入 AppStorage('sharedFiles')
 *       └─> DeviceDiscoverer.startDiscovery()
 *             └─> 发现设备 → 停止扫描 → 更新 ViewModel (CONNECTING)
 *             └─> TransferEngine.sendFile()（串行遍历文件列表）
 *                   ├─ 发送 v1.1 协议头 → waitForConfirm()
 *                   │     ├─ 0x01 → 分块发送文件 → waitForComplete() → 成功
 *                   │     ├─ 0x02 → Receiver rejected → FAILED + transferError
 *                   │     └─ 0x03 → Receiver timeout → FAILED + transferError
 *                   ├─ 进度回调 → 更新 sentBytes / speed
 *                   ├─ 完成 → COMPLETED（清除 transferError）
 *                   └─ 失败 → FAILED + transferError（通过 AppStorage 传递）
 */

import { AbilityConstant, UIAbility, Want, common } from '@kit.AbilityKit';
import { hilog } from '@kit.PerformanceAnalysisKit';
import { window } from '@kit.ArkUI';
import { BusinessError } from '@kit.BasicServicesKit';
import { fileIo as fs } from '@kit.CoreFileKit';
import { ShareReceiver } from '../utils/ShareReceiver';
import { DeviceDiscoverer } from '../utils/DeviceDiscoverer';
import { TransferEngine } from '../utils/TransferEngine';
import { ServiceRegistry } from '../utils/ServiceRegistry';
import { ReceiveServer } from '../utils/ReceiveServer';
import { ReceiveController } from '../utils/ReceiveController';
import { TransferViewModel } from '../viewmodel/TransferViewModel';
import { ReceiveViewModel } from '../viewmodel/ReceiveViewModel';
import { SharedFileInfo, DeviceInfo, TransferStatus, TransferErrorCode, ReceivedFile, ReceiveRequest } from '../model/Types';

const DOMAIN: number = 0x0000;
const TAG: string = 'FlashLink';

/**
 * 模块级变量：保存 EntryAbility 实例引用，供 UI 层调用公共方法。
 */
let entryAbilityInstance: EntryAbility | null = null;

export default class EntryAbility extends UIAbility {
  private discoverer: DeviceDiscoverer | null = null;
  private engine: TransferEngine | null = null;
  private pendingDevice: DeviceInfo | null = null;
  // ===== v1.2：接收侧 =====
  private receiveServer: ReceiveServer | null = null;
  private serviceRegistry: ServiceRegistry | null = null;
  private receiveVm: ReceiveViewModel = new ReceiveViewModel();

  // ================================================================
  // Ability 生命周期
  // ================================================================

  /**
   * Ability 创建时被调用（首次启动 / 系统分享唤起）
   */
  onCreate(want: Want, launchParam: AbilityConstant.LaunchParam): void {
    entryAbilityInstance = this;
    hilog.info(DOMAIN, TAG, '=== FlashLink onCreate called ===');
    hilog.info(DOMAIN, TAG, 'launchReason=%{public}s', launchParam.launchReason);
    this.logWantDetail(want);
    this.handleShareData(want).catch((error: Error) => {
      hilog.error(DOMAIN, TAG, 'handleShareData async error: %{public}s', error.message);
    });
  }

  /**
   * Ability 已在后台运行，再次收到新的 Want 时被调用（重复分享）
   */
  onNewWant(want: Want, launchParam: AbilityConstant.LaunchParam): void {
    hilog.info(DOMAIN, TAG, '=== FlashLink onNewWant called ===');
    hilog.info(DOMAIN, TAG, 'launchReason=%{public}s', launchParam.launchReason);
    this.logWantDetail(want);
    this.handleShareData(want).catch((error: Error) => {
      hilog.error(DOMAIN, TAG, 'handleShareData async error: %{public}s', error.message);
    });
  }

  /**
   * Ability 销毁时清理所有资源
   */
  onDestroy(): void {
    hilog.info(DOMAIN, TAG, 'onDestroy');
    this.stopDiscovery();
    this.abortTransfer();
    this.pendingDevice = null;
    entryAbilityInstance = null;
  }

  /**
   * 窗口创建时加载主页面
   */
  onWindowStageCreate(windowStage: window.WindowStage): void {
    hilog.info(DOMAIN, TAG, 'onWindowStageCreate');

    windowStage.loadContent('pages/Index', (err: BusinessError) => {
      if (err.code !== 0) {
        hilog.error(DOMAIN, TAG, 'loadContent failed, code=%{public}d, message=%{public}s',
          err.code, err.message);
      }
    });

    // v1.2：应用启动即开启接收服务（mDNS 注册 + TCP 监听），使 PC 能发现并发送文件
    this.startReceiveService();
  }

  // ================================================================
  // 分享数据处理（核心入口）
  // ================================================================

  /**
   * 多策略从 Want 中提取文件 URI 列表。
   *
   * 兼容性策略（按优先级）：
   * 1. want.parameters['uri'] — 传统单/多文件 key
   * 2. want.parameters['uris'] — 部分系统版本的复数 key
   * 3. systemShare.getSharedData(want) — API 12+ 新路径
   *
   * @param want - 系统分享触发的 Want 对象
   * @returns 提取到的有效 URI 数组，无数据时返回空数组
   */
  private async extractUrisFromWant(want: Want): Promise<string[]> {
    const parameters: Record<string, Object> | undefined = want.parameters;

    // 策略 1：parameters['uri']（传统路径，单文件或数组）
    if (parameters !== undefined && parameters !== null) {
      const rawUri: Object | undefined = parameters['uri'];
      if (rawUri !== undefined && rawUri !== null) {
        const rawUris: string[] = Array.isArray(rawUri)
          ? (rawUri as string[])
          : [rawUri as string];
        const valid: string[] = rawUris.filter((u: string) => u.trim().length > 0);
        if (valid.length > 0) {
          hilog.info(DOMAIN, TAG, 'extractUris: found %{public}d URIs from parameters.uri', valid.length);
          return valid;
        }
      }

      // 策略 2：parameters['uris']（部分系统使用复数 key）
      const rawUris: Object | undefined = parameters['uris'];
      if (rawUris !== undefined && rawUris !== null) {
        const urisList: string[] = Array.isArray(rawUris)
          ? (rawUris as string[])
          : [rawUris as string];
        const valid: string[] = urisList.filter((u: string) => u.trim().length > 0);
        if (valid.length > 0) {
          hilog.info(DOMAIN, TAG, 'extractUris: found %{public}d URIs from parameters.uris', valid.length);
          return valid;
        }
      }
    }

    // 策略 3：systemShare.getSharedData (API 12+)
    const sharedUris: string[] = await this.trySystemShareApi(want);
    if (sharedUris.length > 0) {
      hilog.info(DOMAIN, TAG, 'extractUris: found %{public}d URIs from systemShare API', sharedUris.length);
      return sharedUris;
    }

    hilog.info(DOMAIN, TAG, 'extractUris: all strategies failed, no URIs found');
    return [];
  }

  /**
   * 终极回退方案：遍历 want 的所有 parameters 寻找可能的 URI 值。
   * 仅在传统路径（uri / uris）都无效时调用。
   */
  private async trySystemShareApi(want: Want): Promise<string[]> {
    // 由于当前 SDK 环境可能不包含 @kit.ShareKit，
    // 此处采用保守策略：遍历 parameters 全量 key 寻找 file:// 开头的字符串
    try {
      if (want.parameters === undefined || want.parameters === null) {
        return [];
      }
      const foundUris: string[] = [];
      const keys: string[] = Object.keys(want.parameters);
      for (const key of keys) {
        const val: Object | undefined = want.parameters[key];
        if (val === undefined || val === null) {
          continue;
        }
        // 如果值是字符串且以 file:// 开头
        if (typeof val === 'string' && val.startsWith('file://')) {
          foundUris.push(val);
        } else if (Array.isArray(val)) {
          // 如果值是数组，遍历查找 file:// 开头的项
          for (const item of (val as Object[])) {
            if (typeof item === 'string' && item.startsWith('file://')) {
              foundUris.push(item);
            }
          }
        }
      }
      if (foundUris.length > 0) {
        hilog.info(DOMAIN, TAG, 'trySystemShareApi(fallback): found %{public}d URIs by scanning parameters',
          foundUris.length);
        return foundUris;
      }
      hilog.info(DOMAIN, TAG, 'trySystemShareApi(fallback): no file:// URIs found in any parameter');
      return [];
    } catch (error) {
      const bizError: BusinessError = error as BusinessError;
      hilog.info(DOMAIN, TAG, 'trySystemShareApi fallback error: %{public}s', bizError.message);
      return [];
    }
  }

  /**
   * 异步处理系统分享数据。
   * 解析 Want → 更新状态 → 发现设备 → 传输文件。
   *
   * @param want - 系统分享触发的 Want 对象
   */
  private async handleShareData(want: Want): Promise<void> {
    // 1. 清理上一次传输的残留状态
    this.stopDiscovery();
    this.abortTransfer();
    this.pendingDevice = null;

    // 2. 重置全局状态 + 清除历史错误信息
    const vm: TransferViewModel = this.getViewModel();
    vm.reset();
    AppStorage.setOrCreate('transferError', '');
    AppStorage.setOrCreate('sharedFiles', []);

    // 3. 多策略提取 URI（兼容不同系统版本和 API 路径）
    const uris: string[] = await this.extractUrisFromWant(want);
    if (uris.length === 0) {
      hilog.info(DOMAIN, TAG, 'No URIs found in want, cannot proceed');
      return;
    }
    hilog.info(DOMAIN, TAG, 'Extracted %{public}d URIs: %{public}s',
      uris.length, JSON.stringify(uris));

    // 4. 解析每个 URI 为 SharedFileInfo（文档 v1.1：附带 mimeType，来源 want.type / parameters.mimeType）
    const sharedMime: string | undefined = this.extractShareMimeType(want);
    const files: SharedFileInfo[] = [];
    for (const uri of uris) {
      try {
        const fileStat: fs.Stat = fs.statSync(uri);
        const segments: string[] = uri.split('/');
        const fileName: string = segments[segments.length - 1];
        if (fileName.trim().length > 0) {
          files.push(new SharedFileInfo(uri, fileName, fileStat.size, sharedMime));
        }
      } catch (statError) {
        const bizError: BusinessError = statError as BusinessError;
        hilog.error(DOMAIN, TAG,
          'statSync failed for uri=%{public}s, error=%{public}s',
          uri, bizError.message);
      }
    }

    if (files.length === 0) {
      hilog.info(DOMAIN, TAG, 'No valid files to transfer');
      return;
    }

    hilog.info(DOMAIN, TAG, 'Shared files received: count=%{public}d', files.length);
    for (let i: number = 0; i < files.length; i++) {
      hilog.info(DOMAIN, TAG, '  [%{public}d] name=%{public}s, size=%{public}d',
        i, files[i].name, files[i].size);
    }

    // 5. 将文件列表存入 AppStorage 驱动 UI 列表更新
    AppStorage.setOrCreate('sharedFiles', files);

    // 6. 更新 ViewModel：摘要信息 + 发现中状态
    if (files.length === 1) {
      vm.fileName = files[0].name;
      vm.fileSize = files[0].size;
    } else {
      vm.fileName = files[0].name + ' 等' + files.length + '个文件';
      vm.fileSize = files.reduce((sum: number, f: SharedFileInfo) => sum + f.size, 0);
    }
    vm.status = TransferStatus.DISCOVERING;

    // 7. 启动设备发现（异步扫描，传入文件列表）
    this.startDiscovery(files);
  }

  // ================================================================
  // 辅助：提取分享 MIME 类型（文档 v1.1 的 SharedFileInfo.mimeType）
  // ================================================================

  /**
   * 从分享 Want 中提取 MIME 类型。
   * 优先级：parameters['mimeType'] > want.type。
   *
   * @param want - 系统分享触发的 Want 对象
   * @returns MIME 类型字符串；无法提取时返回 undefined
   */
  private extractShareMimeType(want: Want): string | undefined {
    try {
      const parameters: Record<string, Object> | undefined = want.parameters;
      if (parameters !== undefined && parameters !== null) {
        const mimeObj: Object | undefined = parameters['mimeType'];
        if (mimeObj !== undefined && mimeObj !== null) {
          const mimeStr: string = mimeObj as string;
          if (mimeStr.trim().length > 0) {
            return mimeStr.trim();
          }
        }
      }
      if (want.type !== undefined && want.type !== null && want.type.trim().length > 0) {
        return want.type.trim();
      }
      return undefined;
    } catch (error) {
      const bizError: BusinessError = error as BusinessError;
      hilog.info(DOMAIN, TAG, 'extractShareMimeType error: %{public}s', bizError.message);
      return undefined;
    }
  }

  // ================================================================
  // 手动文件选择（从 UI 文件选择器触发）
  // ================================================================

  /**
   * 接收到 UI 层手动选择的文件列表，启动传输管道。
   * 与 handleShareData 流程一致，但跳过 Want 解析步骤，直接使用已解析的文件信息。
   *
   * @param files - UI 文件选择器返回的已解析文件信息列表
   */
  public async handleManualFiles(files: SharedFileInfo[]): Promise<void> {
    // 1. 清理上一次传输的残留状态
    this.stopDiscovery();
    this.abortTransfer();
    this.pendingDevice = null;

    // 2. 重置全局状态 + 清除历史错误信息
    const vm: TransferViewModel = this.getViewModel();
    vm.reset();
    AppStorage.setOrCreate('transferError', '');
    AppStorage.setOrCreate('sharedFiles', files);

    // 3. 校验文件列表
    if (files.length === 0) {
      hilog.info(DOMAIN, TAG, 'No files selected, cannot proceed');
      return;
    }
    hilog.info(DOMAIN, TAG, 'Manual file picker: %{public}d files selected', files.length);

    // 4. 启动设备发现（后续流程与系统分享一致）
    this.startDiscovery(files);
  }

  // ================================================================
  // 设备发现
  // ================================================================

  /**
   * 启动 mDNS 设备发现，找到设备后自动开始传输文件列表。
   *
   * @param files - 待传输的文件列表
   */
  private startDiscovery(files: SharedFileInfo[]): void {
    try {
      const discoverer: DeviceDiscoverer = new DeviceDiscoverer(this.context);
      this.discoverer = discoverer;

      discoverer.startDiscovery((device: DeviceInfo) => {
        hilog.info(DOMAIN, TAG, 'Device found: name=%{public}s, ip=%{public}s, port=%{public}d',
          device.name ?? 'unknown', device.ip, device.port);

        // 立即停止发现（只取第一个设备）
        this.stopDiscovery();

        // 保存设备信息并更新 UI
        this.pendingDevice = device;
        const vm: TransferViewModel = this.getViewModel();
        vm.deviceName = device.name ?? device.ip;
        vm.status = TransferStatus.CONNECTING;

        // 开始传输（传入文件列表）
        this.startTransfer(files, device);
      }, () => {
        // 发现超时：更新 UI 提示
        hilog.warn(DOMAIN, TAG, 'Device discovery timeout');
        const vm2: TransferViewModel = this.getViewModel();
        vm2.setError('未发现电脑端，请确认电脑端已启动并处于同一网络');
        AppStorage.setOrCreate('transferError', '未发现电脑端，请确认电脑端已启动并处于同一网络');
      });
    } catch (error) {
      const bizError: BusinessError = error as BusinessError;
      hilog.error(DOMAIN, TAG, 'startDiscovery failed: %{public}s', bizError.message);
      const vm: TransferViewModel = this.getViewModel();
      vm.setError('设备发现失败: ' + bizError.message);
      AppStorage.setOrCreate('transferError', bizError.message);
    }
  }

  /**
   * 停止设备发现并释放资源
   */
  private stopDiscovery(): void {
    if (this.discoverer !== null) {
      try {
        this.discoverer.stopDiscovery();
      } catch (error) {
        hilog.error(DOMAIN, TAG, 'stopDiscovery error: %{public}s',
          (error as BusinessError).message);
      } finally {
        this.discoverer = null;
      }
    }
  }

  // ================================================================
  // 文件传输
  // ================================================================

  /**
   * 向指定设备串行发送文件列表中的每个文件。
   *
   * 每个文件独立 try-catch，失败时：
   *   - 设置 FAILED 状态
   *   - 通过 AppStorage.setOrCreate('transferError', msg) 传递错误信息给 UI
   *   - 终止后续文件传输
   *
   * @param files  - 待传输文件列表
   * @param device - 目标设备
   */
  private startTransfer(files: SharedFileInfo[], device: DeviceInfo): void {
    // 创建引擎实例
    const engine: TransferEngine = new TransferEngine();
    this.engine = engine;
    const vm: TransferViewModel = this.getViewModel();

    // 使用立即执行的异步函数，避免阻塞 Ability 生命周期
    (async (): Promise<void> => {
      for (let i: number = 0; i < files.length; i++) {
        const file: SharedFileInfo = files[i];

        hilog.info(DOMAIN, TAG,
          'Transferring file [%{public}d/%{public}d]: %{public}s',
          i + 1, files.length, file.name);

        // 更新当前文件信息到 ViewModel
        vm.fileName = file.name;
        vm.fileSize = file.size;
        vm.sentBytes = 0;
        vm.speed = 0;
        vm.status = TransferStatus.TRANSFERRING;

        try {
          await engine.sendFile(device, file, (sent: number, total: number) => {
            vm.updateProgress(sent, total);
          });

          // 单个文件传输成功
          hilog.info(DOMAIN, TAG, 'File transfer succeeded: %{public}s', file.name);
        } catch (error) {
          const errMsg: string = (error as Error).message;
          hilog.error(DOMAIN, TAG,
            'File transfer failed [%{public}d/%{public}d]: %{public}s, reason=%{public}s',
            i + 1, files.length, file.name, errMsg);

          // 通过 AppStorage 传递错误信息给 UI
          AppStorage.setOrCreate('transferError', errMsg);
          vm.setError('传输失败: ' + errMsg);
          return; // 失败后不再继续传输后续文件
        }
      }

      // 所有文件传输完成
      hilog.info(DOMAIN, TAG,
        'All %{public}d files transferred successfully', files.length);
      AppStorage.setOrCreate('transferError', '');

      // sendFile 内部的 updateProgress 在 sent >= total 时会自动置为 COMPLETED
      // 但最后一个文件完成后确保状态正确
      if (vm.status !== TransferStatus.FAILED) {
        vm.status = TransferStatus.COMPLETED;
      }
    })().catch((asyncError: Error) => {
      // 顶层异步错误兜底
      hilog.error(DOMAIN, TAG,
        'startTransfer async wrapper failed: %{public}s', asyncError.message);
      AppStorage.setOrCreate('transferError', asyncError.message);
      vm.setError('传输失败: ' + asyncError.message);
    }).finally(() => {
      this.cleanupEngine();
    });
  }

  /**
   * 中止当前传输
   */
  private abortTransfer(): void {
    if (this.engine !== null) {
      try {
        this.engine.abort();
      } catch (error) {
        hilog.error(DOMAIN, TAG, 'abortTransfer error: %{public}s',
          (error as BusinessError).message);
      } finally {
        this.cleanupEngine();
      }
    }
  }

  /**
   * 调试诊断：打印收到的 Want 对象全量信息。
   * 用于排查应用是否被系统分享面板正确唤起。
   */
  private logWantDetail(want: Want): void {
    try {
      hilog.info(DOMAIN, TAG, '--- Want Detail ---');
      hilog.info(DOMAIN, TAG, 'want.action=%{public}s', want.action ?? 'undefined');
      hilog.info(DOMAIN, TAG, 'want.uri=%{public}s', want.uri ?? 'undefined');
      hilog.info(DOMAIN, TAG, 'want.type=%{public}s', want.type ?? 'undefined');
      hilog.info(DOMAIN, TAG, 'want.flags=%{public}d', want.flags ?? -1);
      if (want.entities !== undefined && want.entities !== null) {
        hilog.info(DOMAIN, TAG, 'want.entities=%{public}s', JSON.stringify(want.entities));
      } else {
        hilog.info(DOMAIN, TAG, 'want.entities=undefined');
      }
      if (want.parameters !== undefined && want.parameters !== null) {
        const keys: string[] = Object.keys(want.parameters);
        hilog.info(DOMAIN, TAG, 'want.parameters.keys=%{public}s', JSON.stringify(keys));
        // 逐个打印关键参数
        if (want.parameters['uri'] !== undefined) {
          hilog.info(DOMAIN, TAG, 'want.parameters.uri=%{public}s',
            JSON.stringify(want.parameters['uri']));
        }
        if (want.parameters['ability.focus'] !== undefined) {
          hilog.info(DOMAIN, TAG, 'want.parameters.ability.focus=%{public}s',
            JSON.stringify(want.parameters['ability.focus']));
        }
        // 打印完整 parameters（截断保护）
        const paramsStr: string = JSON.stringify(want.parameters);
        if (paramsStr.length > 1000) {
          hilog.info(DOMAIN, TAG, 'want.parameters(truncated)=%{public}s', paramsStr.substring(0, 1000) + '...(truncated)');
        } else {
          hilog.info(DOMAIN, TAG, 'want.parameters=%{public}s', paramsStr);
        }
      } else {
        hilog.info(DOMAIN, TAG, 'want.parameters=undefined');
      }
      hilog.info(DOMAIN, TAG, '--- Want Detail End ---');
    } catch (error) {
      const bizError: BusinessError = error as BusinessError;
      hilog.error(DOMAIN, TAG, 'logWantDetail error: %{public}s', bizError.message);
    }
  }

  /**
   * 清理传输引擎引用
   */
  private cleanupEngine(): void {
    this.engine = null;
  }

  // ================================================================
  // v1.2：接收服务（mDNS 注册 + TCP 监听）
  // ================================================================

  /**
   * 启动接收服务：
   * 1. ReceiveServer 监听 TCP（53321，占用自动 +1）→ 保存到 filesDir/FlashLink；
   * 2. ServiceRegistry 注册 mDNS（用实际端口），使 PC 端可发现本机。
   */
  private startReceiveService(): void {
    if (this.receiveServer !== null && this.receiveServer.isRunning()) {
      return; // 已启动
    }
    this.receiveVm = AppStorage.get<ReceiveViewModel>('receiveVM') ?? new ReceiveViewModel();

    const saveDir: string = this.context.filesDir + '/FlashLink';
    const server: ReceiveServer = new ReceiveServer(saveDir, false, {
      onRequestConfirm: (req: ReceiveRequest): void => {
        this.receiveVm.setPending(req);
        hilog.info(DOMAIN, TAG, 'incoming request from=%{public}s file=%{public}s size=%{public}d',
          req.fromAddress, req.fileName, req.fileSize);
      },
      onComplete: (file: ReceivedFile): void => {
        this.receiveVm.addRecord(file);
        hilog.info(DOMAIN, TAG, 'receive completed: %{public}s -> %{public}s', file.name, file.path);
      },
      onError: (_cid: string, msg: string): void => {
        this.receiveVm.lastError = msg;
        hilog.error(DOMAIN, TAG, 'receive error: %{public}s', msg);
      },
      onListening: (port: number): void => {
        this.receiveVm.setListening(port);
        // mDNS 注册使用实际端口
        const registry: ServiceRegistry = new ServiceRegistry(this.context);
        this.serviceRegistry = registry;
        registry.register(port).catch((err: Error) => {
          hilog.warn(DOMAIN, TAG, 'mDNS register failed: %{public}s', err.message);
        });
      },
      onListenError: (msg: string): void => {
        this.receiveVm.setListenError(msg);
        hilog.error(DOMAIN, TAG, 'receive server error: %{public}s', msg);
      }
    });
    this.receiveServer = server;
    ReceiveController.attach(server);
    server.start().catch((err: Error) => {
      hilog.error(DOMAIN, TAG, 'receive server start failed: %{public}s', err.message);
    });
  }

  private stopReceiveService(): void {
    try {
      this.serviceRegistry?.unregister();
    } catch (error) {
      hilog.warn(DOMAIN, TAG, 'unregister error');
    }
    this.serviceRegistry = null;
    try {
      this.receiveServer?.stop();
    } catch (error) {
      hilog.warn(DOMAIN, TAG, 'stop receive server error');
    }
    this.receiveServer = null;
  }

  // ================================================================
  // 辅助方法
  // ================================================================

  /**
   * 从 AppStorage 获取全局 ViewModel 实例。
   * 若尚未创建则返回新实例（仅做类型安全兜底）。
   */
  private getViewModel(): TransferViewModel {
    return AppStorage.get<TransferViewModel>('viewModel') ?? new TransferViewModel();
  }
}

/**
 * 供 UI 层（Index.ets）调用的导出函数。
 * 将手动选择的文件列表传递给 EntryAbility 实例执行传输管道。
 *
 * @param files - 从 DocumentViewPicker 选择并解析完成的 SharedFileInfo 列表
 */
export function triggerManualTransfer(files: SharedFileInfo[]): void {
  if (entryAbilityInstance !== null) {
    entryAbilityInstance.handleManualFiles(files).catch((error: Error) => {
      hilog.error(DOMAIN, TAG, 'triggerManualTransfer async error: %{public}s', error.message);
    });
  } else {
    hilog.error(DOMAIN, TAG, 'entryAbilityInstance is null, cannot start manual transfer');
  }
}