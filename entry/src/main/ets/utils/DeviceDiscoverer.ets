/**
 * 文件传输助手 - 设备发现器（mDNS）
 *
 * 通过 mDNS 扫描局域网内指定服务类型（_filetransfer._tcp）的 PC 端设备，
 * 解析出设备的 IP、端口和名称，并根据 v1.1 协议校验 TXT 版本号。
 */

import { mdns } from '@kit.NetworkKit';
import { common } from '@kit.AbilityKit';
import { BusinessError } from '@kit.BasicServicesKit';
import { DeviceInfo, ProtocolConstants } from '../model/Types';

/**
 * mDNS 设备发现工具类。
 * 封装创建、启动、停止发现服务的完整生命周期，解析结果通过回调返回 DeviceInfo。
 */
export class DeviceDiscoverer {
  /**
   * 固定服务类型：文件传输
   */
  private static readonly SERVICE_TYPE: string = '_filetransfer._tcp';

  /**
   * 预期的 TXT 记录版本号（v1.1 协议）
   */
  private static readonly EXPECTED_VERSION: string = '1.1.0';

  /**
   * TXT 记录中标识版本的键名
   */
  private static readonly VERSION_KEY: string = 'version';

  /**
   * UIAbility 上下文，用于创建 mDNS 服务
   */
  private readonly context: common.UIAbilityContext;

  /**
   * mDNS 发现服务实例
   */
  private discoveryService: mdns.DiscoveryService | null = null;

  /**
   * 当前是否正在搜索中
   */
  private isSearching: boolean = false;

  /**
   * @param context - UIAbility 上下文（从 EntryAbility 传入）
   */
  constructor(context: common.UIAbilityContext) {
    this.context = context;
  }

  /**
   * 开始发现局域网内的 PC 端设备。
   *
   * - 创建 DiscoveryService（指定 _filetransfer._tcp 类型）
   * - 订阅 serviceFound 事件
   * - 对发现的设备调用 mdns.resolveLocalService 解析完整信息
   * - 解析成功后校验 TXT 版本号，版本匹配后通过 callback 返回 DeviceInfo
   *
   * @param callback - 每发现一台设备时被调用，传入解析后的 DeviceInfo
   */
  startDiscovery(callback: (device: DeviceInfo) => void, onTimeout?: () => void): void {
    try {
      // 防止重复启动
      if (this.isSearching) {
        console.warn('DeviceDiscoverer: discovery is already running, ignoring startDiscovery');
        return;
      }

      // 发现超时保护：10 秒内未发现任何目标设备则回调 onTimeout（由调用方更新 UI）
      setTimeout(() => {
        if (this.isSearching) {
          console.warn('DeviceDiscoverer: discovery timeout, no device found');
          this.stopDiscovery();
          if (onTimeout !== undefined) {
            onTimeout();
          }
        }
      }, 10000);

      // 1. 创建 DiscoveryService
      const discoveryService: mdns.DiscoveryService = mdns.createDiscoveryService(
        this.context,
        DeviceDiscoverer.SERVICE_TYPE,
      );
      this.discoveryService = discoveryService;

      // 2. 订阅 serviceFound 事件
      discoveryService.on('serviceFound', (serviceInfo: mdns.LocalServiceInfo) => {
        console.info('DeviceDiscoverer: serviceFound, serviceName=' + serviceInfo.serviceName);
        this.handleServiceFound(serviceInfo, callback);
      });

      // 3. 订阅 discoveryStart 事件（仅用于日志监控）
      discoveryService.on('discoveryStart', (eventInfo: mdns.DiscoveryEventInfo) => {
        console.info('DeviceDiscoverer: discoveryStart, serviceType=' +
          DeviceDiscoverer.SERVICE_TYPE + ', errorCode=' + eventInfo.errorCode);
      });

      // 4. 订阅 serviceLost 事件（仅用于日志监控）
      discoveryService.on('serviceLost', (serviceInfo: mdns.LocalServiceInfo) => {
        console.info('DeviceDiscoverer: serviceLost, serviceName=' + serviceInfo.serviceName);
      });

      // 5. 启动搜索
      discoveryService.startSearchingMDNS();
      this.isSearching = true;

      console.info('DeviceDiscoverer: mDNS discovery started for type=' +
        DeviceDiscoverer.SERVICE_TYPE);
    } catch (error) {
      const bizError: BusinessError = error as BusinessError;
      console.error('DeviceDiscoverer: startDiscovery failed, errorCode=' +
        bizError.code + ', message=' + bizError.message);
      this.isSearching = false;
      this.discoveryService = null;
    }
  }

  /**
   * 停止发现服务，清理所有监听和资源。
   */
  stopDiscovery(): void {
    try {
      if (this.discoveryService === null) {
        console.warn('DeviceDiscoverer: discoveryService is null, nothing to stop');
        return;
      }

      // 1. 停止搜索
      if (this.isSearching) {
        this.discoveryService.stopSearchingMDNS();
        this.isSearching = false;
      }

      // 2. 注销所有事件监听
      this.discoveryService.off('serviceFound');
      this.discoveryService.off('serviceLost');
      this.discoveryService.off('discoveryStart');

      this.discoveryService = null;

      console.info('DeviceDiscoverer: mDNS discovery stopped');
    } catch (error) {
      const bizError: BusinessError = error as BusinessError;
      console.error('DeviceDiscoverer: stopDiscovery failed, errorCode=' +
        bizError.code + ', message=' + bizError.message);
    }
  }

  /**
   * 将 mDNS TXT 记录中的字节数组值解码为 UTF-8 字符串。
   *
   * @param bytes - TXT 记录的字节数组
   * @returns 解码后的字符串
   */
  private static decodeTxtValue(bytes: number[]): string {
    let result: string = '';
    for (const b of bytes) {
      result += String.fromCharCode(b);
    }
    return result;
  }

  /**
   * 从解析后的 mDNS 服务信息中提取 version TXT 记录值。
   *
   * @param resolvedInfo - 已解析的 mDNS 服务信息
   * @returns 版本号字符串，若未找到则返回 null
   */
  private static extractVersion(
    resolvedInfo: mdns.LocalServiceInfo,
  ): string | null {
    const attributes: mdns.ServiceAttribute[] = resolvedInfo.serviceAttribute ?? [];
    for (const attr of attributes) {
      if (attr.key === DeviceDiscoverer.VERSION_KEY) {
        return DeviceDiscoverer.decodeTxtValue(attr.value);
      }
    }
    return null;
  }

  /**
   * 从解析后的 mDNS 服务信息中提取指定 TXT 记录值。
   */
  private static extractTxt(
    resolvedInfo: mdns.LocalServiceInfo,
    key: string,
  ): string {
    const attributes: mdns.ServiceAttribute[] = resolvedInfo.serviceAttribute ?? [];
    for (const attr of attributes) {
      if (attr.key === key) {
        return DeviceDiscoverer.decodeTxtValue(attr.value);
      }
    }
    return '';
  }

  /**
   * IPv4 归一化：移除 ::ffff: 映射前缀；纯 IPv6 地址返回空（暂不支持）。
   */
  private static normalizeIpv4(address: string): string {
    if (address.startsWith('::ffff:')) {
      return address.substring('::ffff:'.length);
    }
    if (address.indexOf(':') >= 0) {
      return '';
    }
    return address;
  }

  /**
   * 处理发现的 mDNS 服务：解析服务获取完整信息，校验版本号，
   * 构造 DeviceInfo 并通过回调返回。
   *
   * @param serviceInfo - mDNS 发现的服务基本信息
   * @param callback - 上层回调
   */
  private handleServiceFound(
    serviceInfo: mdns.LocalServiceInfo,
    callback: (device: DeviceInfo) => void,
  ): void {
    // 使用 Promise 方式异步解析
    mdns.resolveLocalService(this.context, serviceInfo)
      .then((resolvedInfo: mdns.LocalServiceInfo) => {
        // ---------- 版本校验（v1.1 协议） ----------
        const version: string | null = DeviceDiscoverer.extractVersion(resolvedInfo);
        if (version === null || version !== DeviceDiscoverer.EXPECTED_VERSION) {
          console.warn('DeviceDiscoverer: version mismatch or missing, serviceName=' +
            resolvedInfo.serviceName + ', expected=' + DeviceDiscoverer.EXPECTED_VERSION +
            ', actual=' + (version ?? 'null') + ', skipping device');
          return;
        }

        // ---------- 过滤本机/手机服务（v1.2：手机自己也注册了 mDNS） ----------
        // 发送目标仅允许 PC（platform=windows / role=pc）；跳过 harmony/phone 自身
        const platform: string = DeviceDiscoverer.extractTxt(resolvedInfo, 'platform');
        const role: string = DeviceDiscoverer.extractTxt(resolvedInfo, 'role');
        const isPhoneSelf: boolean = platform === 'harmony' || role === 'phone';
        if (isPhoneSelf) {
          console.info('DeviceDiscoverer: skip self/phone service, serviceName=' +
            resolvedInfo.serviceName);
          return;
        }

        // ---------- 提取 IP 地址（IPv4 归一化） ----------
        const rawAddress: string = resolvedInfo.host?.address ?? '';
        if (rawAddress.length === 0) {
          console.warn('DeviceDiscoverer: resolved service has no host address, serviceName=' +
            resolvedInfo.serviceName);
          return;
        }
        const hostAddress: string = DeviceDiscoverer.normalizeIpv4(rawAddress);
        if (hostAddress.length === 0) {
          console.warn('DeviceDiscoverer: no IPv4 address available, serviceName=' +
            resolvedInfo.serviceName + ', raw=' + rawAddress);
          return;
        }

        // ---------- 提取端口号，无效时兜底使用 DEFAULT_PORT ----------
        const port: number = resolvedInfo.port ?? 0;
        const effectivePort: number = port > 0 ? port : ProtocolConstants.DEFAULT_PORT;
        if (port <= 0) {
          console.warn('DeviceDiscoverer: resolved service has invalid port=' + port +
            ', falling back to DEFAULT_PORT=' + ProtocolConstants.DEFAULT_PORT +
            ', serviceName=' + resolvedInfo.serviceName);
        }

        // ---------- 提取设备名称 ----------
        const deviceName: string = resolvedInfo.serviceName ?? 'Unknown';

        console.info('DeviceDiscoverer: resolved device, name=' + deviceName +
          ', ip=' + hostAddress + ', port=' + effectivePort +
          ', version=' + version + ', platform=' + platform);

        // 构造 DeviceInfo 并通过回调返回（文档 v1.1：填充 serviceType / protocolVersion）
        const device: DeviceInfo = new DeviceInfo(
          hostAddress,
          effectivePort,
          deviceName,
          DeviceDiscoverer.SERVICE_TYPE,
          version ?? undefined,
        );
        callback(device);
      })
      .catch((error: BusinessError) => {
        console.error('DeviceDiscoverer: resolveLocalService failed, serviceName=' +
          serviceInfo.serviceName + ', errorCode=' + error.code +
          ', message=' + error.message);
      });
  }
}