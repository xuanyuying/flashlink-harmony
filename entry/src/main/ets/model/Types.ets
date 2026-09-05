/**
 * 文件传输助手 - 数据模型定义
 *
 * 包含：文件信息、设备信息、传输状态枚举、传输错误码枚举、传输进度接口、协议常量
 */

/**
 * 通过系统分享接收到的文件信息
 */
export class SharedFileInfo {
  /**
   * 文件 URI（如：file://docs/storage/...）
   */
  uri: string;

  /**
   * 文件名（含扩展名）
   */
  name: string;

  /**
   * 文件大小（字节）
   */
  size: number;

  /**
   * MIME 类型（可选，来自分享 Want 的 type 或 parameters.mimeType）
   */
  mimeType?: string;

  constructor(uri: string, name: string, size: number, mimeType?: string) {
    this.uri = uri;
    this.name = name;
    this.size = size;
    this.mimeType = mimeType;
  }
}

/**
 * 局域网中发现的 PC 端设备信息
 */
export class DeviceInfo {
  /**
   * 设备 IP 地址
   */
  ip: string;

  /**
   * 设备端口号
   */
  port: number;

  /**
   * 设备名称（可选，由 mDNS 发现时获取，形如 FlashLink-PC-<hostname>）
   */
  name?: string;

  /**
   * mDNS 服务类型（_filetransfer._tcp）
   */
  serviceType: string;

  /**
   * TXT 记录中的协议版本（1.1.0）
   */
  protocolVersion?: string;

  constructor(ip: string, port: number, name?: string, serviceType?: string, protocolVersion?: string) {
    this.ip = ip;
    this.port = port;
    this.name = name;
    this.serviceType = serviceType ?? '_filetransfer._tcp';
    this.protocolVersion = protocolVersion;
  }
}

/**
 * 文件传输状态枚举
 */
export enum TransferStatus {
  /**
   * 空闲状态
   */
  IDLE = 'idle',

  /**
   * 正在发现设备
   */
  DISCOVERING = 'discovering',

  /**
   * 正在连接设备
   */
  CONNECTING = 'connecting',

  /**
   * 等待接收端确认（v1.1 协议新增）
   */
  WAITING_CONFIRM = 'waiting_confirm',

  /**
   * 正在传输文件
   */
  TRANSFERRING = 'transferring',

  /**
   * 传输完成
   */
  COMPLETED = 'completed',

  /**
   * 传输失败
   */
  FAILED = 'failed',
}

/**
 * 传输错误码枚举（v1.1 协议）
 */
export enum TransferErrorCode {
  /**
   * 协议版本不匹配
   */
  VERSION_MISMATCH = 'VERSION_MISMATCH',

  /**
   * 接收端拒绝接收
   */
  RECEIVER_REJECTED = 'RECEIVER_REJECTED',

  /**
   * 确认超时
   */
  CONFIRM_TIMEOUT = 'CONFIRM_TIMEOUT',

  /**
   * 文件过大，超出接收端限制
   */
  FILE_TOO_LARGE = 'FILE_TOO_LARGE',

  /**
   * 并发传输数超限
   */
  CONCURRENT_LIMIT = 'CONCURRENT_LIMIT',

  /**
   * 连接中断
   */
  CONNECTION_LOST = 'CONNECTION_LOST',

  /**
   * 文件读取错误
   */
  FILE_READ_ERROR = 'FILE_READ_ERROR',
}

/**
 * 速度滑动窗口采样点（文档 v1.1：近 2 秒平均速度）
 */
export class SpeedSample {
  /**
   * 采样时间戳（ms）
   */
  t: number;

  /**
   * 该时刻累计已发送字节数
   */
  cum: number;

  constructor(t: number, cum: number) {
    this.t = t;
    this.cum = cum;
  }
}

/**
 * 传输进度信息接口
 */
export interface TransferProgress {
  /**
   * 当前传输状态
   */
  status: TransferStatus;

  /**
   * 正在传输的文件名
   */
  fileName: string;

  /**
   * 文件总大小（字节）
   */
  fileSize: number;

  /**
   * 已发送字节数
   */
  sentBytes: number;

  /**
   * 传输速度（字节/秒）
   */
  speed: number;

  /**
   * 错误码（传输失败时可选填充）
   */
  errorCode?: TransferErrorCode;

  /**
   * 错误详情描述（文档 v1.1 字段名：errorMessage）
   */
  errorMessage?: string;
}

/**
 * v1.1 协议常量定义
 */
export class ProtocolConstants {
  /**
   * 协议魔数（0x464C = "FL"），用于标识 FlashLink 协议帧
   */
  static readonly PROTOCOL_MAGIC: number = 0x464C;

  /**
   * 协议版本号（0x01）
   */
  static readonly PROTOCOL_VERSION: number = 0x01;

  /**
   * 默认监听/连接端口
   */
  static readonly DEFAULT_PORT: number = 53321;

  /**
   * 等待接收端确认的超时时间（毫秒）
   */
  static readonly CONFIRM_TIMEOUT_MS: number = 30000;

  /**
   * 传输完成后等待接收端确认完成的等待时间（毫秒）
   */
  static readonly COMPLETE_WAIT_MS: number = 10000;

  /**
   * 文件分块传输的块大小（1 MB）
   */
  static readonly CHUNK_SIZE: number = 1024 * 1024;

  // ===== v1.2：接收侧常量 =====

  /** 响应帧：允许接收 */
  static readonly FRAME_ALLOW: number = 0x01;
  /** 响应帧：拒绝接收 */
  static readonly FRAME_REJECT: number = 0x02;
  /** 响应帧：确认超时 */
  static readonly FRAME_TIMEOUT: number = 0x03;
  /** 响应帧：传输完成 */
  static readonly FRAME_COMPLETE: number = 0x04;

  /** 接收单文件大小上限（10 GB） */
  static readonly MAX_RECEIVE_SIZE: number = 10 * 1024 * 1024 * 1024;

  /** 接收并发上限 */
  static readonly MAX_RECEIVE_CONNECTIONS: number = 4;
}
// ================================================================
// v1.2 互传：接收侧模型
// ================================================================

/** 接收文件记录（v1.2：手机接收 PC 发送的文件） */
export class ReceivedFile {
  /** 文件名 */
  name: string;
  /** 沙箱内完整路径 */
  path: string;
  /** 文件大小 */
  size: number;
  /** 发送端 IP */
  fromAddress: string;
  /** 状态 */
  status: 'receiving' | 'completed' | 'rejected' | 'failed';
  /** 接收完成时间戳 */
  receivedAt: number;
  /** 已保存到文件管理（公共目录）后的 URI */
  savedUri: string;
  /** 已保存到文件管理后的文件名 */
  savedName: string;

  constructor(name: string, path: string, size: number, fromAddress: string, status: 'receiving' | 'completed' | 'rejected' | 'failed') {
    this.name = name;
    this.path = path;
    this.size = size;
    this.fromAddress = fromAddress;
    this.status = status;
    this.receivedAt = Date.now();
    this.savedUri = '';
    this.savedName = '';
  }

  /** 是否已保存到文件管理（公共目录） */
  isSaved(): boolean {
    return this.savedUri.length > 0;
  }
}

/** 待确认的接收请求（v1.2） */
export class ReceiveRequest {
  /** 连接标识（用于确认/拒绝） */
  connId: string;
  /** 发送端 IP */
  fromAddress: string;
  /** 文件名 */
  fileName: string;
  /** 文件大小 */
  fileSize: number;

  constructor(connId: string, fromAddress: string, fileName: string, fileSize: number) {
    this.connId = connId;
    this.fromAddress = fromAddress;
    this.fileName = fileName;
    this.fileSize = fileSize;
  }
}