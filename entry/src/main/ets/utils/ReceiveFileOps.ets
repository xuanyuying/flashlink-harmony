/**
 * 闪连互传 - 接收文件操作（v1.2）
 *
 * 鸿蒙沙箱限制说明：应用沙箱目录（filesDir）对"文件管理"不可见。
 * 要让接收文件在文件管理中可见并可打开，须经系统 DocumentViewPicker 的"保存"授权，
 * 将文件另存到公共目录（用户可新建专属文件夹，如"闪连"）。
 * - saveToFiles: 弹出系统保存对话框 → 用户选择/新建文件夹 → 拷贝文件 → 返回公共 URI
 * - deleteLocal: 删除本地（沙箱）接收文件
 * - 说明：鸿蒙未开放"直接跳转文件管理指定目录"的 API；保存后可转发分享查看。
 */

import { common } from '@kit.AbilityKit';
import { picker } from '@kit.CoreFileKit';
import { fileIo as fs } from '@kit.CoreFileKit';
import { BusinessError } from '@kit.BasicServicesKit';

export class ReceiveFileOps {
  /**
   * 将沙箱文件另存到文件管理可见位置（用户经系统保存对话框选择/新建文件夹）。
   *
   * @param context UIAbilityContext
   * @param sandboxPath 沙箱内源文件路径
   * @param displayName 默认文件名
   * @returns 保存成功返回公共 URI 字符串；用户取消/失败返回空字符串
   */
  static async saveToFiles(context: common.UIAbilityContext, sandboxPath: string, displayName: string): Promise<string> {
    try {
      const documentPicker: picker.DocumentViewPicker = new picker.DocumentViewPicker(context);
      const options: picker.DocumentSaveOptions = new picker.DocumentSaveOptions();
      const names: string[] = [displayName];
      options.newFileNames = names;
      const uris: string[] = await documentPicker.save(options);
      if (uris.length === 0) {
        console.info('ReceiveFileOps: save cancelled');
        return '';
      }
      // 系统已预建空文件（返回 uri 带写授权），将沙箱文件内容拷贝过去
      const targetUri: string = uris[0];
      try {
        fs.copyFileSync(sandboxPath, targetUri);
        console.info('ReceiveFileOps: saved to ' + targetUri);
        return targetUri;
      } catch (copyErr) {
        console.error('ReceiveFileOps: copyFile failed: ' + (copyErr as BusinessError).message);
        return '';
      }
    } catch (error) {
      console.error('ReceiveFileOps: saveToFiles exception: ' + (error as BusinessError).message);
      return '';
    }
  }

  /**
   * 删除本地（沙箱）文件并返回结果。
   */
  static deleteLocal(path: string): boolean {
    try {
      if (fs.accessSync(path)) {
        fs.unlinkSync(path);
      }
      return true;
    } catch (error) {
      console.error('ReceiveFileOps: delete failed: ' + (error as BusinessError).message);
      return false;
    }
  }
}
