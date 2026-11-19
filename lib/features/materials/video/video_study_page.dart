import 'dart:async';
import 'dart:io';
import 'dart:ui' as ui;

import 'package:file_picker/file_picker.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:media_kit/media_kit.dart';
import 'package:media_kit_video/media_kit_video.dart';

import '../../../app_controller.dart';
import '../../../core/models.dart';
import '../../../services/document_service.dart';
import '../../../ui/icons/q_icons.dart';
import '../../../ui/page_surface.dart';
import '../../../ui/shell/app_chrome.dart' show WindowCaptionControls;
import '../../../ui/shell/window_title_bar.dart';
import '../../notes/models/note_models.dart';
import '../../notes/notes_controller.dart';
import '../material_work.dart';
import '../ui/material_work_dialog.dart';

class VideoStudyPage extends StatefulWidget {
  const VideoStudyPage({
    super.key,
    required this.study,
    required this.document,
    required this.onBack,
    required this.notes,
    required this.openNote,
    this.showWindowChrome = false,
  });

  final StudyController study;
  final DocumentRecord document;
  final VoidCallback onBack;
  final NotesController notes;
  final ValueChanged<String> openNote;
  final bool showWindowChrome;

  @override
  State<VideoStudyPage> createState() => _VideoStudyPageState();
}

class _VideoStudyPageState extends State<VideoStudyPage>
    with WidgetsBindingObserver {
  final _videoKey = GlobalKey<VideoState>();
  Player? _player;
  VideoController? _video;
  StreamSubscription<String>? _errorSubscription;
  StreamSubscription<Duration>? _durationSubscription;
  Timer? _checkpoint;
  String? _error;
  bool _busy = false;
  bool _answers = false;
  double _unmuted = 100;
  double? _scrubbing;
  int _jumpSeen = -1;
  bool _loaded = false;
  RenderedPage? _located;

  StudyController get study => widget.study;
  DocumentRecord get doc => widget.document;
  MaterialWork get work => study.materialWork;

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addObserver(this);
    study.addListener(_followJump);
    unawaited(_initialize());
  }

  Future<void> _initialize() async {
    try {
      final file = File(doc.filePath);
      if (!await file.exists()) {
        throw StateError('原视频不在本机。请从资料库的存储管理中重新连接同一原件。');
      }
      if (!mounted) return;
      MediaKit.ensureInitialized();
      final player = Player(
        configuration: const PlayerConfiguration(
          title: 'Quelyt',
          protocolWhitelist: ['file', 'data', 'crypto'],
        ),
      );
      _player = player;
      _video = VideoController(player);
      setState(() {});
      _errorSubscription = player.stream.error.listen((message) {
        if (mounted) setState(() => _error = '无法播放此视频：$message');
      });
      _durationSubscription = player.stream.duration.listen((_) {
        if (mounted) setState(() {});
      });
      final saved = work.readState(doc, 'videoPosition') as int? ?? 0;
      await player.open(
        Media(file.uri.toString(), start: Duration(milliseconds: saved)),
        play: false,
      );
      if (!mounted) return;
      _loaded = true;
      _checkpoint = Timer.periodic(
        const Duration(seconds: 5),
        (_) => _saveProgress(),
      );
      _followJump();
      setState(() {});
    } catch (error) {
      if (mounted) setState(() => _error = '$error');
    }
  }

  void _saveProgress() {
    final state = _player?.state;
    if (!_loaded || state == null || state.duration == Duration.zero) return;
    try {
      work.saveState(doc, 'videoPosition', state.position.inMilliseconds);
    } catch (_) {
      // A closing or removed library is no longer writable.
    }
  }

  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    if (state == AppLifecycleState.paused ||
        state == AppLifecycleState.detached) {
      _saveProgress();
      unawaited(_player?.pause());
    }
  }

  @override
  void dispose() {
    WidgetsBinding.instance.removeObserver(this);
    study.removeListener(_followJump);
    _checkpoint?.cancel();
    _saveProgress();
    unawaited(_errorSubscription?.cancel());
    unawaited(_durationSubscription?.cancel());
    unawaited(_player?.dispose());
    super.dispose();
  }

  void _followJump() {
    final timestamp = study.videoJumpMs;
    if (!_loaded ||
        timestamp == null ||
        study.current?.id != doc.id ||
        _jumpSeen == study.videoJumpRevision) {
      return;
    }
    _jumpSeen = study.videoJumpRevision;
    unawaited(_jumpTo(timestamp, region: study.highlight));
  }

  Future<void> _jumpTo(int timestamp, {SourceRegion? region}) async {
    final player = _player!;
    await player.pause();
    await player.seek(Duration(milliseconds: timestamp));
    final frame = region != null && region != SourceRegion.fullPage
        ? await _capture()
        : null;
    if (mounted) setState(() => _located = frame?.$2);
    _saveProgress();
  }

  Future<void> _seek(Duration target) async {
    final player = _player;
    if (player == null) return;
    if (_located != null) setState(() => _located = null);
    final position = target.inMilliseconds.clamp(
      0,
      player.state.duration.inMilliseconds,
    );
    await player.seek(Duration(milliseconds: position));
    _saveProgress();
  }

  Future<void> _toggle() async {
    final player = _player;
    if (player == null) return;
    if (_located != null) setState(() => _located = null);
    await player.playOrPause();
    _saveProgress();
  }

  Future<(int, RenderedPage)?> _capture() async {
    final player = _player;
    if (!_loaded || player == null) return null;
    await player.pause();
    final pos = player.state.position.inMilliseconds;
    Uint8List? image;
    for (var attempt = 0; attempt < 4 && image == null; attempt++) {
      image = await player.screenshot(format: 'image/png');
      if (image == null) {
        await Future<void>.delayed(const Duration(milliseconds: 90));
      }
    }
    if (player.platform case final NativePlayer native when image == null) {
      await native.setProperty('hwdec', 'no');
      await player.seek(Duration(milliseconds: pos));
      await Future<void>.delayed(const Duration(milliseconds: 220));
      image = await player.screenshot(format: 'image/png');
    }
    if (image == null) return null;
    var timestamp = player.state.position.inMilliseconds;
    if (player.platform case final NativePlayer native) {
      final value = double.tryParse(await native.getProperty('time-pos'));
      if (value != null && value.isFinite && value >= 0) {
        timestamp = (value * 1000).round();
      }
    }
    final codec = await ui.instantiateImageCodec(image);
    try {
      final frame = await codec.getNextFrame();
      try {
        return (
          timestamp,
          RenderedPage(image, frame.image.width, frame.image.height),
        );
      } finally {
        frame.image.dispose();
      }
    } finally {
      codec.dispose();
    }
  }

  Future<void> _guard(Future<void> Function() operation) async {
    if (_busy || !_loaded) return;
    setState(() => _busy = true);
    try {
      await operation();
    } catch (error) {
      if (mounted) {
        ScaffoldMessenger.of(context)
            .showSnackBar(SnackBar(content: Text('$error')));
      }
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  Future<void> _newNote() => _guard(() async {
    final timestamp = _player!.state.position.inMilliseconds;
    final frame = await _capture();
    if (!mounted) return;
    final body = TextEditingController();
    var attach = false;
    final (int, String, bool)? input;
    try {
      input = await showDialog<(int, String, bool)>(
        context: context,
        builder: (context) => StatefulBuilder(
          builder: (context, setState) => AlertDialog(
            title: Text('视频笔记 · ${formatMaterialTime(frame?.$1 ?? timestamp)}'),
            content: SizedBox(
              width: 500,
              child: SingleChildScrollView(
                child: Column(
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    TextField(
                      controller: body,
                      autofocus: true,
                      minLines: 3,
                      maxLines: 8,
                      decoration: const InputDecoration(labelText: '我的笔记'),
                    ),
                    if (frame != null)
                      CheckboxListTile(
                        value: attach,
                        onChanged: (value) =>
                            setState(() => attach = value == true),
                        title: const Text('附上暂停画面'),
                      ),
                  ],
                ),
              ),
            ),
            actions: [
              TextButton(
                onPressed: () => Navigator.pop(context),
                child: const Text('取消'),
              ),
              FilledButton(
                onPressed: () => Navigator.pop(context, (
                  frame?.$1 ?? timestamp,
                  body.text.trim(),
                  attach,
                )),
                child: const Text('保存'),
              ),
            ],
          ),
        ),
      );
    } finally {
      body.dispose();
    }
    if (input == null || input.$2.isEmpty || !mounted) return;
    final asset = input.$3 && frame != null
        ? await work.keepSnapshot(frame.$2.bytes)
        : null;
    if (!mounted) return;
    final label = formatMaterialTime(input.$1);
    final created = widget.notes.createNote(
      title: '${doc.title} · $label',
      body: input.$2,
      folderId: study.noteRepository.folderForDocument(doc.id),
      sources: [
        NoteSource(
          id: '',
          noteId: '',
          documentId: doc.id,
          documentHash: doc.contentHash,
          page: 1,
          timeMs: input.$1,
          locatorLabel: label,
          title: doc.title,
          sourceType: 'video',
          assetName: asset,
          createdAt: DateTime.now(),
        ),
      ],
    );
    if (created != null && mounted) {
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(
          content: const Text('已保存时间点笔记'),
          action: SnackBarAction(
            label: '打开笔记',
            onPressed: () => widget.openNote(created.id),
          ),
        ),
      );
    }
  });

  Future<void> _askFrame() => _guard(() async {
    final frame = await _capture();
    if (frame == null) throw StateError('暂未取到暂停画面，请定位到有画面的时间后重试。');
    if (!mounted) return;
    final selection = await showDialog<(SourceRegion, String)>(
      context: context,
      builder: (_) => _FrameQuestion(frame.$1, frame.$2),
    );
    if (selection == null || !mounted) return;
    final bytes = await cropPage(frame.$2, selection.$1);
    final request = await work.preparePictureQuestion(
      document: doc,
      settings: study.settings,
      question: selection.$2,
      png: bytes,
      region: selection.$1,
      timeMs: frame.$1,
    );
    if (!mounted) {
      await request.close();
      return;
    }
    final result = await showMaterialWork(context, study, request);
    if (result != null && mounted) setState(() => _answers = true);
  });

  Future<void> _subtitle() => _guard(() async {
    final result = await FilePicker.platform.pickFiles(
      type: FileType.custom,
      allowedExtensions: ['srt'],
    );
    final path = result?.files.single.path;
    if (path != null) {
      await _player!.setSubtitleTrack(
        SubtitleTrack.uri(File(path).uri.toString()),
      );
    }
  });

  Future<void> _tracks(bool subtitles) async {
    final player = _player;
    if (player == null) return;
    final tracks = subtitles
        ? player.state.tracks.subtitle
        : player.state.tracks.audio;
    await showDialog<void>(
      context: context,
      builder: (context) => AlertDialog(
        title: Text(subtitles ? '选择字幕' : '选择音轨'),
        content: SizedBox(
          width: 450,
          child: ListView(
            shrinkWrap: true,
            children: [
              for (final track in tracks)
                ListTile(
                  title: Text(track.title ?? track.language ?? track.id),
                  onTap: () {
                    Navigator.pop(context);
                    if (track is AudioTrack) {
                      unawaited(player.setAudioTrack(track));
                    } else if (track is SubtitleTrack) {
                      unawaited(player.setSubtitleTrack(track));
                    }
                  },
                ),
            ],
          ),
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(context),
            child: const Text('关闭'),
          ),
        ],
      ),
    );
  }

  Widget _studyPanel() {
    final answers = work.results(doc, MaterialAction.videoQuestion);
    final notes = study.noteRepository.notesReferencing(doc.id, limit: 100);
    return Column(
      children: [
        Padding(
          padding: const EdgeInsets.all(10),
          child: Wrap(
            spacing: 6,
            children: [
              ChoiceChip(
                label: const Text('时间点笔记'),
                selected: !_answers,
                onSelected: (_) => setState(() => _answers = false),
              ),
              ChoiceChip(
                label: const Text('画面问答'),
                selected: _answers,
                onSelected: (_) => setState(() => _answers = true),
              ),
            ],
          ),
        ),
        Expanded(
          child: ListView(
            padding: const EdgeInsets.symmetric(horizontal: 10),
            children: _answers
                ? [
                    if (answers.isEmpty)
                      const ListTile(title: Text('暂停后可框选画面提问')),
                    for (final answer in answers)
                      MaterialResultView(
                        study: study,
                        document: doc,
                        action: MaterialAction.videoQuestion,
                        result: answer,
                        notes: widget.notes,
                        onJump: study.jumpToEvidence,
                        openNote: widget.openNote,
                      ),
                  ]
                : [
                    if (notes.isEmpty)
                      const ListTile(title: Text('这里会显示本视频的笔记')),
                    for (final note in notes)
                      for (final source in study.noteRepository.sources(
                        note.id,
                      ))
                        if (source.documentId == doc.id &&
                            source.documentHash == doc.contentHash &&
                            source.timeMs != null)
                          ListTile(
                            title: Text(note.displayTitle),
                            subtitle: Text(formatMaterialTime(source.timeMs!)),
                            leading: IconButton(
                              tooltip: '跳回时间点',
                              icon: const QIcon(QIcons.play),
                              onPressed: () => study.jumpToEvidence(
                                Evidence(
                                  id: source.id,
                                  documentId: doc.id,
                                  documentHash: doc.contentHash,
                                  page: 1,
                                  region: source.region,
                                  text: source.excerpt,
                                  timeMs: source.timeMs,
                                ),
                              ),
                            ),
                            onTap: () => widget.openNote(note.id),
                          ),
                  ],
          ),
        ),
      ],
    );
  }

  Widget _stage() {
    final player = _player;
    final video = _video;
    if (player == null || video == null) {
      return Center(
        child: _error == null
            ? const CircularProgressIndicator()
            : Text(_error!),
      );
    }
    return Column(
      children: [
        Expanded(
          child: Stack(
            fit: StackFit.expand,
            children: [
              Video(
                key: _videoKey,
                controller: video,
                controls: (state) => state.isFullscreen()
                    ? AdaptiveVideoControls(state)
                    : const SizedBox.shrink(),
              ),
              if (_located case final frame?)
                PageSurface(
                  page: frame,
                  selection: null,
                  highlight: study.highlight,
                  onSelect: (_) {},
                ),
            ],
          ),
        ),
        StreamBuilder<Duration>(
          stream: player.stream.position,
          builder: (context, snapshot) {
            final duration = player.state.duration.inMilliseconds;
            final position =
                (snapshot.data ?? player.state.position).inMilliseconds;
            return Column(
              children: [
                Slider(
                  value: (_scrubbing ?? position.toDouble())
                      .clamp(0, duration)
                      .toDouble(),
                  max: duration > 0 ? duration.toDouble() : 1,
                  onChanged: duration <= 0
                      ? null
                      : (value) => setState(() => _scrubbing = value),
                  onChangeEnd: (value) {
                    setState(() => _scrubbing = null);
                    _seek(Duration(milliseconds: value.round()));
                  },
                ),
                Wrap(
                  alignment: WrapAlignment.center,
                  crossAxisAlignment: WrapCrossAlignment.center,
                  children: [
                    Tooltip(
                      message: '后退 5 秒',
                      child: TextButton.icon(
                        icon: const QIcon(
                          QIcons.chevronLeft,
                          size: IconSizes.sm,
                        ),
                        label: const Text('5 秒'),
                        onPressed: () =>
                            _seek(Duration(milliseconds: position - 5000)),
                      ),
                    ),
                    StreamBuilder<bool>(
                      stream: player.stream.playing,
                      builder: (context, snapshot) => IconButton(
                        tooltip: snapshot.data == true ? '暂停' : '播放',
                        icon: QIcon(
                          snapshot.data == true ? QIcons.pause : QIcons.play,
                        ),
                        onPressed: _toggle,
                      ),
                    ),
                    Tooltip(
                      message: '前进 5 秒',
                      child: TextButton.icon(
                        iconAlignment: IconAlignment.end,
                        icon: const QIcon(
                          QIcons.chevronRight,
                          size: IconSizes.sm,
                        ),
                        label: const Text('5 秒'),
                        onPressed: () =>
                            _seek(Duration(milliseconds: position + 5000)),
                      ),
                    ),
                    Text(
                      '${formatMaterialTime(position).split('.').first} / ${formatMaterialTime(duration).split('.').first}',
                    ),
                    PopupMenuButton<double>(
                      tooltip: '播放倍速',
                      icon: const QIcon(QIcons.duration),
                      onSelected: player.setRate,
                      itemBuilder: (_) => [
                        for (final rate in [.5, .75, 1.0, 1.25, 1.5, 1.75, 2.0])
                          PopupMenuItem(value: rate, child: Text('$rate×')),
                      ],
                    ),
                    PopupMenuButton<String>(
                      tooltip: '音量、音轨与字幕',
                      icon: const QIcon(QIcons.settings),
                      onSelected: (value) async {
                        switch (value) {
                          case 'srt':
                            await _subtitle();
                          case 'audio':
                            await _tracks(false);
                          case 'subtitle':
                            await _tracks(true);
                          case 'mute':
                            if (player.state.volume > 0) {
                              _unmuted = player.state.volume;
                              await player.setVolume(0);
                            } else {
                              await player.setVolume(_unmuted);
                            }
                          default:
                            await player.setVolume(double.parse(value));
                        }
                      },
                      itemBuilder: (_) => const [
                        PopupMenuItem(value: 'mute', child: Text('静音 / 恢复')),
                        PopupMenuItem(value: '35', child: Text('音量 35%')),
                        PopupMenuItem(value: '70', child: Text('音量 70%')),
                        PopupMenuItem(value: '100', child: Text('音量 100%')),
                        PopupMenuItem(value: 'audio', child: Text('选择音轨')),
                        PopupMenuItem(value: 'subtitle', child: Text('选择字幕')),
                        PopupMenuItem(value: 'srt', child: Text('载入 SRT 字幕')),
                      ],
                    ),
                    IconButton(
                      tooltip: '全屏',
                      icon: const QIcon(QIcons.fit),
                      onPressed: () =>
                          _videoKey.currentState?.toggleFullscreen(),
                    ),
                  ],
                ),
              ],
            );
          },
        ),
        Wrap(
          spacing: 8,
          children: [
            FilledButton.tonalIcon(
              onPressed: _busy ? null : _newNote,
              icon: const QIcon(QIcons.notes, size: IconSizes.sm),
              label: const Text('记时间点'),
            ),
            OutlinedButton.icon(
              onPressed: _busy ? null : _askFrame,
              icon: const QIcon(QIcons.region, size: IconSizes.sm),
              label: const Text('框画面提问'),
            ),
          ],
        ),
        if (_error != null)
          Text(_error!, maxLines: 2, overflow: TextOverflow.ellipsis),
      ],
    );
  }

  @override
  Widget build(BuildContext context) => Scaffold(
    body: SafeArea(
      child: CallbackShortcuts(
        bindings: {
          const SingleActivator(LogicalKeyboardKey.space): () => _toggle(),
          const SingleActivator(LogicalKeyboardKey.arrowLeft): () {
            if (_player case final player?) {
              _seek(player.state.position - const Duration(seconds: 5));
            }
          },
          const SingleActivator(LogicalKeyboardKey.arrowRight): () {
            if (_player case final player?) {
              _seek(player.state.position + const Duration(seconds: 5));
            }
          },
          const SingleActivator(LogicalKeyboardKey.keyF): () =>
              _videoKey.currentState?.toggleFullscreen(),
        },
        child: Focus(
          autofocus: true,
          child: Column(
            children: [
              Row(
                children: [
                  IconButton(
                    tooltip: '返回资料库',
                    icon: const QIcon(QIcons.back),
                    onPressed: widget.onBack,
                  ),
                  Expanded(
                    child: WindowDragRegion(
                      child: Text(
                        doc.title,
                        maxLines: 1,
                        overflow: TextOverflow.ellipsis,
                      ),
                    ),
                  ),
                  const Padding(
                    padding: EdgeInsets.symmetric(horizontal: 12),
                    child: Text('视频'),
                  ),
                  if (widget.showWindowChrome) const WindowCaptionControls(),
                ],
              ),
              if (_busy) const LinearProgressIndicator(),
              Expanded(
                child: LayoutBuilder(
                  builder: (context, size) => size.maxWidth >= 820
                      ? Row(
                          children: [
                            Expanded(child: _stage()),
                            const VerticalDivider(),
                            SizedBox(width: 360, child: _studyPanel()),
                          ],
                        )
                      : Column(
                          children: [
                            SizedBox(
                              height: size.maxHeight * .62,
                              child: _stage(),
                            ),
                            Expanded(child: _studyPanel()),
                          ],
                        ),
                ),
              ),
            ],
          ),
        ),
      ),
    ),
  );
}

class _FrameQuestion extends StatefulWidget {
  const _FrameQuestion(this.timestamp, this.frame);
  final int timestamp;
  final RenderedPage frame;

  @override
  State<_FrameQuestion> createState() => _FrameQuestionState();
}

class _FrameQuestionState extends State<_FrameQuestion> {
  final _surface = GlobalKey<PageSurfaceState>();
  final _question = TextEditingController();
  SourceRegion? _region;

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addPostFrameCallback(
      (_) => _surface.currentState?.setSelecting(true),
    );
  }

  @override
  void dispose() {
    _question.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) => AlertDialog(
    title: Text('框选暂停画面 · ${formatMaterialTime(widget.timestamp)}'),
    content: SizedBox(
      width: 700,
      height: MediaQuery.sizeOf(context).height * .55,
      child: Column(
        children: [
          Expanded(
            child: PageSurface(
              key: _surface,
              page: widget.frame,
              selection: _region,
              highlight: null,
              onSelect: (value) => setState(() => _region = value),
            ),
          ),
          TextField(
            controller: _question,
            maxLines: 2,
            onChanged: (_) => setState(() {}),
            decoration: const InputDecoration(
              labelText: '你想问什么？',
              hintText: '拖动选框，纳入需要的图例或公式',
            ),
          ),
        ],
      ),
    ),
    actions: [
      TextButton(
        onPressed: () => Navigator.pop(context),
        child: const Text('取消'),
      ),
      FilledButton(
        onPressed: _region == null || _question.text.trim().isEmpty
            ? null
            : () => Navigator.pop(context, (_region!, _question.text.trim())),
        child: const Text('预览裁图'),
      ),
    ],
  );
}
