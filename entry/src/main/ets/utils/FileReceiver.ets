/**
 * 闪连互传 - 文件接收引擎（v1.2 新增）
 *
 * 解析 PC 端发送的 v1.1 协议数据并落盘到应用沙箱：
 *   协议头 → 校验（魔数/版本）→ 连接确认（0x01/0x02）→ 分块写文件 → 完成（0x04）
 * 与 PC 端 main/fileReceiver.ts 同构。
 */

import { socket } from '@kit.NetworkKit';
import { fileIo as fs } from '@kit.CoreFileKit';
import { BusinessError } from '@kit.BasicServicesKit';
import { ProtocolConstants, ReceivedFile, ReceiveRequest } from '../model/Types';

/** 接收状态机状态 */
enum RxState {
  MAGIC = 0,
  VERSION = 1,
  RESERVED = 2,
  NAME_LEN = 3,
  FILE_NAME = 4,
  FILE_SIZE = 5,
  WAIT_CONFIRM = 6,
  FILE_DATA = 7,
  DONE = 8,
  ERROR = 9
}

/** 接收事件回调（由 ReceiveServer/EntryAbility 提供） */
export interface ReceiverCallbacks {
  onRequestConfirm: (req: ReceiveRequest) => void;
  onComplete: (file: ReceivedFile) => void;
  onError: (connId: string, msg: string) => void;
}

/**
 * 单个 TCP 连接的文件接收器。
 * 数据来源：ReceiveServer 转发的 connection 'message' 事件。
 */
export class FileReceiver {
  private state: RxState = RxState.MAGIC;
  private pending: number[] = [];        // 头部阶段字节累积
  private nameLen: number = 0;
  private fileName: string = '';
  private fileSize: number = 0;
  private receivedBytes: number = 0;
  private connId: string;
  private connection: socket.TCPSocketConnection;
  private saveDir: string;
  private autoAccept: boolean;
  private callbacks: ReceiverCallbacks;
  private tmpPath: string = '';
  private finalPath: string = '';
  private fileFd: number = -1;
  private confirmResolved: boolean = false;
  private fromAddress: string = '';
  // 异步写队列：避免在 UI 线程同步 writeSync 大文件导致卡死被杀
  private writeQueue: Array<ArrayBuffer> = [];
  private queuedBytes: number = 0;
  private writing: boolean = false;

  constructor(connId: string, connection: socket.TCPSocketConnection, saveDir: string, autoAccept: boolean,
    fromAddress: string, callbacks: ReceiverCallbacks) {
    this.connId = connId;
    this.connection = connection;
    this.saveDir = saveDir;
    this.autoAccept = autoAccept;
    this.fromAddress = fromAddress;
    this.callbacks = callbacks;
  }

  /** 处理一个数据块（ArrayBuffer → 字节数组解析） */
  feed(data: ArrayBuffer): void {
    if (this.state === RxState.DONE || this.state === RxState.ERROR) {
      return;
    }
    const bytes: Uint8Array = new Uint8Array(data);
    if (this.state === RxState.FILE_DATA) {
      // 文件数据阶段：入队异步写盘（不阻塞 UI 线程）
      this.consumeFileData(bytes);
      return;
    }
    // 头部阶段：累积字节
    for (let i = 0; i < bytes.length; i++) {
      this.pending.push(bytes[i]);
    }
    this.tryParseHeader();
  }

  /** 用户确认结果 */
  confirm(allow: boolean): void {
    if (this.state !== RxState.WAIT_CONFIRM || this.confirmResolved) {
      return;
    }
    this.confirmResolved = true;
    if (allow) {
      this.sendFrame(ProtocolConstants.FRAME_ALLOW);
      this.openFile();
      this.state = RxState.FILE_DATA;
      this.consumeRemainingPending();
    } else {
      this.sendFrame(ProtocolConstants.FRAME_REJECT);
      this.fail('用户拒绝接收');
    }
  }

  /** 关闭连接时清理（由 ReceiveServer 调用） */
  close(): void {
    this.cleanup();
  }

  // ================================================================
  // 内部实现
  // ================================================================

  private sendFrame(byte: number): void {
    const buf: ArrayBuffer = new ArrayBuffer(1);
    const view: Uint8Array = new Uint8Array(buf);
    view[0] = byte;
    try {
      const options: socket.TCPSendOptions = { data: buf };
      this.connection.send(options);
    } catch (error) {
      console.error('FileReceiver: sendFrame error ' + (error as BusinessError).message);
    }
  }

  private tryParseHeader(): void {
    try {
      let consumed: boolean = true;
      while (consumed && this.state < RxState.WAIT_CONFIRM) {
        consumed = false;
        switch (this.state) {
          case RxState.MAGIC: {
            if (this.pending.length < 2) break;
            const magic: number = (this.pending[0] << 8) | this.pending[1];
            if (magic !== ProtocolConstants.PROTOCOL_MAGIC) {
              this.fail('协议魔数校验失败');
              return;
            }
            this.pending.splice(0, 2);
            this.state = RxState.VERSION;
            consumed = true;
            break;
          }
          case RxState.VERSION: {
            if (this.pending.length < 1) break;
            const ver: number = this.pending[0];
            if (ver !== ProtocolConstants.PROTOCOL_VERSION) {
              this.fail('协议版本不匹配: ' + ver);
              return;
            }
            this.pending.splice(0, 1);
            this.state = RxState.RESERVED;
            consumed = true;
            break;
          }
          case RxState.RESERVED: {
            if (this.pending.length < 1) break;
            this.pending.splice(0, 1);
            this.state = RxState.NAME_LEN;
            consumed = true;
            break;
          }
          case RxState.NAME_LEN: {
            if (this.pending.length < 2) break;
            this.nameLen = (this.pending[0] << 8) | this.pending[1];
            this.pending.splice(0, 2);
            this.state = RxState.FILE_NAME;
            consumed = true;
            break;
          }
          case RxState.FILE_NAME: {
            if (this.pending.length < this.nameLen) break;
            const nameBytes: number[] = this.pending.splice(0, this.nameLen);
            let decodedName: string = '';
            for (let i = 0; i < nameBytes.length; i++) {
              decodedName += String.fromCharCode(nameBytes[i]);
            }
            this.fileName = this.sanitizeFileName(decodedName);
            this.state = RxState.FILE_SIZE;
            consumed = true;
            break;
          }
          case RxState.FILE_SIZE: {
            if (this.pending.length < 8) break;
            const hi: number = ((this.pending[0] << 24) | (this.pending[1] << 16) | (this.pending[2] << 8) | this.pending[3]) >>> 0;
            const lo: number = ((this.pending[4] << 24) | (this.pending[5] << 16) | (this.pending[6] << 8) | this.pending[7]) >>> 0;
            this.pending.splice(0, 8);
            this.fileSize = hi * 0x100000000 + lo;
            if (this.fileSize > ProtocolConstants.MAX_RECEIVE_SIZE) {
              this.sendFrame(ProtocolConstants.FRAME_REJECT);
              this.fail('文件超过大小上限');
              return;
            }
            this.beginConfirm();
            consumed = false; // 停止循环；FILE_DATA 由循环外统一消费 pending
            break;
          }
          default:
            break;
        }
      }
      if (this.state === RxState.FILE_DATA) {
        this.consumeRemainingPending();
      }
    } catch (error) {
      this.fail('协议解析异常: ' + (error as Error).message);
    }
  }

  private beginConfirm(): void {
    if (this.autoAccept) {
      this.sendFrame(ProtocolConstants.FRAME_ALLOW);
      this.openFile();
      this.state = RxState.FILE_DATA;
      return;
    }
    this.state = RxState.WAIT_CONFIRM;
    this.callbacks.onRequestConfirm(new ReceiveRequest(this.connId, this.getRemoteAddress(), this.fileName, this.fileSize));
  }

  private consumeRemainingPending(): void {
    if (this.state !== RxState.FILE_DATA || this.pending.length === 0) {
      return;
    }
    const bytes: Uint8Array = new Uint8Array(this.pending.length);
    for (let i = 0; i < this.pending.length; i++) {
      bytes[i] = this.pending[i];
    }
    this.pending = [];
    this.enqueueWrite(bytes);
  }

  private consumeFileData(bytes: Uint8Array): void {
    if (this.fileFd < 0) {
      this.fail('文件未打开');
      return;
    }
    const remaining: number = this.fileSize - this.receivedBytes - this.queuedBytes;
    if (remaining <= 0) {
      return;
    }
    const writeLen: number = bytes.length > remaining ? remaining : bytes.length;
    if (writeLen === bytes.length) {
      this.enqueueWrite(bytes);
    } else {
      this.enqueueWrite(bytes.subarray(0, writeLen));
    }
  }

  private openFile(): void {
    try {
      // 确保保存目录存在
      if (!fs.accessSync(this.saveDir)) {
        fs.mkdirSync(this.saveDir);
      }
      // 文件名冲突处理：追加 (1)、(2)
      let finalName: string = this.fileName;
      let counter: number = 1;
      while (fs.accessSync(this.saveDir + '/' + finalName)) {
        finalName = this.insertSuffix(this.fileName, counter);
        counter++;
      }
      this.finalPath = this.saveDir + '/' + finalName;
      this.tmpPath = this.finalPath + '.tmp';
      const file = fs.openSync(this.tmpPath, fs.OpenMode.READ_WRITE | fs.OpenMode.CREATE);
      this.fileFd = file.fd;
    } catch (error) {
      this.fail('打开文件失败: ' + (error as BusinessError).message);
    }
  }

  /** 将一块数据入队（内部拷贝为 ArrayBuffer）并启动串行异步写 */
  private enqueueWrite(bytes: Uint8Array): void {
    if (bytes.length === 0) {
      return;
    }
    const buf: ArrayBuffer = new ArrayBuffer(bytes.length);
    const view: Uint8Array = new Uint8Array(buf);
    for (let i = 0; i < bytes.length; i++) {
      view[i] = bytes[i];
    }
    this.writeQueue.push(buf);
    this.queuedBytes += buf.byteLength;
    if (!this.writing) {
      this.writing = true;
      this.pumpWrite();
    }
  }

  /** 串行异步写泵：写一块 → 让出事件循环 → 写下一块 */
  private async pumpWrite(): Promise<void> {
    while (this.writeQueue.length > 0) {
      if (this.state !== RxState.FILE_DATA || this.fileFd < 0) {
        this.writing = false;
        return;
      }
      if (this.writeQueue.length === 0) {
        break;
      }
      const buf: ArrayBuffer = this.writeQueue[0];
      this.writeQueue.splice(0, 1);
      this.queuedBytes -= buf.byteLength;
      try {
        await fs.write(this.fileFd, buf);
      } catch (error) {
        this.fail('文件写入失败: ' + (error as BusinessError).message);
        return;
      }
      this.receivedBytes += buf.byteLength;
      if (this.receivedBytes >= this.fileSize) {
        // 数据收齐，完成收尾（幂等：finishFile 内部防重）
        this.finishFile();
        return;
      }
    }
    this.writing = false;
  }

  private finishFile(): void {
    if (this.state === RxState.DONE || this.state === RxState.ERROR) {
      return; // 幂等保护
    }
    try {
      if (this.fileFd >= 0) {
        fs.closeSync(this.fileFd);
        this.fileFd = -1;
      }
      // tmp → 最终名（原子落盘）
      fs.moveFileSync(this.tmpPath, this.finalPath);
      this.state = RxState.DONE;
      this.sendFrame(ProtocolConstants.FRAME_COMPLETE);
      const file: ReceivedFile = new ReceivedFile(
        this.fileName,
        this.finalPath,
        this.fileSize,
        this.getRemoteAddress(),
        'completed'
      );
      this.callbacks.onComplete(file);
    } catch (error) {
      this.fail('保存文件失败: ' + (error as BusinessError).message);
    }
  }

  private fail(msg: string): void {
    if (this.state === RxState.ERROR || this.state === RxState.DONE) {
      return;
    }
    this.state = RxState.ERROR;
    this.cleanup();
    this.callbacks.onError(this.connId, msg);
  }

  private cleanup(): void {
    try {
      if (this.fileFd >= 0) {
        fs.closeSync(this.fileFd);
        this.fileFd = -1;
      }
    } catch (error) {
      console.error('FileReceiver: close fd error ' + (error as BusinessError).message);
    }
    if (this.tmpPath.length > 0) {
      try {
        if (fs.accessSync(this.tmpPath)) {
          fs.unlinkSync(this.tmpPath);
        }
      } catch (error) {
        console.error('FileReceiver: remove tmp error');
      }
    }
  }

  /** 文件名净化：去除目录成分并替换非法字符 */
  private sanitizeFileName(raw: string): string {
    let name: string = raw;
    const slashIdx: number = Math.max(name.lastIndexOf('/'), name.lastIndexOf('\\'));
    if (slashIdx >= 0) {
      name = name.substring(slashIdx + 1);
    }
    name = name.replace(/[<>:"/\\|?*\u0000-\u001f]/g, '_');
    if (name.length === 0 || name === '.' || name === '..') {
      throw new Error('invalid file name');
    }
    if (name.length > 180) {
      name = name.substring(name.length - 180);
    }
    return name;
  }

  /** 在扩展名前插入 (n) 后缀 */
  private insertSuffix(fileName: string, n: number): string {
    const dot: number = fileName.lastIndexOf('.');
    if (dot <= 0) {
      return fileName + '(' + n + ')';
    }
    return fileName.substring(0, dot) + '(' + n + ')' + fileName.substring(dot);
  }

  private getRemoteAddress(): string {
    return this.fromAddress;
  }
}