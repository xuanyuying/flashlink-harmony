/**
 * 闪连互传 - 接收确认控制器（v1.2）
 * 静态桥接：UI 按钮 -> EntryAbility 持有的 ReceiveServer.confirm()。
 */

import { ReceiveServer } from './ReceiveServer';

export class ReceiveController {
  private static server: ReceiveServer | null = null;

  static attach(server: ReceiveServer): void {
    ReceiveController.server = server;
  }

  static confirm(connId: string, allow: boolean): void {
    if (ReceiveController.server !== null) {
      ReceiveController.server.confirm(connId, allow);
    }
  }
}
