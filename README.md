# Quelyt

<img src="assets/brand/quelyt-icon.png" width="72" height="72" alt="Quelyt 应用图标">

**本地优先（Local-First）、带原文出处的教材自学与论文精读客户端**（Windows / Android · Flutter）

仓库地址：<https://github.com/Quelyt-team/Quelyt> · 问题反馈：<https://github.com/Quelyt-team/Quelyt/issues>

当前开发版本：**`0.3.0-dev+33`** · SQLite Schema：**`v10`** · Flutter **`3.47.9`** / Dart **`3.13.7`**

---

## 核心理念

Quelyt 面向需要围绕真实教材、论文和习题开展长期深度学习的场景，所有资料副本、OCR 文本、全文检索索引、独立笔记、复习调度与排课日程均保存于本机：

- **离线可用**：无需配置 API Key 即可完成导入、原页阅读、本地 OCR、全文检索、原文校对、记笔记、手动/自动排课与自评复习。
- **原文可回溯**：笔记摘录、全书问答来源卡片、复习候选题与每日课程均绑定文档 SHA-256、物理页码和选区坐标，随时回跳核对。
- **可控的 AI 边界**：自带兼容 OpenAI Chat Completions 的文本/视觉模型 Key，写入系统受保护凭据库（不入库、不进备份）；发送前完整预览目的地、模型与上下文，图片授权仅限当次请求。

## 功能概览

### 1. 资料库与文件管理
- **统一导入队列**：支持系统文件/文件夹选择器及系统资源管理器拖入（`desktop_drop 0.8.4`），保留目录结构、计算 SHA-256 去重、逐项显示进度，支持失败重试与取消剩余。
- **多维整理与查找**：可嵌套彩色文件夹树（emoji、说明、分支参考线）、面包屑、列表/网格双视图、可切换列显示、标签、星标、快捷方式、首屏封面缩略图、手动排序及跨正文（FTS5）＋元信息的智能文件夹。
- **浮层操作与回收站**：选中资料弹出浮层操作菜单，不挤压下方列表排版；支持批次/单项移入回收站与恢复、按影响范围确认后永久删除（外部原件不受影响）。
- **备份、导出与维护**：托管原件批量导出（自动避让非法字符与保留名）、整库一致性备份与校验恢复（`VACUUM INTO` + `pre-restore` 回滚保护，API Key 不进入备份）、空间占用查看、缓存清理与按哈希重链缺失原件。

### 2. 原页阅读与本地 OCR
- 支持 PDF / JPG / PNG 原页阅读（`pdfrx`）、缩放、旋转、框选区域、物理页直达与阅读位置恢复。
- 随包交付中英文 Tesseract OCR 模型与原生桥接，在本地构建 SQLite FTS5 索引并支持对照原页人工校正识别文本。

### 3. 教材问答与整书理解
- **整书理解索引**：支持构建章节（可编辑）、页段分块、知识点（含别名）与全书概览，分别跟踪页面解析与知识整理进度，支持中断续跑与按页指纹局部重建。
- **全书检索与联网补充**：任意页提问均检索整本书；仅依靠教材结论难以展开时，支持接入 DeepSeek 官方 Search / Fetch（限流与 7 天缓存），回答严格分列「教材出处」与「网络参考」，作者原话核查保持严格书内核查。
- **原页框选图片问答**：框选图表或公式后预览确认再发送给视觉模型，结果写回独立教材会话并保留来源页信息。

### 4. 独立笔记系统
- 独立于教材生命周期的全局笔记工作区，支持 6 类模板、700 ms 防抖自动保存（含修订号保护，失败不伪造状态）、Markdown 工具栏与预览、来源回跳卡片。
- 共用资料库彩色文件夹与标签；支持全文检索、待解决问题列表、节流历史快照与版本恢复、软删除回收站及 Markdown 导出。

### 5. 复习系统（FSRS v5 + 专题训练）
- **双模式调度**：接入 FSRS v5（默认 19 权重）记忆调度与考前专题训练模式；支持今日队列、错题本、待核对（`review_checks`）、题库总览与统计 5 视图。
- **完整闭环**：独立复盘会话支持断点续做、主动回忆作答、4 档自评与操作撤销；支持可选 AI 判分辅助与人工核对标记、错因记录、学习用时统计，并可从阅读器、笔记或每日课程收集候选题入库。

### 6. 日程与 AI 排课
- **日历、列表与学习路径**：周一开头月历、可折叠右侧日详情、计划筛选；支持手动任务/个人占用、每周重复（最多展开 366 天，支持单次或后续修改）、冲突定位与单日休息。
- **确定性排课与课程闭环**：本地排课器自动避让其他计划与锁定块、跳过考试日并支持一键撤销；计划材料目录与知识点提取、每日课程生成与作答草稿/自评落库。
- **便捷跳转与 AI 规划栏**：支持年视图（12 年切换）、月视图、迷你月历选某日、日详情前后一天步进；工具栏「跳转」弹窗提供表达式直达（如 `2027-05-20`、`20270520`、`+7`、`2周`、`3月`）与「按数字推算 / 年月日数字」双模式选择并实时预览目标日期；桌面端内嵌自适应高度 AI 规划对话栏，支持 `Enter` 发送 / `Shift+Enter` 换行。

## 当前验证状态与边界

以下状态均对应当前仓库实际检查与构造结果，**未完成的领域不做夸大宣称**：

- **静态分析与测试（2026-11-13）**：
  - `.\.tooling\flutter\bin\dart.bat analyze lib test` 退出码 `0`（0 错误、0 警告，仅含 1 条既有的 `test/notes/notes_migration_test.dart` `dispose` 弃用提示 `info`）。
  - `.\.tooling\flutter\bin\flutter.bat test --no-pub -r expanded` 共 **337 项通过、0 项失败**；另有 1 项需外部密钥的实时联网测试默认跳过（`test/book_qa/live_book_qa_test.dart`，需显式设置 `BOOK_QA_LIVE=1` 与 `DEEPSEEK_API_KEY`）。
- **Windows 构建与本机安装**：已构建 `0.3.0-dev+33` Windows Release（`build/windows/x64/runner/Release/`）并通过 `scripts/install-windows.ps1` 完成便携 ZIP 打包与覆盖安装启动验收。
- **尚未完成的验收范围**：
  - 真实模型服务商的长期回答与排课质量评估、真实 DeepSeek 账号 Search / Fetch 实测联调；
  - Android 真机完整流程与系统文件拖入验收（Android Release 目前使用开发调试签名）；
  - 富文本 WYSIWYG 与图片附件、公式可视化编辑、笔记链接/反向链接、系统通知与系统日历（ICS）同步、以及万级资料压测。

## 快速开始与构建脚本

### 环境要求
- Flutter **`3.47.9`** / Dart **`3.13.7`**（脚本默认优先使用工作区 `.tooling/flutter`，否则回退到系统 PATH 中的 `flutter`）
- **Windows**：Visual Studio 2022 C++ 桌面开发工具链、ATL 与 Windows SDK
- **Android**：兼容的 JDK 17 与 Android SDK

### 获取与检查

```powershell
git clone https://github.com/Quelyt-team/Quelyt.git
cd Quelyt

# 运行分析与全套测试
./scripts/check.ps1

# 构建 Windows Release 产物（位于 build/windows/x64/runner/Release/）
./scripts/check.ps1 -Task windows

# 打包便携 ZIP 并安装到本机 %LOCALAPPDATA%\Programs\Quelyt
./scripts/install-windows.ps1

# 构建 Android arm64 APK（开发调试签名）
./scripts/check.ps1 -Task android

# 运行 Windows 原生 OCR 冒烟测试
./native_ocr/windows/smoke-test.ps1
```

> 若系统 PowerShell 执行策略限制运行脚本，可使用：
> `powershell -NoProfile -ExecutionPolicy Bypass -File .\scripts\check.ps1 -Task windows`
>
> 当仓库位于包含中文字符的目录路径时，`scripts/check.ps1` 会自动在临时目录创建纯 ASCII 联接目录以规避部分原生工具链路径限制。

## 数据存储与仓库结构

- **本机数据目录**：为兼容已有资料与凭据绑定，内部包名与系统应用支持子目录保留 `local_study/`，SQLite 通过 `v1 → v10` 顺序迁移（每级自动 `VACUUM INTO` 备份与完整性校验）。
- **第三方许可**：OCR 运行库、字库及开源字体/组件许可均随源码保存在 [licenses/](licenses/) 与 [assets/ocr/LICENSE](assets/ocr/LICENSE)。

| 路径 | 说明 |
| --- | --- |
| `lib/core/` | 核心数据模型、SQLite 存储、v1→v10 顺序迁移与 FTS5 索引 |
| `lib/features/library/` | 资料库导入队列、文件夹树、快捷方式、标签、回收站、导出与备份修复 |
| `lib/features/notes/` | 独立笔记模型、自动保存控制器、来源卡、Markdown 工具/预览与历史版本 |
| `lib/features/book_qa/` | 教材整书理解、多路检索、联网补充契约与教材独立问答面板 |
| `lib/features/review/` | FSRS v5 与专题训练调度、复盘会话、AI 核对与错题统计 |
| `lib/features/schedule/` | 日程与 AI 排课、材料目录、知识点提取、每日课程及日期跳转交互 |
| `lib/services/` | 文档读写、PDF/图片渲染、原生 OCR 封装、共用 AI 传输与 Search/Fetch 适配 |
| `lib/ui/` | 全局壳层、阅读器与学习面板、设置弹窗及统一 Folio Line 线性图标体系（`QIcons`） |
| `native_ocr/`、`assets/`、`licenses/` | Windows/Android 原生 OCR 桥接、随包 OCR 模型/品牌资源与第三方许可 |
| `scripts/`、`.github/workflows/` | 本地检查/构建/打包安装脚本与 GitHub Actions CI 工作流 |
| `test/` | 存储、迁移、检索、AI 安全契约、图标规范及各模块 UI 回归测试 |

## 相关文档

- [更新记录](CHANGELOG.md)
- [产品与设计企划](企划.md)
- [资料库与文件管理实现说明](docs/资料库实现说明.md)
- [笔记实现说明](docs/笔记实现说明.md)
- [教材问答实现说明](docs/教材问答实现说明.md)
- [日程实现说明](docs/日程实现说明.md)
- [OCR 实现与完整性](docs/OCR.md)
- [首版验收基线](docs/首版验收.md)
- [公开归档清单](docs/公开归档清单.md)
