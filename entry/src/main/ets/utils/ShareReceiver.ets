/**
 * 文件传输助手 - 系统分享接收器
 *
 * 负责从系统分享的 Want 对象中解析出文件 URI、
 * 文件名和文件大小，封装为 SharedFileInfo 实例。
 */

import { Want } from '@kit.AbilityKit';
import { fileIo as fs } from '@kit.CoreFileKit';
import { BusinessError } from '@kit.BasicServicesKit';
import { SharedFileInfo } from '../model/Types';

/**
 * 系统分享接收工具类，提供静态方法解析分享数据。
 */
export class ShareReceiver {
  /**
   * 解析系统分享的 Want，提取文件信息。
   *
   * 从 want.parameters 中提取 uri 字段，
   * 通过 fileIo.statSync 获取文件大小，
   * 通过 URI 路径最后一段提取文件名。
   *
   * @param want - 系统分享触发的 Want 对象
   * @returns 解析成功返回 SharedFileInfo 实例，失败或无效数据返回 null
   */
  static parseSharedFile(want: Want): SharedFileInfo | null {
    try {
      // 1. 校验 want.parameters 是否存在
      const parameters: Record<string, Object> | undefined = want.parameters;
      if (parameters === undefined || parameters === null) {
        console.warn('ShareReceiver: want.parameters is undefined or null');
        return null;
      }

      // 2. 从多个可能的字段中提取 URI（优先级从高到低）
      let uri: string | null = null;

      // 2a. 尝试提取 parameters['uri']（单个文件分享）
      const uriObj: Object | undefined = parameters['uri'];
      if (uriObj !== undefined && uriObj !== null) {
        const uriStr: string = uriObj as string;
        if (uriStr.trim().length > 0) {
          uri = uriStr;
        }
      }

      // 2b. 若未找到，尝试 parameters['filePaths']（数组形式的文件路径）
      if (uri === null) {
        const filePathsObj: Object | undefined = parameters['filePaths'];
        if (filePathsObj !== undefined && filePathsObj !== null) {
          const filePaths: Object[] = filePathsObj as Object[];
          if (filePaths.length > 0 && filePaths[0] !== null) {
            const firstPath: string = filePaths[0] as string;
            if (firstPath.trim().length > 0) {
              uri = firstPath;
            }
          }
        }
      }

      // 2c. 尝试 parameters['fileUri']（另一种常见 key）
      if (uri === null) {
        const fileUriObj: Object | undefined = parameters['fileUri'];
        if (fileUriObj !== undefined && fileUriObj !== null) {
          const fileUriStr: string = fileUriObj as string;
          if (fileUriStr.trim().length > 0) {
            uri = fileUriStr;
          }
        }
      }

      if (uri === null) {
        console.warn('ShareReceiver: no valid uri found in want.parameters or want.uris');
        return null;
      }

      // 3. 通过 fileIo.statSync 获取文件大小
      let fileStat: fs.Stat;
      try {
        fileStat = fs.statSync(uri);
      } catch (statError) {
        console.error('ShareReceiver: fs.statSync failed, uri=' + uri +
          ', error=' + (statError as BusinessError).message);
        return null;
      }

      const fileSize: number = fileStat.size;

      // 4. 从 URI 路径最后一段提取文件名
      const segments: string[] = uri.split('/');
      const fileName: string = segments[segments.length - 1];

      if (fileName.trim().length === 0) {
        console.warn('ShareReceiver: extracted fileName is empty, uri=' + uri);
        return null;
      }

      // 5. 提取 MIME 类型（可选，文档 v1.1 的 SharedFileInfo.mimeType）
      let mimeType: string | undefined = undefined;
      const mimeObj: Object | undefined = parameters['mimeType'];
      if (mimeObj !== undefined && mimeObj !== null) {
        const mimeStr: string = mimeObj as string;
        if (mimeStr.trim().length > 0) {
          mimeType = mimeStr.trim();
        }
      }
      // 兜底：使用 want.type（分享意图通常携带 MIME 类型）
      if (mimeType === undefined && want.type !== undefined && want.type !== null) {
        const wantType: string = want.type;
        if (wantType.trim().length > 0) {
          mimeType = wantType.trim();
        }
      }

      console.info('ShareReceiver: parsed file, name=' + fileName +
        ', size=' + fileSize + ', uri=' + uri + ', mimeType=' + (mimeType ?? 'null'));

      // 6. 返回 SharedFileInfo 实例
      return new SharedFileInfo(uri, fileName, fileSize, mimeType);
    } catch (error) {
      console.error('ShareReceiver.parseSharedFile unexpected error: ' +
        (error as BusinessError).message);
      return null;
    }
  }
}
