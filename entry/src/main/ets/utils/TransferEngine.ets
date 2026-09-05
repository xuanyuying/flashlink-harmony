/**
 * 文件传输助手 - 传输引擎（TCP Socket）
 *
 * 负责与 PC 端建立 TCP 连接，
 * 按照 v1.1 二进制协议发送文件头 + 文件内容，
 * 并通过回调实时上报传输进度。
 *
 * v1.1 协议格式（Header）：
 *   [2字节魔数 0x464C(大端Uint16)] +
 *   [1字节协议版本 0x01(Uint8)] +
 *   [1字节保留字段 0x00(Uint8)] +
 *   [2字节文件名长度(大端Uint16)] +
 *   [文件名UTF-8字节] +
 *   [8字节文件大小(大端Uint64, 高32位+低32位)] +
 *   [文件原始二进制流]
 */

import { socket } from '@kit.NetworkKit';
import { fileIo as fs } from '@kit.CoreFileKit';
import { util } from '@kit.ArkTS';
import { BusinessError } from '@kit.BasicServicesKit';
import { DeviceInfo, SharedFileInfo, ProtocolConstants } from '../model/Types';

/**
 * TCP Socket 连接超时时间：10 秒
 */
const CONNECT_TIMEOUT_MS: number = 10000;

/**
 * 传输引擎。
 * 管理单个 TCP 连接的生命周期，支持按块发送文件及中断传输。
 */
export class TransferEngine {
  /**
   * TCP Socket 实例
   */
  private tcpSocket: socket.TCPSocket | null = null;

  /**
   * 是否已建立连接
   */
  private isConnected: boolean = false;

  /**
   * 是否被用户主动中止
   */
  private isAborted: boolean = false;

  /**
   * 等待接收端确认过程中，存储 Promise reject 函数引用，
   * 供 abort() 调用以立即中断等待，避免等待超时。
   */
  private waitingReject: ((reason: Error) => void) | null = null;

  /**
   * 发送文件到指定设备。
   *
   * @param device  - 目标设备（IP + 端口）
   * @param fileInfo - 待发送的文件元信息
   * @param onProgress - 进度回调 (已发送字节数, 文件总字节数)
   * @throws 传输失败或中断时抛出 BusinessError / Error
   */
  async sendFile(
    device: DeviceInfo,
    fileInfo: SharedFileInfo,
    onProgress: (sent: number, total: number) => void,
  ): Promise<void> {
    this.isAborted = false;

    let fileHandle: fs.File | null = null;

    try {
      // ============================================================
      // 1. 创建并连接 TCP Socket
      // ============================================================
      console.info('TransferEngine: connecting to ' + device.ip + ':' + device.port);

      this.tcpSocket = socket.constructTCPSocketInstance();

      const netAddress: socket.NetAddress = {
        address: device.ip,
        port: device.port,
        family: 1, // IPv4
      };

      const connectOptions: socket.TCPConnectOptions = {
        address: netAddress,
        timeout: CONNECT_TIMEOUT_MS,
      };

      await this.tcpSocket.connect(connectOptions);
      this.isConnected = true;
      console.info('TransferEngine: connected to ' + device.ip + ':' + device.port);

      // ============================================================
      // 2. 构建并发送协议头
      // ============================================================
      const headerBuffer: ArrayBuffer = this.buildProtocolHeader(fileInfo);
      const headerOptions: socket.TCPSendOptions = { data: headerBuffer };
      await this.tcpSocket.send(headerOptions);
      console.info('TransferEngine: protocol header sent, fileName=' +
        fileInfo.name + ', fileSize=' + fileInfo.size);

      // ============================================================
      // 3. 等待接收端确认（v1.1 协议）
      // ============================================================
      const confirmByte: number = await this.waitForConfirm();
      console.info('TransferEngine: confirmByte=0x' +
        confirmByte.toString(16).padStart(2, '0'));

      if (confirmByte === 0x02) {
        throw new Error('TransferEngine: receiver rejected the file transfer');
      } else if (confirmByte === 0x03) {
        throw new Error('TransferEngine: receiver confirm timeout');
      }
      // confirmByte === 0x01 → 继续传输

      // ============================================================
      // 4. 打开文件并分块发送
      // ============================================================
      fileHandle = fs.openSync(fileInfo.uri, fs.OpenMode.READ_ONLY);
      const fd: number = fileHandle.fd;
      const totalSize: number = fileInfo.size;
      let totalSent: number = 0;

      // 回调通知初始状态（0 已发送）
      onProgress(totalSent, totalSize);

      while (totalSent < totalSize) {
        // 检查是否被用户中止
        if (this.isAborted) {
          throw new Error('TransferEngine: transfer aborted by user');
        }

        const remaining: number = totalSize - totalSent;
        const chunkSize: number = Math.min(ProtocolConstants.CHUNK_SIZE, remaining);
        const chunkBuffer: ArrayBuffer = new ArrayBuffer(chunkSize);

        // 从文件读取一个分块
        const bytesRead: number = fs.readSync(fd, chunkBuffer, {
          offset: totalSent,
          length: chunkSize,
        });

        if (bytesRead <= 0) {
          // 读取到文件末尾（理论上不应在 totalSent < totalSize 时发生）
          console.warn('TransferEngine: read file returned 0 bytes, breaking early');
          break;
        }

        // 发送分块数据
        const actualData: ArrayBuffer =
          bytesRead === chunkBuffer.byteLength
            ? chunkBuffer
            : chunkBuffer.slice(0, bytesRead);

        const sendOptions: socket.TCPSendOptions = { data: actualData };
        await this.tcpSocket.send(sendOptions);

        totalSent += bytesRead;

        // 回调通知进度
        onProgress(totalSent, totalSize);
      }

      console.info('TransferEngine: file data sent, totalSent=' + totalSent +
        ', totalSize=' + totalSize);

      // ============================================================
      // 5. 等待接收端完成确认（v1.1 协议）
      // ============================================================
      await this.waitForComplete();

      console.info('TransferEngine: transfer fully completed, fileName=' +
        fileInfo.name);
    } catch (error) {
      const bizError: BusinessError = error as BusinessError;
      console.error('TransferEngine: sendFile failed, code=' + bizError.code +
        ', message=' + bizError.message);
      throw new Error(bizError.message);
    } finally {
      // ============================================================
      // 4. 资源释放（红线：必须执行）
      // ============================================================
      // 4a. 关闭文件句柄
      if (fileHandle !== null) {
        try {
          fs.closeSync(fileHandle);
          console.info('TransferEngine: file handle closed');
        } catch (closeFileError) {
          console.error('TransferEngine: failed to close file, error=' +
            (closeFileError as BusinessError).message);
        }
      }

      // 4b. 关闭 Socket 并清理
      await this.cleanupSocket();
    }
  }

  /**
   * 主动中止当前传输。
   * 立即设置中止标志，并强制关闭 TCP Socket 以中断可能阻塞的 connect() 调用。
   * 调用后 sendFile 会抛出异常进入 finally 完成资源清理。
   */
  abort(): void {
    this.isAborted = true;
    console.info('TransferEngine: abort() called');

    // 立即中断任意正在等待的 waitForConfirm / waitForComplete
    if (this.waitingReject !== null) {
      this.waitingReject(new Error('TransferEngine: transfer aborted by user while waiting'));
      this.waitingReject = null;
    }

    // 主动关闭 Socket，中断可能正在阻塞的 connect() / send()
    if (this.tcpSocket !== null) {
      try {
        this.tcpSocket.close();
        console.info('TransferEngine: socket forcefully closed by abort');
      } catch (error) {
        console.error('TransferEngine: abort close error, code=' +
          (error as BusinessError).code + ', message=' +
          (error as BusinessError).message);
      }
    }
  }

  // ================================================================
  // 私有方法
  // ================================================================

  /**
   * 等待接收端对本次传输请求的确认回复。
   *
   * 监听 Socket message 事件，读取第一个字节：
   *   - 0x01：接收端允许传输
   *   - 0x02：接收端拒绝传输
   * 若超时（ProtocolConstants.CONFIRM_TIMEOUT_MS）未收到回复，返回 0x03。
   *
   * @returns Promise<number> — 回复字节值（0x01 允许 / 0x02 拒绝 / 0x03 超时）
   */
  private waitForConfirm(): Promise<number> {
    return new Promise<number>((resolve: (value: number) => void, reject: (reason: Error) => void) => {
      if (this.isAborted || this.tcpSocket === null) {
        reject(new Error('TransferEngine: abort detected in waitForConfirm'));
        return;
      }

      // 存储 reject 引用供 abort() 调用
      this.waitingReject = reject;

      let cleanedUp: boolean = false;

      // 超时定时器
      const timerId: number = setTimeout(() => {
        if (cleanedUp) {
          return;
        }
        cleanedUp = true;
        this.waitingReject = null;
        console.info('TransferEngine: waitForConfirm timeout, resolving 0x03');
        resolve(0x03);
      }, ProtocolConstants.CONFIRM_TIMEOUT_MS);

      // 消息回调
      const onMessage = (info: socket.SocketMessageInfo): void => {
        if (cleanedUp) {
          return;
        }
        cleanedUp = true;
        clearTimeout(timerId);
        this.waitingReject = null;
        const firstByte: number = new Uint8Array(info.message)[0];
        console.info('TransferEngine: waitForConfirm received byte=0x' +
          firstByte.toString(16).padStart(2, '0'));
        resolve(firstByte);
      };

      this.tcpSocket.on('message', onMessage);
    });
  }

  /**
   * 等待接收端的完成确认。
   *
   * 文件内容发送完成后调用，监听第一个字节是否为 0x04。
   * 设置 ProtocolConstants.COMPLETE_WAIT_MS 超时，超时也 resolve（不阻塞 UI）。
   */
  private waitForComplete(): Promise<void> {
    return new Promise<void>((resolve: () => void, reject: (reason: Error) => void) => {
      if (this.isAborted || this.tcpSocket === null) {
        // abort 状态下直接 resolve，让 finally 清理即可
        resolve();
        return;
      }

      // 存储 reject 引用供 abort() 调用
      this.waitingReject = reject;

      let cleanedUp: boolean = false;

      // 超时定时器：超时也算成功，不阻塞 UI
      const timerId: number = setTimeout(() => {
        if (cleanedUp) {
          return;
        }
        cleanedUp = true;
        this.waitingReject = null;
        console.info('TransferEngine: waitForComplete timeout, resolving anyway');
        resolve();
      }, ProtocolConstants.COMPLETE_WAIT_MS);

      // 消息回调：仅当收到 0x04 时 resolve
      const onMessage = (info: socket.SocketMessageInfo): void => {
        if (cleanedUp) {
          return;
        }
        const firstByte: number = new Uint8Array(info.message)[0];
        if (firstByte === 0x04) {
          cleanedUp = true;
          clearTimeout(timerId);
          this.waitingReject = null;
          console.info('TransferEngine: waitForComplete received 0x04, transfer confirmed');
          resolve();
        }
        // 非 0x04 字节忽略，继续等待
      };

      this.tcpSocket.on('message', onMessage);
    });
  }

  /**
   * 根据 v1.1 协议构建协议头 ArrayBuffer。
   *
   * 结构：
   *   [0..1]   2字节 — 魔数 0x464C（大端序 Uint16）
   *   [2]      1字节 — 协议版本 0x01（Uint8）
   *   [3]      1字节 — 保留字段 0x00（Uint8）
   *   [4..5]   2字节 — 文件名长度（大端序 Uint16）
   *   [6..N-1] N字节 — 文件名 UTF-8 字节
   *   [N..N+7] 8字节 — 文件大小，拆分为高 32 位 + 低 32 位（大端序 Uint32 × 2）
   *
   * @param fileInfo - 文件信息
   * @returns 完整的协议头 ArrayBuffer
   */
  private buildProtocolHeader(fileInfo: SharedFileInfo): ArrayBuffer {
    const textEncoder: util.TextEncoder = new util.TextEncoder();
    const nameBytes: Uint8Array = textEncoder.encodeInto(fileInfo.name);
    const nameLen: number = nameBytes.length;

    // v1.1 协议头大小：2(魔数) + 1(版本) + 1(保留) + 2(文件名长度) + nameLen + 8(文件大小 uint64)
    const headerSize: number = 2 + 1 + 1 + 2 + nameLen + 8;
    const buffer: ArrayBuffer = new ArrayBuffer(headerSize);
    const view: DataView = new DataView(buffer);

    let offset: number = 0;

    // ---- v1.1 Header ----

    // [2 字节] 魔数 0x464C（大端序）
    view.setUint16(offset, ProtocolConstants.PROTOCOL_MAGIC, false);
    offset += 2;

    // [1 字节] 协议版本 0x01
    view.setUint8(offset, ProtocolConstants.PROTOCOL_VERSION);
    offset += 1;

    // [1 字节] 保留字段 0x00
    view.setUint8(offset, 0x00);
    offset += 1;

    // [2 字节] 文件名长度（大端序）
    view.setUint16(offset, nameLen, false);
    offset += 2;

    // [nameLen 字节] 文件名 UTF-8 字节
    const nameView: Uint8Array = new Uint8Array(buffer, offset, nameLen);
    nameView.set(nameBytes);
    offset += nameLen;

    // [8 字节] 文件大小（uint64，拆分为高 32 位 + 低 32 位，大端序）
    const fileSize: number = fileInfo.size;
    const high: number = Math.floor(fileSize / 0x100000000);
    const low: number = fileSize % 0x100000000;
    view.setUint32(offset, high, false);
    view.setUint32(offset + 4, low, false);

    return buffer;
  }

  /**
   * 清理并关闭 TCP Socket。
   * 注销所有事件监听，确保无资源泄漏。
   */
  private async cleanupSocket(): Promise<void> {
    if (this.tcpSocket === null) {
      return;
    }

    try {
      // 关闭连接
      if (this.isConnected) {
        await this.tcpSocket.close();
        this.isConnected = false;
        console.info('TransferEngine: socket closed');
      }

      // 注销事件监听
      this.tcpSocket.off('message');
      this.tcpSocket.off('close');
      this.tcpSocket.off('error');
      console.info('TransferEngine: socket listeners removed');
    } catch (error) {
      console.error('TransferEngine: cleanupSocket error, code=' +
        (error as BusinessError).code + ', message=' +
        (error as BusinessError).message);
    } finally {
      this.tcpSocket = null;
    }
  }
}
