/**
 * 闪连互传 - 接收状态 ViewModel（v1.2 新增）
 * 通过 AppStorage('receiveVM') 挂载，驱动接收 UI：监听状态、确认请求、接收记录。
 */

import { ReceivedFile, ReceiveRequest } from '../model/Types';

@Observed
export class ReceiveViewModel {
  /** 是否正在监听 */
  listening: boolean = false;
  /** 实际监听端口 */
  port: number = 0;
  /** 当前待确认的接收请求（同时只有一个） */
  pending: ReceiveRequest | null = null;
  /** 接收完成记录（最多保留 20 条） */
  records: ReceivedFile[] = [];
  /** 最近错误信息 */
  lastError: string = '';

  setListening(port: number): void {
    this.listening = port > 0;
    this.port = port;
  }

  setListenError(msg: string): void {
    this.listening = false;
    this.lastError = msg;
  }

  setPending(req: ReceiveRequest): void {
    this.pending = req;
  }

  clearPending(): void {
    this.pending = null;
  }

  addRecord(file: ReceivedFile): void {
    this.records.unshift(file);
    if (this.records.length > 20) {
      this.records = this.records.slice(0, 20);
    }
  }

  /** 移除一条接收记录（按路径匹配） */
  removeRecordByPath(path: string): void {
    const next: ReceivedFile[] = [];
    for (let i = 0; i < this.records.length; i++) {
      if (this.records[i].path !== path) {
        next.push(this.records[i]);
      }
    }
    this.records = next;
  }
}

AppStorage.setOrCreate('receiveVM', new ReceiveViewModel());