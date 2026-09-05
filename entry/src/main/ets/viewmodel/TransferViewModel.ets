/**
 * 文件传输助手 - 全局传输状态 ViewModel
 *
 * @Observed 装饰，所有属性变更均可驱动 UI 自动刷新。
 * 通过 AppStorage.setOrCreate 挂载为全局单例，
 * UI 层通过 @StorageLink('viewModel') 绑定使用。
 */

import { TransferStatus, SpeedSample } from '../model/Types';

/**
 * 全局传输状态 ViewModel。
 * 集中管理文件传输过程中的所有状态，
 * 提供 reset、updateProgress、setError 操作方法。
 */
@Observed
export class TransferViewModel {
  /**
   * 当前传输状态（默认空闲）
   */
  status: TransferStatus = TransferStatus.IDLE;

  /**
   * 正在传输的文件名
   */
  fileName: string = '';

  /**
   * 文件总大小（字节）
   */
  fileSize: number = 0;

  /**
   * 已发送字节数
   */
  sentBytes: number = 0;

  /**
   * 传输速度（字节/秒）
   */
  speed: number = 0;

  /**
   * 目标设备名称
   */
  deviceName: string = '';

  /**
   * 错误信息（当 status === FAILED 时有效）
   */
  errorMsg: string = '';

  /**
   * 速度滑动窗口（近 2 秒），元素为 SpeedSample
   * 文档 v1.1 要求：速度 = 窗口内累计字节 / 窗口时长（与 PC 端一致）
   */
  private speedWindow: SpeedSample[] = [];

  /**
   * 重置所有状态到初始值。
   * 在开始新一次传输前调用。
   */
  reset(): void {
    this.status = TransferStatus.IDLE;
    this.fileName = '';
    this.fileSize = 0;
    this.sentBytes = 0;
    this.speed = 0;
    this.deviceName = '';
    this.errorMsg = '';
    this.speedWindow = [];
  }

  /**
   * 更新传输进度。
   * 根据当前时间戳与上一次回调的差值计算瞬时速度。
   *
   * @param sent  - 当前已发送字节数
   * @param total - 文件总字节数
   */
  updateProgress(sent: number, total: number): void {
    const now: number = Date.now();

    // 记录本次进度到滑动窗口
    this.speedWindow.push(new SpeedSample(now, sent));

    // 裁剪 2 秒之前的窗口数据
    const cutoff: number = now - 2000;
    while (this.speedWindow.length > 0 && this.speedWindow[0].t < cutoff) {
      this.speedWindow.shift();
    }

    // 计算近 2 秒平均速度（bytes/s）
    if (this.speedWindow.length >= 2) {
      const first: SpeedSample = this.speedWindow[0];
      const spanSec: number = (now - first.t) / 1000;
      this.speed = spanSec > 0 ? Math.round((sent - first.cum) / spanSec) : 0;
    } else {
      // 窗口不足 2 个采样点（传输刚开始），暂不计算速度
      this.speed = 0;
    }

    this.sentBytes = sent;
    this.fileSize = total;

    // 更新状态为传输中
    if (this.status !== TransferStatus.TRANSFERRING) {
      this.status = TransferStatus.TRANSFERRING;
    }

    // 如果已发送字节数达到总大小，标记为完成
    if (sent >= total && total > 0) {
      this.status = TransferStatus.COMPLETED;
      this.speed = 0;
    }
  }

  /**
   * 设置错误状态。
   * 将 status 置为 FAILED，并记录错误信息。
   *
   * @param msg - 错误描述
   */
  setError(msg: string): void {
    this.status = TransferStatus.FAILED;
    this.errorMsg = msg;
    this.speed = 0;
  }
}

// 挂载到全局 AppStorage，UI 组件通过 @StorageLink('viewModel') 获取
AppStorage.setOrCreate('viewModel', new TransferViewModel());
