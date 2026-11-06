# 本地 OCR 的实现与验收状态

本轮采用 **随包 Tesseract 替代引擎**，尚未接入企划指定的 PP-OCRv5_mobile。两端都使用已保存在仓库中的中英文 tessdata_fast 模型，不在首次启动时下载。源码接入不等同于双端安装验收通过。

| 平台 | 当前实现 | 打包方式 | 验证边界 |
| --- | --- | --- | --- |
| Windows x64 | Tesseract NuGet 5.2.0 分发中的原生 C API，WIC 解码，后台线程返回行框 | `native_ocr/windows/runtime/x64/` 的两份 DLL 安装到程序旁的 `ocr/`；模型由 Flutter assets 携带 | 已真实调用 DLL 识别生成的中英混排图片；runner 已编译并安装，设置页报告内置中英文 OCR 可用；尚待真实资料质量验收 |
| Android | Tesseract4Android 4.9.0 标准版 | Gradle 解析 `cz.adaptech.tesseract4android:tesseract4android:4.9.0`；首次离线启动将 APK 模型复制到应用 noBackupFilesDir | Kotlin 桥接与 arm64 Release APK 已编译成功；尚未安装到手机实测 |

Windows DLL 来源：[NuGet Tesseract 5.2.0](https://www.nuget.org/packages/Tesseract/5.2.0)、[维护者仓库](https://github.com/charlesw/tesseract/tree/5.2.0)。该分发依赖 Microsoft VC++ 运行时，干净设备的安装程序仍需处理此依赖。当前实现不需要 MSIX 包身份或系统 OCR 语言包。

Android 使用维护者提供的 [Tesseract4Android 4.9.0](https://github.com/adaptech-cz/Tesseract4Android)，通过 JitPack 构建依赖；应用运行时没有模型下载逻辑。代码没有使用 ML Kit、Google Play Services OCR 或云 OCR。

## 随附文件与完整性

模型来自 [tessdata_fast 4.1.0](https://github.com/tesseract-ocr/tessdata_fast/tree/4.1.0)，仅用于正文检索辅助；不提供 LaTeX 转写或表格结构恢复。

| 仓库文件 | SHA-256 |
| --- | --- |
| `assets/ocr/chi_sim.traineddata` | `a5fcb6f0db1e1d6d8522f39db4e848f05984669172e584e8d76b6b3141e1f730` |
| `assets/ocr/eng.traineddata` | `7d4322bd2a7749724879683fc3912cb542f19906c83bcc1a52132556427170b2` |
| `native_ocr/windows/runtime/x64/tesseract50.dll` | `de4d04ec75095374d98f5dd7a60d14d7e2e0f76589db693eccf7ae658be8cb2b` |
| `native_ocr/windows/runtime/x64/leptonica-1.82.0.dll` | `dfcb3e6ed0b16bc55bfdbcf53543cfe42a354b87c3e35bd3a95eebf005d73e76` |

模型共约 6.6 MB，Windows 两份原生 DLL 共约 7 MB。这不是完整应用安装包的大小。上游许可证在 `licenses/` 及 `assets/ocr/LICENSE`，并注册到设置页的“开源许可”。正式发布仍需核对原生二进制中静态链接的图像编解码库声明及运行时再分发事项。

## 数据和坐标约定

Flutter 通道为 `MethodChannel('local_study/ocr')`：

- `availability` 返回 `available`、`backend`、`languages`、`message`。
- `recognizeImage` 接收本机图片路径和可选语言；返回文字、行框、宽高及引擎名。
- 每个行框包含文字、0..1 归一化坐标和可选置信度。基准是原页渲染图片，已包含 PDF 自带旋转 / 图片 EXIF 方向；用户旋转显示和缩放不改变持久化坐标。
- Windows WIC 与 Android 解码器将输入长边限制到约 2800px。PDF 当前默认渲染长边 2000px。
- Tesseract 行置信度归一化到 0..1，仅为引擎分数，不可视为校准后的正确率。
- 默认自动分栏，不使用依赖额外 OSD 模型的自动方向识别；页面倾斜校正和复杂版面分析尚未完成。PDF 内置旋转的文字定位已有实际 PDF 裁图回归测试。

Windows worker 使用 80 秒识别期限和关闭取消，完成事件回到 Flutter 平台线程。Android 单线程复用引擎，通过 hOCR 开启可取消识别；Dart 通道 90 秒超时。关闭 / 暂停当前队列在当前页任务结束后生效。

Android 关闭系统备份，并在备份 / 数据迁移规则中排除应用文件、数据库、首选项与外部应用目录。OCR 输入限制在应用私有目录；没有相机或广泛存储权限。INTERNET 仅用于用户显式确认的 AI 请求，仍需真机抓包验证整条运行路径。

## 可重复检查

在项目根目录的 PowerShell 7 中执行：

```powershell
./native_ocr/windows/smoke-test.ps1
```

此脚本生成一张中英混排图片，调用仓库 DLL 与模型，并断言包含“守恒”和“Momentum”。本机结果为：

```text
动量守恒 Momentum is conserved
PASS: bundled x64 OCR recognizes a generated bilingual image using a Unicode project path.
```

该样例不代表教材识别率、CER 或性能目标达标。Dart 的 OCR 桥接测试只验证能力报告、路径、错误和矩形校验，不能替代 APK / Windows runner 的真实调用。

## 后续验收

1. 对照企划评估或切换 PP-OCRv5_mobile；保持桥接返回结构与原页坐标不变。
2. 双端原生构建已通过；继续验证 Android 真机加载、干净 Windows 的 VC++ 运行库与完整模型分发。
3. 使用真实教材和双栏论文，分别测中英文 CER、OCR P90、峰值内存和包体；记录手机 / 电脑型号。
4. 首次安装即断网运行，并对导入、OCR、检索和取消图片预览做网络记录。
5. 人工核对表格、单位、负号、上下标、跨栏以及失败页的回看路径。

