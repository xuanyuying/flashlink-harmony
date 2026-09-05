/**
 * 闪连互传 - TCP 接收服务（v1.2 新增）
 *
 * 基于 socket.TCPSocketServer（API 24）监听 53321，接收 PC 端发送的文件：
 *   每连接一个 FileReceiver；统一管理连接生命周期与并发上限；
 *   向 UI 转达"待确认"请求，接收用户确认结果。
 */

import { socket } from '@kit.NetworkKit';
import { BusinessError } from '@kit.BasicServicesKit';
import { ProtocolConstants, ReceivedFile, ReceiveRequest } from '../model/Types';
import { FileReceiver, ReceiverCallbacks } from './FileReceiver';

/** 接收服务事件回调（EntryAbility/UI 提供） */
export interface ReceiveServerCallbacks {
  onRequestConfirm: (req: ReceiveRequest) => void;
  onComplete: (file: ReceivedFile) => void;
  onError: (connId: string, msg: string) => void;
  onListening: (port: number) => void;
  onListenError: (msg: string) => void;
}

export class ReceiveServer {
  private server: socket.TCPSocketServer | null = null;
  private receivers: Map<string, FileReceiver> = new Map();
  private connSeq: number = 0;
  private saveDir: string;
  private autoAccept: boolean;
  private callbacks: ReceiveServerCallbacks;
  private actualPort: number = -1;

  constructor(saveDir: string, autoAccept: boolean, callbacks: ReceiveServerCallbacks) {
    this.saveDir = saveDir;
    this.autoAccept = autoAccept;
    this.callbacks = callbacks;
  }

  getPort(): number {
    return this.actualPort;
  }

  isRunning(): boolean {
    return this.server !== null;
  }

  /** 启动监听（端口占用自动 +1，最多 3 次） */
  start(preferredPort: number = ProtocolConstants.DEFAULT_PORT): Promise<number> {
    return this.listenWithRetry(preferredPort, 3);
  }

  private listenWithRetry(port: number, attempts: number): Promise<number> {
    return new Promise<number>((resolve: (v: number) => void, reject: (e: Error) => void) => {
      const server: socket.TCPSocketServer = socket.constructTCPSocketServerInstance();
      server.on('connect', (connection: socket.TCPSocketConnection) => {
        this.handleConnection(connection);
      });
      server.on('error', (err: BusinessError) => {
        console.error('ReceiveServer: error code=' + err.code + ' msg=' + err.message);
      });
      try {
        server.listen({
          address: '0.0.0.0',
          port: port,
          family: 1
        }, (err: BusinessError) => {
          if (err && err.code !== 0) {
            console.warn('ReceiveServer: listen failed code=' + err.code + ' port=' + port + ' attempts=' + attempts);
            if (attempts > 1) {
              try {
                server.close();
              } catch (e) {
                // ignore
              }
              this.listenWithRetry(port + 1, attempts - 1).then(resolve, reject);
              return;
            }
            this.callbacks.onListenError('端口监听失败: ' + err.message);
            reject(new Error('listen failed: ' + err.message));
            return;
          }
          this.server = server;
          this.actualPort = port;
          console.info('ReceiveServer: listening on port ' + port);
          this.callbacks.onListening(port);
          resolve(port);
        });
      } catch (error) {
        const biz: BusinessError = error as BusinessError;
        this.callbacks.onListenError(biz.message);
        reject(new Error('listen exception: ' + biz.message));
      }
    });
  }

  /** 停止监听并清理所有连接 */
  stop(): void {
    if (this.server !== null) {
      try {
        this.server.off('connect');
        this.server.off('error');
        this.server.close();
      } catch (error) {
        console.error('ReceiveServer: stop error');
      }
      this.server = null;
    }
    this.receivers.forEach((receiver: FileReceiver) => {
      try {
        receiver.close();
      } catch (e) {
        // ignore
      }
    });
    this.receivers.clear();
  }

  /** 用户确认（allow=true 允许接收） */
  confirm(connId: string, allow: boolean): void {
    const receiver: FileReceiver | undefined = this.receivers.get(connId);
    if (receiver !== undefined) {
      receiver.confirm(allow);
    }
  }

  // ================================================================
  // 内部
  // ================================================================

  private handleConnection(connection: socket.TCPSocketConnection): void {
    if (this.receivers.size >= ProtocolConstants.MAX_RECEIVE_CONNECTIONS) {
      const buf: ArrayBuffer = new ArrayBuffer(1);
      new Uint8Array(buf)[0] = ProtocolConstants.FRAME_REJECT;
      try {
        const options: socket.TCPSendOptions = { data: buf };
        connection.send(options);
        connection.close();
      } catch (e) {
        // ignore
      }
      return;
    }
    this.connSeq++;
    const connId: string = 'rx-' + this.connSeq;
    let fromAddress: string = 'unknown';
    // 异步获取远端地址（不阻塞）
    connection.getRemoteAddress().then((addr: socket.NetAddress) => {
      fromAddress = addr.address;
    }).catch((e: BusinessError) => {
      console.warn('ReceiveServer: getRemoteAddress failed code=' + e.code);
    });

    const callbacks: ReceiverCallbacks = {
      onRequestConfirm: (req: ReceiveRequest): void => this.callbacks.onRequestConfirm(req),
      onComplete: (file: ReceivedFile): void => {
        this.callbacks.onComplete(file);
        this.dropReceiver(connId);
      },
      onError: (_cid: string, msg: string): void => {
        this.callbacks.onError(connId, msg);
        this.dropReceiver(connId);
      }
    };
    const receiver: FileReceiver = new FileReceiver(connId, connection, this.saveDir, this.autoAccept,
      fromAddress, callbacks);
    this.receivers.set(connId, receiver);

    connection.on('message', (info: socket.SocketMessageInfo) => {
      receiver.feed(info.message);
    });
    connection.on('close', () => {
      this.dropReceiver(connId);
    });
    connection.on('error', (err: BusinessError) => {
      console.error('ReceiveServer: conn error code=' + err.code);
      this.dropReceiver(connId);
    });
  }

  private dropReceiver(connId: string): void {
    const receiver: FileReceiver | undefined = this.receivers.get(connId);
    if (receiver !== undefined) {
      this.receivers.delete(connId);
      try {
        receiver.close();
      } catch (e) {
        // ignore
      }
    }
  }
}