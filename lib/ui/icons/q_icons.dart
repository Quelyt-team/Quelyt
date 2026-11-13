import 'q_icon.dart';

export 'q_icon.dart';

/// Quelyt's Folio Line icon set.
///
/// Every icon is drawn on a 24 x 24 grid with round caps/joins. The vocabulary
/// is borrowed from the brand mark: the rounded folio frame, the swallowtail
/// bookmark (filled in the active weight) and the short evidence baseline.
///
/// One concept maps to exactly one icon. When adding an icon, add it to
/// [QIcons.all] so the contact sheet and regression tests pick it up.
abstract final class QIcons {
  // ---------------------------------------------------------------------------
  // Shared parts
  // ---------------------------------------------------------------------------

  static const _calendar = <QShape>[
    QRect(3.5, 5, 17, 15.5, r: 2.5),
    QLine(3.5, 9.75, 20.5, 9.75),
    QLine(8, 3, 8, 6.5),
    QLine(16, 3, 16, 6.5),
  ];

  static const _bubble = QPath(
    'M5.5 4h13A2.5 2.5 0 0 1 21 6.5v8a2.5 2.5 0 0 1-2.5 2.5H12.5L8 20.5V17H5.5'
    'A2.5 2.5 0 0 1 3 14.5v-8A2.5 2.5 0 0 1 5.5 4z',
  );

  static const _corners = <QShape>[
    QPath('M3 8V5.5A2.5 2.5 0 0 1 5.5 3H8'),
    QPath('M16 3h2.5A2.5 2.5 0 0 1 21 5.5V8'),
    QPath('M21 16v2.5a2.5 2.5 0 0 1-2.5 2.5H16'),
    QPath('M8 21H5.5A2.5 2.5 0 0 1 3 18.5V16'),
  ];

  static const _ring = QCircle(12, 12, 9);

  static const _eye = QPath(
    'M2.5 12C4.5 7.8 8 5 12 5s7.5 2.8 9.5 7c-2 4.2-5.5 7-9.5 7s-7.5-2.8-9.5-7z',
  );

  // ---------------------------------------------------------------------------
  // Navigation
  // ---------------------------------------------------------------------------

  /// 书库: two upright spines and a third leaning book.
  static const library = QIconData('library', [
    QRect(2.5, 4, 4, 16, r: 1.25),
    QRect(8.25, 4, 4, 16, r: 1.25, fill: QFill.active),
    QPath('M13.84 18.96L17.72 4.47L21.58 5.51L17.7 20z'),
  ]);

  /// 计划: calendar with a bookmark hanging on the date grid.
  static const schedule = QIconData('schedule', [
    ..._calendar,
    QPath('M13.5 13h3.5v5l-1.75-1.4L13.5 18z', fill: QFill.active),
  ]);

  /// 复习: a returning arrow around a bookmark.
  static const review = QIconData('review', [
    QPath('M4 12a8 8 0 1 0 8-8a8 8 0 0 0-5.66 2.34'),
    QPath('M6.34 2.6v3.74h3.74'),
    QPath('M10.25 8.75h3.5v6.5l-1.75-1.4-1.75 1.4z', fill: QFill.active),
  ]);

  /// 设置: three sliders.
  static const settings = QIconData('settings', [
    QLine(4, 6.5, 13, 6.5),
    QCircle(15, 6.5, 2),
    QLine(17, 6.5, 20, 6.5),
    QLine(4, 12, 7, 12),
    QCircle(9, 12, 2),
    QLine(11, 12, 20, 12),
    QLine(4, 17.5, 12, 17.5),
    QCircle(14, 17.5, 2),
    QLine(16, 17.5, 20, 17.5),
  ]);

  /// 侧栏开合.
  static const sidebar = QIconData('sidebar', [
    QRect(3, 4.5, 18, 15, r: 2.5),
    QLine(9.5, 4.5, 9.5, 19.5),
  ]);

  /// 返回.
  static const back = QIconData('back', [
    QLine(19, 12, 5, 12),
    QPath('M11 6l-6 6 6 6'),
  ]);

  // ---------------------------------------------------------------------------
  // Documents & reader
  // ---------------------------------------------------------------------------

  /// 教材: the folio with its swallowtail bookmark and evidence line.
  static const textbook = QIconData('textbook', [
    QRect(5, 3, 14, 18, r: 2.5),
    QPath('M10.5 3v7l1.5-1.25 1.5 1.25V3', fill: QFill.active),
    QLine(8.5, 17, 13, 17),
  ]);

  /// 论文: a folio with a folded corner and two text lines.
  static const paper = QIconData('paper', [
    QPath(
      'M14 3H7.5A2.5 2.5 0 0 0 5 5.5v13A2.5 2.5 0 0 0 7.5 21h9'
      'a2.5 2.5 0 0 0 2.5-2.5V8z',
    ),
    QPath('M14 3v3.5A1.5 1.5 0 0 0 15.5 8H19'),
    QLine(8.5, 12.5, 15.5, 12.5),
    QLine(8.5, 16, 13, 16),
  ]);

  /// 学习: an open book with a bookmark on the right page.
  static const study = QIconData('study', [
    QPath('M3 5h5a4 4 0 0 1 4 4v11a3 3 0 0 0-3-3H3z'),
    QPath('M21 5h-5a4 4 0 0 0-4 4v11a3 3 0 0 1 3-3h6z'),
    QPath('M15.5 5v5l1.25-1 1.25 1V5', fill: QFill.active),
  ]);

  /// 跳页 / 页码.
  static const page = QIconData('page', [
    QLine(4.5, 9, 19.5, 9),
    QLine(4.5, 15, 19.5, 15),
    QLine(10, 4, 8, 20),
    QLine(16, 4, 14, 20),
  ]);

  /// 识别文字 (OCR).
  static const ocr = QIconData('ocr', [
    ..._corners,
    QLine(7.5, 9, 16.5, 9),
    QLine(7.5, 12, 16.5, 12),
    QLine(7.5, 15, 13, 15),
  ]);

  /// 框选.
  static const region = QIconData('region', [..._corners]);

  /// 框选提问 / 以图查找.
  static const regionSearch = QIconData('regionSearch', [
    ..._corners,
    QCircle(11, 11, 3.5),
    QLine(13.6, 13.6, 16, 16),
  ]);

  /// 清除选区.
  static const clear = QIconData('clear', [
    ..._corners,
    QLine(9.5, 9.5, 14.5, 14.5),
    QLine(14.5, 9.5, 9.5, 14.5),
  ]);

  /// 适应页面.
  static const fit = QIconData('fit', [
    QRect(3, 4.5, 18, 15, r: 2.5),
    QRect(7.5, 8.5, 9, 7, r: 1),
  ]);

  /// 旋转.
  static const rotate = QIconData('rotate', [
    QPath('M20 12a8 8 0 1 1-8-8c2.24 0 4.38.89 5.99 2.44L20 8.5'),
    QPath('M20 4v4.5h-4.5'),
  ]);

  /// 鼠标 / 手势提示 (scroll to zoom, drag to pan).
  static const mouse = QIconData('mouse', [
    QRect(6.5, 3, 11, 18, r: 5.5),
    QLine(12, 7, 12, 10),
  ]);

  // ---------------------------------------------------------------------------
  // Learning & AI
  // ---------------------------------------------------------------------------

  /// AI 生成: a single spark resting on the evidence line.
  static const ai = QIconData('ai', [
    QPath(
      'M12 4Q12.9 9.6 18.5 10.5Q12.9 11.4 12 17Q11.1 11.4 5.5 10.5'
      'Q11.1 9.6 12 4z',
    ),
    QLine(7.5, 20.5, 16.5, 20.5),
  ]);

  /// 原文锚点: the brand's solid bookmark on the evidence line.
  static const anchor = QIconData('anchor', [
    QPath('M8.5 3.5h7v11.5l-3.5-2.8-3.5 2.8z', fill: QFill.solid),
    QLine(5, 20, 19, 20),
  ]);

  /// 主动回忆: a speech bubble with a returning loop.
  static const recall = QIconData('recall', [
    _bubble,
    QPath('M8.75 10.5a3.25 3.25 0 1 0 3.25-3.25a3.25 3.25 0 0 0-2.3.95'),
    QPath('M9.7 5.7v2.5h2.5'),
  ]);

  /// 问答.
  static const qa = QIconData('qa', [
    _bubble,
    QLine(7.5, 8.75, 16.5, 8.75),
    QLine(7.5, 12.25, 13, 12.25),
  ]);

  /// 笔记: a folio with a pen resting on its corner.
  static const notes = QIconData('notes', [
    QPath(
      'M11.5 21H7.5A2.5 2.5 0 0 1 5 18.5v-13A2.5 2.5 0 0 1 7.5 3h9'
      'A2.5 2.5 0 0 1 19 5.5V9',
    ),
    QLine(8.5, 8, 15.5, 8),
    QLine(8.5, 11.5, 12.5, 11.5),
    QPath('M18.25 12.25l2.5 2.5-5.75 5.75H12.5V18z'),
  ]);

  /// 核对作答.
  static const verify = QIconData('verify', [
    QRect(4.5, 3, 15, 18, r: 2.5),
    QLine(8, 7.5, 16, 7.5),
    QLine(8, 11, 13, 11),
    QPath('M8.5 15.5l2 2 4.5-4.5'),
  ]);

  /// 知识结构.
  static const knowledge = QIconData('knowledge', [
    QRect(9, 3, 6, 5, r: 1.5),
    QRect(3, 16, 6, 5, r: 1.5),
    QRect(15, 16, 6, 5, r: 1.5),
    QLine(12, 8, 12, 12),
    QPath('M6 16v-2a2 2 0 0 1 2-2h8a2 2 0 0 1 2 2v2'),
  ]);

  /// 模型服务.
  static const model = QIconData('model', [
    QRect(6, 6, 12, 12, r: 2.5),
    QRect(9.5, 9.5, 5, 5, r: 1),
    QLine(9.5, 3, 9.5, 6),
    QLine(14.5, 3, 14.5, 6),
    QLine(9.5, 18, 9.5, 21),
    QLine(14.5, 18, 14.5, 21),
    QLine(3, 9.5, 6, 9.5),
    QLine(3, 14.5, 6, 14.5),
    QLine(18, 9.5, 21, 9.5),
    QLine(18, 14.5, 21, 14.5),
  ]);

  /// 翻译.
  static const translate = QIconData('translate', [
    QLine(5, 8, 11, 14),
    QPath('M4 14l6-6 2-3'),
    QLine(3, 5, 14, 5),
    QLine(8, 2.5, 8, 5),
    QPath('M21 20.5l-4.5-9.5-4.5 9.5'),
    QLine(13.5, 17.5, 19.5, 17.5),
  ]);

  /// 联网检索.
  static const web = QIconData('web', [
    _ring,
    QLine(3, 12, 21, 12),
    QPath('M12 3a14 14 0 0 1 0 18a14 14 0 0 1 0-18'),
  ]);

  /// 深度查找.
  static const deepSearch = QIconData('deepSearch', [
    QLine(3, 5, 19, 5),
    QLine(3, 10.5, 7, 10.5),
    QLine(3, 16, 7, 16),
    QCircle(14.5, 13.5, 4.5),
    QLine(17.8, 16.8, 21, 20),
  ]);

  /// 键盘 / 快捷键.
  static const keyboard = QIconData('keyboard', [
    QRect(2.5, 5.5, 19, 13, r: 2.5),
    QCircle(6.5, 9.5, .5, fill: QFill.solid),
    QCircle(10, 9.5, .5, fill: QFill.solid),
    QCircle(13.5, 9.5, .5, fill: QFill.solid),
    QCircle(17.5, 9.5, .5, fill: QFill.solid),
    QCircle(8.25, 12.5, .5, fill: QFill.solid),
    QCircle(12, 12.5, .5, fill: QFill.solid),
    QCircle(15.75, 12.5, .5, fill: QFill.solid),
    QLine(8, 15.5, 16, 15.5),
  ]);

  // ---------------------------------------------------------------------------
  // Planning
  // ---------------------------------------------------------------------------

  /// 计划列表.
  static const plan = QIconData('plan', [
    ..._calendar,
    QLine(7.5, 13.75, 16.5, 13.75),
    QLine(7.5, 16.75, 12.5, 16.75),
  ]);

  /// 今天.
  static const today = QIconData('today', [
    ..._calendar,
    QRect(7.5, 13, 4, 4, r: 1, fill: QFill.solid),
  ]);

  /// 已完成.
  static const done = QIconData('done', [
    ..._calendar,
    QPath('M9 15.25l2 2 4-4'),
  ]);

  /// 错过 / 冲突.
  static const missed = QIconData('missed', [
    ..._calendar,
    QLine(9.75, 12.75, 14.25, 17.25),
    QLine(14.25, 12.75, 9.75, 17.25),
  ]);

  /// 重复.
  static const repeat = QIconData('repeat', [
    QPath('M17 3l3.5 3.5L17 10'),
    QPath('M3.5 11v-1a3.5 3.5 0 0 1 3.5-3.5h13.5'),
    QPath('M7 21l-3.5-3.5L7 14'),
    QPath('M20.5 13v1a3.5 3.5 0 0 1-3.5 3.5H3.5'),
  ]);

  /// 里程碑: a swallowtail flag.
  static const milestone = QIconData('milestone', [
    QLine(5, 21, 5, 3.5),
    QPath('M5 4h13l-3 4.5 3 4.5H5', fill: QFill.active),
  ]);

  /// 时长.
  static const duration = QIconData('duration', [
    _ring,
    QPath('M12 7v5l3.5 2'),
  ]);

  /// 追赶进度.
  static const catchUp = QIconData('catchUp', [
    QPath('M5.5 6l6 6-6 6'),
    QPath('M12.5 6l6 6-6 6'),
  ]);

  /// 休息日.
  static const rest = QIconData('rest', [
    QPath('M12 3a6 6 0 0 0 9 9a9 9 0 1 1-9-9z'),
  ]);

  /// 锁定.
  static const lock = QIconData('lock', [
    QRect(5, 11, 14, 10, r: 2.5),
    QPath('M8 11V7.5a4 4 0 0 1 8 0V11'),
  ]);

  /// 加入任务.
  static const addTask = QIconData('addTask', [
    QLine(4, 6, 16, 6),
    QLine(4, 11, 16, 11),
    QLine(4, 16, 11, 16),
    QLine(18, 14, 18, 20),
    QLine(15, 17, 21, 17),
  ]);

  /// 学习路径.
  static const route = QIconData('route', [
    QCircle(6, 18.5, 2.25),
    QPath(
      'M8.25 18.5H16C18 18.5 19.25 17.1 19.25 15.25S18 12 16 12H8'
      'C6 12 4.75 10.6 4.75 8.75S6 5.5 8 5.5h7.75',
    ),
    QCircle(18, 5.5, 2.25),
  ]);

  // ---------------------------------------------------------------------------
  // Actions
  // ---------------------------------------------------------------------------

  static const add = QIconData('add', [
    QLine(12, 5, 12, 19),
    QLine(5, 12, 19, 12),
  ]);

  static const edit = QIconData('edit', [
    QPath('M16.5 3.5a2.12 2.12 0 0 1 3 3L8 18l-4 1 1-4z'),
    QLine(14.5, 5.5, 17.5, 8.5),
  ]);

  static const delete = QIconData('delete', [
    QLine(4, 6.5, 20, 6.5),
    QPath('M18 6.5V19a2 2 0 0 1-2 2H8a2 2 0 0 1-2-2V6.5'),
    QPath('M9 6.5v-2A1.5 1.5 0 0 1 10.5 3h3A1.5 1.5 0 0 1 15 4.5v2'),
    QLine(10, 11, 10, 16.5),
    QLine(14, 11, 14, 16.5),
  ]);

  static const copy = QIconData('copy', [
    QRect(8.5, 8.5, 12.5, 12.5, r: 2.5),
    QPath(
      'M15.5 8.5v-3A2.5 2.5 0 0 0 13 3H5.5A2.5 2.5 0 0 0 3 5.5V13'
      'a2.5 2.5 0 0 0 2.5 2.5h3',
    ),
  ]);

  static const search = QIconData('search', [
    QCircle(10.5, 10.5, 6.5),
    QLine(15.5, 15.5, 20.5, 20.5),
  ]);

  static const searchEmpty = QIconData('searchEmpty', [
    QCircle(10.5, 10.5, 6.5),
    QLine(15.5, 15.5, 20.5, 20.5),
    QLine(8.5, 8.5, 12.5, 12.5),
    QLine(12.5, 8.5, 8.5, 12.5),
  ]);

  static const refresh = QIconData('refresh', [
    QPath('M4 12a8 8 0 0 1 13.66-5.66L20 8.5'),
    QPath('M20 4v4.5h-4.5'),
    QPath('M20 12a8 8 0 0 1-13.66 5.66L4 15.5'),
    QPath('M4 20v-4.5h4.5'),
  ]);

  static const undo = QIconData('undo', [
    QPath('M9 14L4 9l5-5'),
    QPath('M4 9h10.5a5.5 5.5 0 0 1 0 11H11'),
  ]);

  /// 发送 (chat composer and send preview).
  static const send = QIconData('send', [
    QLine(12, 19, 12, 5),
    QPath('M6 11l6-6 6 6'),
  ]);

  static const play = QIconData('play', [
    QPath('M7.5 5.2v13.6a.8.8 0 0 0 1.2.7l10.7-6.8a.8.8 0 0 0 0-1.4L8.7 4.5'
        'a.8.8 0 0 0-1.2.7z'),
  ]);

  static const pause = QIconData('pause', [
    QLine(9, 5.5, 9, 18.5),
    QLine(15, 5.5, 15, 18.5),
  ]);

  static const stop = QIconData('stop', [
    QRect(6.5, 6.5, 11, 11, r: 2, fill: QFill.solid),
  ]);

  /// 在新窗口打开.
  static const external = QIconData('external', [
    QPath('M14 4h6v6'),
    QLine(20, 4, 11, 13),
    QPath(
      'M18 14v4.5a2.5 2.5 0 0 1-2.5 2.5h-10A2.5 2.5 0 0 1 3 18.5v-10'
      'A2.5 2.5 0 0 1 5.5 6H10',
    ),
  ]);

  static const link = QIconData('link', [
    QPath('M9.5 14.5l5-5'),
    QPath(
      'M11 7.5l2-2a4.24 4.24 0 0 1 6 6l-2 2',
    ),
    QPath(
      'M13 16.5l-2 2a4.24 4.24 0 0 1-6-6l2-2',
    ),
  ]);

  static const unlink = QIconData('unlink', [
    QPath('M11 7.5l2-2a4.24 4.24 0 0 1 6 6l-2 2'),
    QPath('M13 16.5l-2 2a4.24 4.24 0 0 1-6-6l2-2'),
    QLine(8.5, 4, 8.5, 6.5),
    QLine(4, 8.5, 6.5, 8.5),
    QLine(15.5, 17.5, 15.5, 20),
    QLine(17.5, 15.5, 20, 15.5),
  ]);

  /// 更多 (single horizontal form; the vertical variant is retired).
  static const more = QIconData('more', [
    QCircle(5.5, 12, 1, fill: QFill.solid),
    QCircle(12, 12, 1, fill: QFill.solid),
    QCircle(18.5, 12, 1, fill: QFill.solid),
  ]);

  static const sort = QIconData('sort', [
    QLine(7, 20, 7, 4),
    QPath('M3 8l4-4 4 4'),
    QLine(17, 4, 17, 20),
    QPath('M13 16l4 4 4-4'),
  ]);

  /// 筛选: a funnel narrowing to a short stem.
  static const filter = QIconData('filter', [
    QPath('M3.5 5h17l-6.5 7.6V20l-4-2.2v-5.2z'),
  ]);

  static const close = QIconData('close', [
    QLine(6, 6, 18, 18),
    QLine(18, 6, 6, 18),
  ]);

  static const check = QIconData('check', [
    QPath('M4.5 12.5l5 5 10-10'),
  ]);

  static const visible = QIconData('visible', [
    _eye,
    QCircle(12, 12, 3),
  ]);

  static const hidden = QIconData('hidden', [
    _eye,
    QCircle(12, 12, 3),
    QLine(4, 4, 20, 20),
  ]);

  // ---------------------------------------------------------------------------
  // Direction
  // ---------------------------------------------------------------------------

  static const chevronRight = QIconData('chevronRight', [
    QPath('M9 5.5l6.5 6.5L9 18.5'),
  ]);

  static const chevronLeft = QIconData('chevronLeft', [
    QPath('M15 5.5L8.5 12l6.5 6.5'),
  ]);

  static const chevronUp = QIconData('chevronUp', [
    QPath('M5.5 15L12 8.5l6.5 6.5'),
  ]);

  static const chevronDown = QIconData('chevronDown', [
    QPath('M5.5 9l6.5 6.5L18.5 9'),
  ]);

  // ---------------------------------------------------------------------------
  // Status
  // ---------------------------------------------------------------------------

  static const success = QIconData('success', [
    _ring,
    QPath('M8 12.25l2.75 2.75L16 9.75'),
  ]);

  static const info = QIconData('info', [
    _ring,
    QLine(12, 11, 12, 16.5),
    QCircle(12, 7.75, .5, fill: QFill.solid),
  ]);

  static const warning = QIconData('warning', [
    QPath(
      'M10.6 4.5a1.6 1.6 0 0 1 2.8 0l7.1 12.6a1.6 1.6 0 0 1-1.4 2.4H4.9'
      'a1.6 1.6 0 0 1-1.4-2.4z',
    ),
    QLine(12, 9.5, 12, 13.5),
    QCircle(12, 16.5, .5, fill: QFill.solid),
  ]);

  static const error = QIconData('error', [
    _ring,
    QLine(12, 7.5, 12, 12.5),
    QCircle(12, 16, .5, fill: QFill.solid),
  ]);

  /// 本机 / 隐私.
  static const local = QIconData('local', [
    QPath(
      'M12 3l7.5 3v5.5c0 4.6-3.2 8.3-7.5 9.5-4.3-1.2-7.5-4.9-7.5-9.5V6z',
    ),
  ]);

  /// 云端服务商.
  static const cloud = QIconData('cloud', [
    QPath(
      'M6.5 18.5h11a3.5 3.5 0 0 0 .4-6.98A5.5 5.5 0 0 0 7.2 9.5'
      'a4.5 4.5 0 0 0-.7 9z',
    ),
  ]);

  /// 计费: a receipt with a torn edge.
  static const billing = QIconData('billing', [
    QPath(
      'M5.5 3h13v18l-2.17-1.5L14.17 21 12 19.5 9.83 21l-2.16-1.5L5.5 21z',
    ),
    QLine(9, 8, 15, 8),
    QLine(9, 11.5, 15, 11.5),
    QLine(9, 15, 12.5, 15),
  ]);

  /// Step done (filled dot).
  static const dot = QIconData('dot', [
    QCircle(12, 12, 4, fill: QFill.solid),
  ]);

  /// Step to do (ring).
  static const ring = QIconData('ring', [QCircle(12, 12, 4)]);

  // ---------------------------------------------------------------------------
  // Library
  // ---------------------------------------------------------------------------

  /// 文件夹: a folio folder with a raised tab.
  static const folder = QIconData('folder', [
    QPath(
      'M3 7.5A2.5 2.5 0 0 1 5.5 5h3.2l1.8 2h8A2.5 2.5 0 0 1 21 9.5v7'
      'A2.5 2.5 0 0 1 18.5 19h-13A2.5 2.5 0 0 1 3 16.5z',
    ),
  ]);

  /// 打开的文件夹: the same folio with a lifted front panel.
  static const folderOpen = QIconData('folderOpen', [
    QPath('M3 7.5A2.5 2.5 0 0 1 5.5 5h3.2l1.8 2h7.5A2.5 2.5 0 0 1 20.5 9.5v1'),
    QPath('M3 16.5V9.5h18.2l-2.4 7.6a2.5 2.5 0 0 1-2.4 1.9H5.5A2.5 2.5 0 0 1 3 16.5z'),
  ]);

  /// 星标: the bookmark family's five-point star.
  static const star = QIconData('star', [
    QPath(
      'M12 3.6l2.55 5.17 5.7.83-4.13 4.02.98 5.68L12 16.62l-5.1 2.68.98-5.68'
      'L3.75 9.6l5.7-.83z',
      fill: QFill.active,
    ),
  ]);

  /// 标签: a luggage tag with its eyelet.
  static const tag = QIconData('tag', [
    QPath(
      'M4 4h7.2a2 2 0 0 1 1.42.59l6.8 6.8a2 2 0 0 1 0 2.83l-3.2 3.2'
      'a2 2 0 0 1-2.83 0l-6.8-6.8A2 2 0 0 1 6 9.2z',
    ),
    QCircle(9, 9, 1.2),
  ]);

  /// 回收站: a lidded bin.
  static const trash = QIconData('trash', [
    QLine(4, 7, 20, 7),
    QPath('M9 7V4.8h6V7'),
    QPath('M6 7l1 12.2A1.8 1.8 0 0 0 8.8 21h6.4a1.8 1.8 0 0 0 1.8-1.8L18 7'),
    QLine(10, 11, 10, 17.5),
    QLine(14, 11, 14, 17.5),
  ]);

  /// 恢复: an arrow returning into a tray.
  static const restore = QIconData('restore', [
    QPath('M4 12a8 8 0 1 0 8-8a8 8 0 0 0-5.66 2.34'),
    QPath('M6.34 2.6v3.74h3.74'),
    QLine(12, 8, 12, 12.5),
    QLine(12, 12.5, 15.5, 14.5),
  ]);

  /// 移动: a document moving into another folder.
  static const move = QIconData('move', [
    QPath('M3 7.5A2.5 2.5 0 0 1 5.5 5h3.2l1.8 2h4.5'),
    QPath('M3 16.5V8.5h16.2'),
    QPath('M13 12.5l4 4-4 4'),
    QLine(9, 16.5, 17, 16.5),
  ]);

  /// 快捷方式: a document with an outbound corner arrow.
  static const shortcut = QIconData('shortcut', [
    QPath('M13.5 4.5H5.5A1.5 1.5 0 0 0 4 6v12a1.5 1.5 0 0 0 1.5 1.5h12A1.5 1.5 0 0 0 19 18v-8'),
    QPath('M14.5 3.5h6v6'),
    QPath('M20.2 3.8l-8 8'),
  ]);

  static const grid = QIconData('grid', [
    QRect(4, 4, 7, 7, r: 1.5),
    QRect(13, 4, 7, 7, r: 1.5),
    QRect(4, 13, 7, 7, r: 1.5),
    QRect(13, 13, 7, 7, r: 1.5),
  ]);

  /// 列显示: a table divided into three columns.
  static const columns = QIconData('columns', [
    QRect(3.5, 4.5, 17, 15, r: 2),
    QLine(9.5, 4.5, 9.5, 19.5),
    QLine(14.5, 4.5, 14.5, 19.5),
  ]);

  static const list = QIconData('list', [
    QLine(8, 6.5, 20, 6.5),
    QLine(8, 12, 20, 12),
    QLine(8, 17.5, 20, 17.5),
    QCircle(4.5, 6.5, 1, fill: QFill.solid),
    QCircle(4.5, 12, 1, fill: QFill.solid),
    QCircle(4.5, 17.5, 1, fill: QFill.solid),
  ]);

  /// 外观: a palette with three wells.
  static const palette = QIconData('palette', [
    QPath(
      'M12 3a9 9 0 1 0 0 18c1.4 0 2.2-.8 2.2-1.8 0-1.4-1.2-1.9-1.2-3'
      ' 0-.9.7-1.2 1.6-1.2H16a5 5 0 0 0 5-5C21 6.5 17.1 3 12 3z',
    ),
    QCircle(8, 9, 1.1, fill: QFill.solid),
    QCircle(12.5, 7.2, 1.1, fill: QFill.solid),
    QCircle(7, 13.2, 1.1, fill: QFill.solid),
  ]);

  /// 导出: an outbound tray.
  static const download = QIconData('download', [
    QLine(12, 3.5, 12, 14),
    QPath('M8 10l4 4 4-4'),
    QPath('M4 15v3.5A1.5 1.5 0 0 0 5.5 20h13a1.5 1.5 0 0 0 1.5-1.5V15'),
  ]);

  /// 备份: an archive box.
  static const archive = QIconData('archive', [
    QRect(3.5, 4, 17, 5, r: 1.5),
    QPath('M5 9v9.5A1.5 1.5 0 0 0 6.5 20h11a1.5 1.5 0 0 0 1.5-1.5V9'),
    QLine(10, 13, 14, 13),
  ]);

  /// Every icon, in contact-sheet order.
  static const all = <QIconData>[
    library, schedule, review, settings, sidebar, back, //
    textbook, paper, study, page, ocr, region, regionSearch, clear, fit,
    rotate, mouse, //
    ai, anchor, recall, qa, notes, verify, knowledge, model, translate, web,
    deepSearch, keyboard, //
    plan, today, done, missed, repeat, milestone, duration, catchUp, rest,
    lock, addTask, route, //
    add, edit, delete, copy, search, searchEmpty, refresh, undo, send, play,
    pause, stop, external, link, unlink, more, sort, filter, close, check,
    visible, hidden, //
    chevronRight, chevronLeft, chevronUp, chevronDown, //
    success, info, warning, error, local, cloud, billing, dot, ring, //
    folder, folderOpen, star, tag, trash, restore, move, shortcut, grid, list, columns,
    palette, download, archive,
  ];
}
