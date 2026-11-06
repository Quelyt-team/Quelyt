# Quelyt · 教材自学与论文精读

<img src="assets/brand/quelyt-icon.png" width="72" height="72" alt="Quelyt 应用图标">

本地优先的 Flutter 学习客户端，共享 Windows / Android 的阅读器与学习数据结构。以自己的教材或论文为起点，阅读、检索原文、主动回忆、核对出处并保存学习记录。

当前为 **v0.1.0 首版开发基线**（应用版本 `0.1.0+1`）。以本机安装的 Quelyt 和用户完成的 Round 3 界面为基础，静态分析、**91 项测试**、真实随包 OCR 与 Windows Release 构建通过。验收范围、复现方式和安装产物哈希见 [首版验收](docs/首版验收.md)。

真实服务商回答质量、完整窗口端到端流程、复杂资料质量与 Android 真机尚未完成验收。

## 已有功能

- 系统文件选择器导入 PDF / JPG / PNG，保存应用副本、计算内容哈希并去重。
- 原页阅读、缩放、旋转、框选、物理页跳转与阅读位置恢复。
- 本地 OCR、SQLite FTS5 中英文检索、对照原页校正文字。
- 教材页段、学习目标与时间设置，出题、独立作答、评阅、待核对和重练记录。
- 论文导读、术语解释、图表请求与带原文出处的理解笔记。
- 自带 API Key，直连兼容 Chat Completions 的服务；文本与视觉模型可分别设置。
- 发送前预览目的地、问题、作答、原文、图片和历史上下文；图片授权只用于本次请求。

无需 API Key 也可导入、阅读、检索、校正原文、写笔记和保存已有练习的作答。两端各自保存数据，暂无同步服务。

## 首版可靠性修复

- 证据不足、协议失败或网络错误不会变成题目或已完成评阅。
- 追问可带上同资料版本、同学习小节最近 6 轮以内、8,000 字符以内的有效历史；历史在发送预览中完整展示。
- 导读按页分配证据预算，保留首尾；最多 12 页、16,000 字符，缺页和节选明确标为局部导读。
- 请求绑定预览时的资料与学习状态，旧请求及迟到回答不会覆盖新进度。

## 开发与验证

需要 Flutter 3.47.9 / Dart 3.13.7。Windows 构建另需 Visual Studio C++ 工具链、ATL 与 Windows SDK；Android 构建需兼容的 JDK 和 Android SDK。

```powershell
./scripts/check.ps1
./scripts/check.ps1 -Task windows
./scripts/check.ps1 -Task run
./scripts/check.ps1 -Task android
./native_ocr/windows/smoke-test.ps1
```

脚本优先使用工作区 `.tooling/flutter`，否则使用系统 Flutter。中文工作区路径会使用临时英文目录联接；Flutter 插件使用目录联接，减少本机开发环境差异。构建所需依赖在首次解析时下载，OCR 模型则随应用交付。

Windows 产物为 `build/windows/x64/runner/Release/`，Android arm64 开发 APK 为 `build/app/outputs/flutter-apk/app-release.apk`。Android 当前使用开发调试签名，不能等同于正式发行包。

## 数据与出处

资料副本、索引、问答、笔记和练习保存在系统应用支持目录内的 `local_study/`。Key 使用系统保护的凭据存储，不写入 SQLite。Android 关闭系统云备份。删除资料只清理应用管理的副本与记录，外部原件保留。

只有确认发送预览才进入 AI 调用；超时不自动重试。引用绑定文档哈希、物理页和原页区域。旧历史只辅助理解追问，不能代替当前原文证据。复杂公式、表格和跨栏内容仍需对照原页。

## 项目结构与文档

| 目录 | 内容 |
| --- | --- |
| `lib/core/` | 数据模型、SQLite、全文检索 |
| `lib/services/` | 导入、渲染、OCR、AI 请求与响应校验 |
| `lib/app_controller.dart` | 阅读位置、索引队列、学习会话、历史与出处 |
| `lib/ui/` | 用户设计的书库、阅读器、学习面板和设置 |
| `native_ocr/`、`assets/ocr/`、`licenses/` | 原生 OCR 桥接、随包模型、运行库及第三方许可 |
| `test/` | 持久化、检索、文件、AI、控制器与界面回归 |

- [实施企划](企划.md)
- [首版验收](docs/首版验收.md)
- [OCR 实现与完整性](docs/OCR.md)
- [DeepTutor 对齐计划](docs/功能校验与DeepTutor对齐计划.md)
- [公开归档清单](docs/公开归档清单.md)
- [更新记录](CHANGELOG.md)

本机运行数据、备份、工具环境和历史截图不随源码归档。内部包名及数据目录保留 `local_study`，以兼容已有资料和凭据绑定。
