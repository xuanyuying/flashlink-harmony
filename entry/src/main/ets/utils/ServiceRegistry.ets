/**
 * 闪连互传 - mDNS 服务注册器（v1.2 新增）
 *
 * 手机端作为"可被发现方"：向局域网注册 _filetransfer._tcp 服务（API 24 mdns.addLocalService），
 * PC 端（DeviceDiscoverer）据此发现本机并发起文件发送。
 * TXT 属性: version=1.1.0, platform=harmony, role=phone, deviceId=<uuid>
 */

import { mdns } from '@kit.NetworkKit';
import { common } from '@kit.AbilityKit';
import { BusinessError } from '@kit.BasicServicesKit';

export class ServiceRegistry {
  private static readonly SERVICE_TYPE: string = '_filetransfer._tcp';
  private static readonly PROTOCOL_VERSION: string = '1.1.0';
  private readonly context: common.UIAbilityContext;
  private readonly deviceId: string;
  private serviceInfo: mdns.LocalServiceInfo | null = null;

  constructor(context: common.UIAbilityContext) {
    this.context = context;
    this.deviceId = ServiceRegistry.generateDeviceId();
  }

  /** 生成本机唯一 ID（格式：flash-<时间戳>-<随机>） */
  private static generateDeviceId(): string {
    const rand: string = Math.floor(Math.random() * 0x7fffffff).toString(16).padStart(8, '0');
    return 'flash-' + Date.now().toString(16) + '-' + rand;
  }

  getDeviceId(): string {
    return this.deviceId;
  }

  /** 将字符串编码为 TXT 字节数组（number[]） */
  private static encodeTxt(s: string): number[] {
    const bytes: number[] = [];
    for (let i = 0; i < s.length; i++) {
      bytes.push(s.charCodeAt(i) & 0xff);
    }
    return bytes;
  }

  /**
   * 注册 mDNS 服务（端口需与 ReceiveServer 实际监听端口一致）。
   */
  register(port: number): Promise<void> {
    return new Promise<void>((resolve: () => void, reject: (e: Error) => void) => {
      try {
        const info: mdns.LocalServiceInfo = {
          serviceType: ServiceRegistry.SERVICE_TYPE,
          serviceName: 'FlashLink-Phone-' + this.deviceId.slice(-6),
          port: port,
          serviceAttribute: [
            { key: 'version', value: ServiceRegistry.encodeTxt(ServiceRegistry.PROTOCOL_VERSION) },
            { key: 'platform', value: ServiceRegistry.encodeTxt('harmony') },
            { key: 'role', value: ServiceRegistry.encodeTxt('phone') },
            { key: 'deviceId', value: ServiceRegistry.encodeTxt(this.deviceId) }
          ]
        };
        this.serviceInfo = info;
        mdns.addLocalService(this.context, info).then(() => {
          console.info('ServiceRegistry: mDNS service registered on port ' + port);
          resolve();
        }).catch((err: BusinessError) => {
          console.error('ServiceRegistry: addLocalService failed code=' + err.code + ' msg=' + err.message);
          this.serviceInfo = null;
          reject(new Error('mDNS register failed: ' + err.message));
        });
      } catch (error) {
        const biz: BusinessError = error as BusinessError;
        console.error('ServiceRegistry: register exception code=' + biz.code);
        reject(new Error('mDNS register exception'));
      }
    });
  }

  /** 注销 mDNS 服务 */
  unregister(): void {
    if (this.serviceInfo !== null) {
      try {
        mdns.removeLocalService(this.context, this.serviceInfo).catch((err: BusinessError) => {
          console.error('ServiceRegistry: removeLocalService failed code=' + err.code);
        });
      } catch (error) {
        console.error('ServiceRegistry: unregister exception ' + (error as BusinessError).message);
      }
      this.serviceInfo = null;
    }
  }
}
