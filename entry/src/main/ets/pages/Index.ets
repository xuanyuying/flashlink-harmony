// 闪连（FlashLink）手机端 - 主页面（v1.2 深色风格，参照 PC 端界面）
// 布局：标题栏 → Tab(发送/接收) → 内容区；接收确认以覆盖层呈现

import { TransferStatus, SharedFileInfo, ReceivedFile, ReceiveRequest } from '../model/Types';
import { TransferViewModel } from '../viewmodel/TransferViewModel';
import { ReceiveViewModel } from '../viewmodel/ReceiveViewModel';
import { ReceiveController } from '../utils/ReceiveController';
import { ReceiveFileOps } from '../utils/ReceiveFileOps';
import { picker } from '@kit.CoreFileKit';
import { fileIo as fs } from '@kit.CoreFileKit';
import { common, Want } from '@kit.AbilityKit';
import { BusinessError } from '@kit.BasicServicesKit';
import { triggerManualTransfer } from '../entryability/EntryAbility';

// ===== 深色主题色板（与 PC 端一致） =====
const COLOR_BG: string = '#1C1C1E';
const COLOR_CARD: string = '#2C2C2E';
const COLOR_CARD_BORDER: string = '#3A3A3C';
const COLOR_TEXT: string = '#E5E5EA';
const COLOR_TEXT_DIM: string = '#98989F';
const COLOR_ACCENT: string = '#FFD60A';
const COLOR_ACCENT_INK: string = '#1C1C1E';
const COLOR_GREEN: string = '#30D158';
const COLOR_YELLOW: string = '#FFD60A';
const COLOR_RED: string = '#FF453A';
const COLOR_BLUE: string = '#0A84FF';

@Entry
@Component
struct Index {
  /** 发送/传输状态（全局共享） */
  @StorageLink('viewModel') viewModel: TransferViewModel = new TransferViewModel();

  /** v1.2 接收状态 */
  @StorageLink('receiveVM') receiveVm: ReceiveViewModel = new ReceiveViewModel();

  /** 0=发送 1=接收 */
  @State activeTab: number = 0;

  /** 接收视图：当前选中的记录（用于操作面板） */
  @State selectedFile: ReceivedFile | null = null;

  /** 提示消息 */
  @State toastMsg: string = '';

  build() {
    Stack({ alignContent: Alignment.Center }) {
      Column() {
        this.buildTitleBar()
        this.buildTabBar()
        if (this.activeTab === 0) {
          this.buildSendView()
        } else {
          this.buildReceiveView()
        }
      }
      .width('100%')
      .height('100%')
      .backgroundColor(COLOR_BG)

      if (this.receiveVm.pending !== null) {
        this.buildConfirmOverlay()
      }

      if (this.selectedFile !== null) {
        this.buildFileActionPanel()
      }

      if (this.toastMsg.length > 0) {
        this.buildToast()
      }
    }
    .width('100%')
    .height('100%')
    .backgroundColor(COLOR_BG)
  }

  // ================================================================
  // 标题栏
  // ================================================================
  @Builder
  buildTitleBar(): void {
    Row() {
      Text('⚡ 闪连')
        .fontSize(20)
        .fontWeight(FontWeight.Bold)
        .fontColor(COLOR_TEXT)
      Blank()
      Text('FlashLink')
        .fontSize(12)
        .fontColor(COLOR_TEXT_DIM)
    }
    .width('100%')
    .padding({ left: 20, right: 20, top: 16, bottom: 12 })
    .alignItems(VerticalAlign.Center)
  }

  // ================================================================
  // Tab 栏
  // ================================================================
  @Builder
  buildTabBar(): void {
    Row() {
      this.buildTabButton('📤 发送', 0)
      this.buildTabButton('📥 接收', 1)
    }
    .width('100%')
    .padding({ left: 16, right: 16, bottom: 10 })
  }

  @Builder
  buildTabButton(label: string, index: number): void {
    Text(label)
      .fontSize(14)
      .fontWeight(this.activeTab === index ? FontWeight.Bold : FontWeight.Regular)
      .fontColor(this.activeTab === index ? COLOR_ACCENT_INK : COLOR_TEXT_DIM)
      .backgroundColor(this.activeTab === index ? COLOR_ACCENT : COLOR_CARD)
      .borderRadius(18)
      .textAlign(TextAlign.Center)
      .layoutWeight(1)
      .padding({ top: 8, bottom: 8 })
      .margin({ left: 4, right: 4 })
      .onClick(() => {
        this.activeTab = index;
      })
  }

  // ================================================================
  // 发送视图（Tab 0）
  // ================================================================
  @Builder
  buildSendView(): void {
    Scroll() {
      Column() {
        // ---- 状态卡片 ----
        Column() {
          Row() {
            Text('●')
              .fontSize(13)
              .fontColor(this.getStatusDotColor())
              .margin({ right: 6 })
            Text(this.getStatusText())
              .fontSize(16)
              .fontWeight(FontWeight.Medium)
              .fontColor(COLOR_TEXT)
          }
          .width('100%')

          if (this.viewModel.status === TransferStatus.IDLE) {
            Text('选择文件，发送到附近的设备')
              .fontSize(13)
              .fontColor(COLOR_TEXT_DIM)
              .margin({ top: 10 })
            Button('📤 选择文件发送')
              .fontSize(15)
              .fontWeight(FontWeight.Bold)
              .fontColor(COLOR_ACCENT_INK)
              .backgroundColor(COLOR_ACCENT)
              .borderRadius(22)
              .width(180)
              .height(44)
              .margin({ top: 16 })
              .onClick(() => {
                this.handleFilePicker();
              })
          }

          if (this.viewModel.fileName.length > 0) {
            Text(this.viewModel.fileName)
              .fontSize(15)
              .fontColor(COLOR_TEXT)
              .fontWeight(FontWeight.Regular)
              .maxLines(1)
              .textOverflow({ overflow: TextOverflow.Ellipsis })
              .margin({ top: 12 })
          }

          if (this.viewModel.fileSize > 0) {
            Text(this.formatFileSize(this.viewModel.fileSize))
              .fontSize(12)
              .fontColor(COLOR_TEXT_DIM)
              .margin({ top: 4 })
          }

          // ---- 进度区 ----
          if (this.viewModel.status !== TransferStatus.IDLE && this.viewModel.status !== TransferStatus.COMPLETED
            && this.viewModel.status !== TransferStatus.FAILED) {
            if (this.viewModel.status === TransferStatus.WAITING_CONFIRM) {
              Text('等待对方确认…')
                .fontSize(12)
                .fontColor(COLOR_YELLOW)
                .margin({ top: 12 })
              LoadingProgress()
                .width(22)
                .height(22)
                .color(COLOR_YELLOW)
                .margin({ top: 6 })
            } else {
              Progress({
                value: this.viewModel.sentBytes,
                total: this.viewModel.fileSize > 0 ? this.viewModel.fileSize : 1,
                type: ProgressType.Linear
              })
                .width('100%')
                .height(8)
                .borderRadius(4)
                .color(COLOR_BLUE)
                .backgroundColor(COLOR_CARD_BORDER)
                .margin({ top: 14 })
              Text(this.getProgressPercentText())
                .fontSize(12)
                .fontColor(COLOR_TEXT_DIM)
                .width('100%')
                .textAlign(TextAlign.End)
                .margin({ top: 4 })
            }
          }

          if (this.viewModel.status === TransferStatus.TRANSFERRING && this.viewModel.speed > 0) {
            Text('速度: ' + this.formatSpeed(this.viewModel.speed))
              .fontSize(12)
              .fontColor(COLOR_TEXT_DIM)
              .margin({ top: 6 })
          }

          if (this.viewModel.deviceName.length > 0 && (this.viewModel.status === TransferStatus.CONNECTING
            || this.viewModel.status === TransferStatus.WAITING_CONFIRM
            || this.viewModel.status === TransferStatus.TRANSFERRING)) {
            Text('目标: ' + this.viewModel.deviceName)
              .fontSize(12)
              .fontColor(COLOR_TEXT_DIM)
              .margin({ top: 6 })
          }

          if (this.viewModel.status === TransferStatus.COMPLETED) {
            this.buildCompletedHint()
          }
          if (this.viewModel.status === TransferStatus.FAILED) {
            this.buildFailedHint()
          }
        }
        .width('100%')
        .padding(18)
        .backgroundColor(COLOR_CARD)
        .borderRadius(14)
        .border({ width: 1, color: COLOR_CARD_BORDER })

        // ---- 接收横幅（仍展示最近接收，便于切换查看） ----
        this.buildReceiveBanner()
      }
      .width('100%')
      .padding({ left: 16, right: 16, top: 6 })
    }
    .width('100%')
    .height('100%')
    .scrollBar(BarState.Off)
    .align(Alignment.Top)
  }

  // ================================================================
  // 接收视图（Tab 1）
  // ================================================================
  @Builder
  buildReceiveView(): void {
    Column() {
      // ---- 接收状态卡 ----
      Row() {
        Text('●')
          .fontSize(14)
          .fontColor(this.receiveVm.listening ? COLOR_GREEN : '#555555')
          .margin({ right: 8 })
        Column() {
          Text(this.receiveVm.listening ? ('接收中 · 端口 ' + this.receiveVm.port) : '接收未开启')
            .fontSize(15)
            .fontWeight(FontWeight.Medium)
            .fontColor(COLOR_TEXT)
          Text(this.receiveVm.listening ? '电脑端可发现本机并发送文件' : this.receiveVm.lastError)
            .fontSize(11)
            .fontColor(COLOR_TEXT_DIM)
            .margin({ top: 2 })
        }
        .alignItems(HorizontalAlign.Start)
        Blank()
      }
      .width('100%')
      .padding(16)
      .backgroundColor(COLOR_CARD)
      .borderRadius(14)
      .border({ width: 1, color: COLOR_CARD_BORDER })
      .margin({ top: 6, bottom: 12 })

      // ---- 接收记录 ----
      Row() {
        Text('📥 接收记录')
          .fontSize(14)
          .fontWeight(FontWeight.Bold)
          .fontColor(COLOR_TEXT)
        Blank()
        Text(this.receiveVm.records.length > 0 ? ('共 ' + this.receiveVm.records.length + ' 个') : '')
          .fontSize(11)
          .fontColor(COLOR_TEXT_DIM)
      }
      .width('100%')
      .padding({ bottom: 8 })

      if (this.receiveVm.records.length === 0) {
        Column() {
          Text('暂无接收文件')
            .fontSize(13)
            .fontColor(COLOR_TEXT_DIM)
          Text('等待电脑端发送…')
            .fontSize(11)
            .fontColor('#666666')
            .margin({ top: 6 })
        }
        .width('100%')
        .padding({ top: 40, bottom: 40 })
        .backgroundColor(COLOR_CARD)
        .borderRadius(14)
      } else {
        Scroll() {
          Column() {
            ForEach(this.receiveVm.records, (file: ReceivedFile) => {
              this.buildReceiveItem(file)
            }, (file: ReceivedFile) => file.name + '_' + file.receivedAt)
          }
          .width('100%')
        }
        .width('100%')
        .scrollBar(BarState.Auto)
        .layoutWeight(1)
        .align(Alignment.Top)
      }
    }
    .width('100%')
    .height('100%')
    .padding({ left: 16, right: 16 })
  }

  // ================================================================
  // 接收文件操作面板（保存到文件管理 / 转发 / 删除）
  // ================================================================

  @Builder
  buildFileActionPanel(): void {
    Column() {
      Blank()
      Column() {
        Text('📄 ' + (this.selectedFile?.name ?? ''))
          .fontSize(15)
          .fontWeight(FontWeight.Medium)
          .fontColor(COLOR_TEXT)
          .maxLines(1)
          .textOverflow({ overflow: TextOverflow.Ellipsis })
          .width('100%')

        Text((this.selectedFile?.isSaved() ?? false)
          ? '已在文件管理中保存'
          : '保存到文件管理后可打开/转发')
          .fontSize(12)
          .fontColor(this.selectedFile?.isSaved() ? COLOR_GREEN : COLOR_TEXT_DIM)
          .margin({ top: 4 })

        // ---- 保存到文件管理 ----
        Row() {
          Text('💾')
            .fontSize(18)
            .margin({ right: 12 })
          Column() {
            Text(this.selectedFile?.isSaved() ? '重新保存位置' : '保存到文件管理')
              .fontSize(14)
              .fontColor(COLOR_TEXT)
            Text('选择或新建文件夹（如"闪连"）存放，之后可在文件管理查看')
              .fontSize(10)
              .fontColor(COLOR_TEXT_DIM)
              .margin({ top: 2 })
          }
          .alignItems(HorizontalAlign.Start)
          .layoutWeight(1)
        }
        .width('100%')
        .padding(12)
        .backgroundColor(COLOR_BG)
        .borderRadius(8)
        .margin({ top: 12 })
        .onClick(() => {
          this.handleSaveSelected();
        })

        // ---- 转发 / 打开（需先保存到公共位置） ----
        Row() {
          Text('📤')
            .fontSize(18)
            .margin({ right: 12 })
          Column() {
            Text('转发 / 打开')
              .fontSize(14)
              .fontColor(this.selectedFile?.isSaved() ? COLOR_TEXT : '#555555')
            Text(this.selectedFile?.isSaved() ? '分享给微信 / 文件管理等应用' : '请先保存到文件管理')
              .fontSize(10)
              .fontColor(COLOR_TEXT_DIM)
              .margin({ top: 2 })
          }
          .alignItems(HorizontalAlign.Start)
          .layoutWeight(1)
        }
        .width('100%')
        .padding(12)
        .backgroundColor(COLOR_BG)
        .borderRadius(8)
        .margin({ top: 8 })
        .opacity(this.selectedFile?.isSaved() ? 1 : 0.45)
        .onClick(() => {
          if (this.selectedFile?.isSaved() === true) {
            this.handleShareSelected();
          }
        })

        // ---- 删除本地 ----
        Row() {
          Text('🗑')
            .fontSize(18)
            .margin({ right: 12 })
          Text('删除本地文件')
            .fontSize(14)
            .fontColor(COLOR_RED)
          Blank()
        }
        .width('100%')
        .padding(12)
        .backgroundColor(COLOR_BG)
        .borderRadius(8)
        .margin({ top: 8 })
        .onClick(() => {
          this.handleDeleteSelected();
        })

        Button('关闭')
          .fontSize(15)
          .fontColor(COLOR_TEXT_DIM)
          .backgroundColor('#3A3A3C')
          .borderRadius(20)
          .height(40)
          .width('100%')
          .margin({ top: 14 })
          .onClick(() => {
            this.selectedFile = null;
          })
      }
      .width('100%')
      .padding(18)
      .backgroundColor(COLOR_CARD)
      .borderRadius(16)
      .border({ width: 1, color: COLOR_CARD_BORDER })
      .margin({ left: 12, right: 12, bottom: 12 })
    }
    .width('100%')
    .height('100%')
    .backgroundColor('rgba(0, 0, 0, 0.45)')
    .onClick(() => {
      this.selectedFile = null;
    })
  }

  /** 保存当前选中记录到文件管理 */
  async handleSaveSelected(): Promise<void> {
    const file: ReceivedFile | null = this.selectedFile;
    if (file === null) {
      return;
    }
    const context: common.Context = getContext(this) as common.Context;
    const uri: string = await ReceiveFileOps.saveToFiles(context as common.UIAbilityContext, file.path, file.name);
    if (uri.length > 0) {
      file.savedUri = uri;
      file.savedName = file.name;
      this.showToast('已保存到文件管理');
    } else {
      this.showToast('已取消保存');
    }
  }

  /** 转发已保存的文件（拉起系统分享面板） */
  async handleShareSelected(): Promise<void> {
    const file: ReceivedFile | null = this.selectedFile;
    if (file === null || !file.isSaved()) {
      return;
    }
    try {
      const context: common.UIAbilityContext = getContext(this) as common.UIAbilityContext;
      const params: Record<string, Object> = {};
      params['uri'] = file.savedUri;
      const want: Want = {
        action: 'ohos.want.action.sendData',
        type: this.guessMime(file.name),
        uri: file.savedUri,
        parameters: params
      };
      await context.startAbility(want);
    } catch (error) {
      console.error('Index: share failed: ' + (error as BusinessError).message);
      this.showToast('无法打开分享面板');
    }
  }

  /** 删除当前选中记录的本地文件 */
  handleDeleteSelected(): void {
    const file: ReceivedFile | null = this.selectedFile;
    if (file === null) {
      return;
    }
    const removed: boolean = ReceiveFileOps.deleteLocal(file.path);
    this.receiveVm.removeRecordByPath(file.path);
    this.selectedFile = null;
    this.showToast(removed ? '已删除' : '删除失败（文件不存在）');
  }

  /** 简单 MIME 推断 */
  guessMime(name: string): string {
    const lower: string = name.toLowerCase();
    if (lower.endsWith('.jpg') || lower.endsWith('.jpeg')) return 'image/jpeg';
    if (lower.endsWith('.png')) return 'image/png';
    if (lower.endsWith('.gif')) return 'image/gif';
    if (lower.endsWith('.mp4')) return 'video/mp4';
    if (lower.endsWith('.mp3')) return 'audio/mpeg';
    if (lower.endsWith('.pdf')) return 'application/pdf';
    if (lower.endsWith('.txt') || lower.endsWith('.md')) return 'text/plain';
    if (lower.endsWith('.zip')) return 'application/zip';
    return 'application/octet-stream';
  }

  /** 提示条 */
  @Builder
  buildToast(): void {
    Column() {
      Text(this.toastMsg)
        .fontSize(13)
        .fontColor(COLOR_TEXT)
        .padding({ left: 18, right: 18, top: 10, bottom: 10 })
        .backgroundColor('#3A3A3C')
        .borderRadius(20)
    }
    .width('100%')
    .justifyContent(FlexAlign.End)
    .alignItems(HorizontalAlign.Center)
    .padding({ bottom: 40 })
  }

  showToast(msg: string): void {
    this.toastMsg = msg;
    setTimeout(() => {
      this.toastMsg = '';
    }, 2500);
  }

  @Builder
  buildReceiveItem(file: ReceivedFile): void {
    Row() {
      Text('📄')
        .fontSize(20)
        .margin({ right: 10 })
      Column() {
        Text(file.name)
          .fontSize(14)
          .fontColor(COLOR_TEXT)
          .maxLines(1)
          .textOverflow({ overflow: TextOverflow.Ellipsis })
        Text(this.formatFileSize(file.size) + ' · 来自 ' + file.fromAddress)
          .fontSize(11)
          .fontColor(COLOR_TEXT_DIM)
          .margin({ top: 3 })
      }
      .alignItems(HorizontalAlign.Start)
      .layoutWeight(1)
      Blank()
      Text(file.status === 'completed' ? '✓' : (file.status === 'failed' ? '✗' : '…'))
        .fontSize(16)
        .fontColor(file.status === 'completed' ? COLOR_GREEN : (file.status === 'failed' ? COLOR_RED : COLOR_YELLOW))
    }
    .width('100%')
    .padding(12)
    .backgroundColor(COLOR_CARD)
    .borderRadius(10)
    .margin({ bottom: 8 })
    .onClick(() => {
      if (file.status === 'completed') {
        this.selectedFile = file;
      }
    })
  }

  // ================================================================
  // 完成 / 失败提示
  // ================================================================
  @Builder
  buildCompletedHint(): void {
    Row() {
      Text('✓ 发送完成')
        .fontSize(15)
        .fontWeight(FontWeight.Medium)
        .fontColor(COLOR_GREEN)
    }
    .width('100%')
    .justifyContent(FlexAlign.Center)
    .padding({ top: 12, bottom: 4 })
  }

  @Builder
  buildFailedHint(): void {
    Column() {
      Text('✗ 发送失败')
        .fontSize(15)
        .fontWeight(FontWeight.Medium)
        .fontColor(COLOR_RED)
      if (this.viewModel.errorMsg.length > 0) {
        Text(this.viewModel.errorMsg)
          .fontSize(12)
          .fontColor(COLOR_RED)
          .textAlign(TextAlign.Center)
          .maxLines(3)
          .textOverflow({ overflow: TextOverflow.Ellipsis })
          .margin({ top: 4 })
      }
      Button('重新选择文件')
        .fontSize(13)
        .fontColor(COLOR_TEXT)
        .backgroundColor('#3A3A3C')
        .borderRadius(18)
        .height(34)
        .margin({ top: 10 })
        .onClick(() => {
          this.viewModel.reset();
          this.handleFilePicker();
        })
    }
    .width('100%')
    .alignItems(HorizontalAlign.Center)
    .margin({ top: 10 })
  }
  // ================================================================
  // 接收横幅（发送 Tab 底部，展示最近接收）
  // ================================================================
  @Builder
  buildReceiveBanner(): void {
    Column() {
      Row() {
        Text('●')
          .fontSize(12)
          .fontColor(this.receiveVm.listening ? COLOR_GREEN : '#555555')
          .margin({ right: 6 })
        Text(this.receiveVm.listening ? ('接收中 · 端口 ' + this.receiveVm.port) : '接收未开启')
          .fontSize(12)
          .fontColor(COLOR_TEXT_DIM)
        Blank()
        Text(this.receiveVm.records.length > 0 ? ('已接收 ' + this.receiveVm.records.length + ' 个') : '')
          .fontSize(11)
          .fontColor(COLOR_TEXT_DIM)
      }
      .width('100%')
      .padding({ top: 8, bottom: 8 })

      if (this.receiveVm.records.length > 0) {
        Text('最近: ' + this.receiveVm.records[0].name)
          .fontSize(11)
          .fontColor('#777777')
          .maxLines(1)
          .textOverflow({ overflow: TextOverflow.Ellipsis })
          .width('100%')
          .padding({ bottom: 6 })
      }
    }
    .width('100%')
    .margin({ top: 10 })
    .onClick(() => {
      this.activeTab = 1;
    })
  }

  // ================================================================
  // 接收确认覆盖层（v1.2）
  // ================================================================
  @Builder
  buildConfirmOverlay(): void {
    Column() {
      Blank()
      Column() {
        Text('📥 接收文件？')
          .fontSize(18)
          .fontWeight(FontWeight.Bold)
          .fontColor(COLOR_TEXT)

        Text('来自: ' + (this.receiveVm.pending?.fromAddress ?? ''))
          .fontSize(13)
          .fontColor(COLOR_TEXT_DIM)
          .margin({ top: 14 })

        Text(this.receiveVm.pending?.fileName ?? '')
          .fontSize(15)
          .fontColor(COLOR_TEXT)
          .fontWeight(FontWeight.Medium)
          .margin({ top: 8 })
          .maxLines(2)
          .textOverflow({ overflow: TextOverflow.Ellipsis })

        Text('大小: ' + this.formatFileSize(this.receiveVm.pending?.fileSize ?? 0))
          .fontSize(13)
          .fontColor(COLOR_TEXT_DIM)
          .margin({ top: 6 })

        Row() {
          Button('拒绝')
            .fontSize(15)
            .fontColor(COLOR_TEXT_DIM)
            .backgroundColor('#3A3A3C')
            .borderRadius(22)
            .height(44)
            .layoutWeight(1)
            .margin({ right: 10 })
            .onClick(() => {
              this.handleReceiveConfirm(false);
            })

          Button('允许接收')
            .fontSize(15)
            .fontWeight(FontWeight.Bold)
            .fontColor(COLOR_ACCENT_INK)
            .backgroundColor(COLOR_ACCENT)
            .borderRadius(22)
            .height(44)
            .layoutWeight(1)
            .onClick(() => {
              this.handleReceiveConfirm(true);
            })
        }
        .width('100%')
        .margin({ top: 20 })
      }
      .width('100%')
      .padding(22)
      .backgroundColor(COLOR_CARD)
      .borderRadius(16)
      .border({ width: 1, color: COLOR_CARD_BORDER })
      .margin({ left: 24, right: 24 })

      Blank()
    }
    .width('100%')
    .height('100%')
    .backgroundColor('rgba(0, 0, 0, 0.5)')
  }

  // ================================================================
  // 交互处理
  // ================================================================

  /**
   * 打开系统文件选择器，选择文件后触发发送管道
   */
  async handleFilePicker(): Promise<void> {
    try {
      const context: common.Context = getContext(this) as common.Context;
      const documentPicker: picker.DocumentViewPicker = new picker.DocumentViewPicker(context);
      const documentSelectOptions: picker.DocumentSelectOptions = new picker.DocumentSelectOptions();
      const result: Array<string> = await documentPicker.select(documentSelectOptions);
      if (result.length === 0) {
        return;
      }
      const files: SharedFileInfo[] = [];
      for (const uri of result) {
        try {
          const stat: fs.Stat = fs.statSync(uri);
          const segments: string[] = uri.split('/');
          const name: string = segments[segments.length - 1] ?? ('file_' + Date.now());
          files.push(new SharedFileInfo(uri, name, stat.size));
        } catch (parseError) {
          const err: BusinessError = parseError as BusinessError;
          console.error('Failed to parse file URI: ' + uri + ', error: ' + err.message);
        }
      }
      if (files.length === 0) {
        console.error('No valid files selected');
        return;
      }
      triggerManualTransfer(files);
    } catch (error) {
      const bizError: BusinessError = error as BusinessError;
      console.error('File picker failed: ' + bizError.message);
    }
  }

  /**
   * 接收确认处理（v1.2）
   */
  handleReceiveConfirm(allow: boolean): void {
    const pending: ReceiveRequest | null = this.receiveVm.pending;
    if (pending !== null) {
      ReceiveController.confirm(pending.connId, allow);
      this.receiveVm.clearPending();
    }
  }

  // ================================================================
  // 状态文案与颜色
  // ================================================================

  getStatusText(): string {
    switch (this.viewModel.status) {
      case TransferStatus.IDLE:
        return '准备就绪';
      case TransferStatus.DISCOVERING:
        return '正在搜索设备…';
      case TransferStatus.CONNECTING:
        return '正在连接设备…';
      case TransferStatus.WAITING_CONFIRM:
        return '等待对方确认…';
      case TransferStatus.TRANSFERRING:
        return '正在发送文件…';
      case TransferStatus.COMPLETED:
        return '发送完成';
      case TransferStatus.FAILED:
        return '发送失败';
      default:
        return '准备就绪';
    }
  }

  getStatusDotColor(): string {
    switch (this.viewModel.status) {
      case TransferStatus.IDLE:
        return COLOR_TEXT_DIM;
      case TransferStatus.DISCOVERING:
      case TransferStatus.CONNECTING:
        return COLOR_YELLOW;
      case TransferStatus.WAITING_CONFIRM:
        return COLOR_YELLOW;
      case TransferStatus.TRANSFERRING:
        return COLOR_BLUE;
      case TransferStatus.COMPLETED:
        return COLOR_GREEN;
      case TransferStatus.FAILED:
        return COLOR_RED;
      default:
        return COLOR_TEXT_DIM;
    }
  }

  getProgressPercentText(): string {
    if (this.viewModel.fileSize <= 0) {
      return '0%';
    }
    const percent: number = Math.min(100, Math.round((this.viewModel.sentBytes / this.viewModel.fileSize) * 100));
    return percent + '%';
  }

  formatFileSize(bytes: number): string {
    if (bytes <= 0) {
      return '0 B';
    }
    const units: string[] = ['B', 'KB', 'MB', 'GB'];
    let unitIndex: number = 0;
    let size: number = bytes;
    while (size >= 1024 && unitIndex < units.length - 1) {
      size /= 1024;
      unitIndex++;
    }
    if (unitIndex === 0) {
      return size.toFixed(0) + ' ' + units[unitIndex];
    }
    return size.toFixed(1) + ' ' + units[unitIndex];
  }

  formatSpeed(bytesPerSec: number): string {
    if (bytesPerSec <= 0) {
      return '0 B/s';
    }
    const units: string[] = ['B/s', 'KB/s', 'MB/s'];
    let unitIndex: number = 0;
    let speed: number = bytesPerSec;
    while (speed >= 1024 && unitIndex < units.length - 1) {
      speed /= 1024;
      unitIndex++;
    }
    if (unitIndex === 0) {
      return speed.toFixed(0) + ' ' + units[unitIndex];
    }
    return speed.toFixed(1) + ' ' + units[unitIndex];
  }

  /** 兼容旧的 formatBytes 引用（有需要时使用） */
  formatBytes(bytes: number): string {
    return this.formatFileSize(bytes);
  }
}