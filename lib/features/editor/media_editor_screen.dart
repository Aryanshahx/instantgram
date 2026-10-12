import 'dart:async';
import 'dart:io';
import 'dart:ui' as ui;

import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:flutter/rendering.dart';
import 'package:image/image.dart' as img;
import 'package:video_player/video_player.dart';

import '../../core/services/media_service.dart';
import '../../core/theme/app_colors.dart';
import '../../core/theme/app_theme.dart';
import '../../core/utils/time_ago.dart';
import '../post/presentation/create_post_screen.dart';
import 'edit_models.dart';
import 'filters.dart';
import 'video_frames.dart';

/// Opens the editor for picked media, then the share screen.
Future<void> openEditor(
  BuildContext context,
  List<PickedMedia> media,
  ComposeMode mode,
) {
  return Navigator.of(context).push(
    MaterialPageRoute<void>(
      builder: (_) => MediaEditorScreen(media: media, mode: mode),
    ),
  );
}

enum _Tool { filters, adjust, crop, text, trim, sound }

enum _Adjust {
  brightness('Brightness', Icons.wb_sunny_outlined),
  contrast('Contrast', Icons.contrast),
  saturation('Saturation', Icons.palette_outlined),
  warmth('Warmth', Icons.thermostat_outlined),
  fade('Fade', Icons.blur_on);

  const _Adjust(this.label, this.icon);
  final String label;
  final IconData icon;
}

/// Advanced editor: filters, adjust, crop / rotate, text (photos)
/// and trim, filters, adjust, sound (videos).
class MediaEditorScreen extends StatefulWidget {
  const MediaEditorScreen({
    super.key,
    required this.media,
    required this.mode,
    this.onDone,
  });

  final List<PickedMedia> media;
  final ComposeMode mode;

  /// Tests: called with the result instead of opening the share screen.
  final ValueChanged<List<EditedMedia>>? onDone;

  @override
  State<MediaEditorScreen> createState() => _MediaEditorScreenState();
}

class _MediaEditorScreenState extends State<MediaEditorScreen> {
  late final List<EditItem> _items = widget.media
      .map((m) => EditItem(m, mode: widget.mode))
      .toList();
  int _index = 0;
  late _Tool _tool = _items.first.isVideo ? _Tool.trim : _Tool.filters;
  _Adjust _adjust = _Adjust.brightness;
  bool _exporting = false;
  bool _showGrid = false;

  VideoPlayerController? _video;
  bool _videoReady = false;
  String? _videoError;

  EditItem get _item => _items[_index];

  List<_Tool> get _tools => _item.isVideo
      ? const [_Tool.trim, _Tool.filters, _Tool.adjust, _Tool.sound]
      : const [_Tool.filters, _Tool.adjust, _Tool.crop, _Tool.text];

  @override
  void initState() {
    super.initState();
    _openItem();
  }

  @override
  void dispose() {
    _video?.dispose();
    for (final i in _items) {
      i.zoom?.dispose();
    }
    super.dispose();
  }

  // ---------------------------------------------------------------- load

  Future<void> _openItem() async {
    final item = _item;
    if (!_tools.contains(_tool)) _tool = _tools.first;
    final old = _video;
    _video = null;
    _videoReady = false;
    _videoError = null;
    old?.dispose();
    if (item.isVideo) {
      await _loadVideo(item);
    } else {
      _loadPhotoSize(item);
    }
  }

  void _loadPhotoSize(EditItem item) {
    if (item.natural != null) return;
    final stream = FileImage(item.file).resolve(ImageConfiguration.empty);
    late ImageStreamListener l;
    l = ImageStreamListener((info, _) {
      item.natural = Size(
        info.image.width.toDouble(),
        info.image.height.toDouble(),
      );
      stream.removeListener(l);
      if (mounted) setState(() {});
    }, onError: (e, _) {
      stream.removeListener(l);
      item.natural = const Size(1000, 1000);
      if (mounted) setState(() {});
    });
    stream.addListener(l);
  }

  Future<void> _loadVideo(EditItem item) async {
    final c = VideoPlayerController.file(item.file);
    _video = c;
    setState(() {});
    try {
      await c.initialize();
      if (!mounted || _video != c) return;
      item.durationMs = c.value.duration.inMilliseconds;
      item.videoAspect = c.value.aspectRatio > 0 ? c.value.aspectRatio : 9 / 16;
      final max = maxVideoMs(widget.mode);
      if (item.trimEnd == 0 || item.trimEnd > item.durationMs) {
        item.trimEnd =
            item.durationMs > max ? max : item.durationMs;
      }
      await c.setLooping(false);
      await c.setVolume(item.muted ? 0 : 1);
      await c.seekTo(Duration(milliseconds: item.trimStart));
      c.addListener(_loop);
      setState(() => _videoReady = true);
      c.play();
      _makeThumbs(item);
    } catch (e) {
      if (mounted) setState(() => _videoError = 'Could not open this video');
    }
  }

  /// Keep playing inside the trim range.
  void _loop() {
    final c = _video;
    if (c == null || !c.value.isInitialized) return;
    final item = _item;
    final pos = c.value.position.inMilliseconds;
    final end = item.trimEnd > 0 ? item.trimEnd : item.durationMs;
    if (pos >= end - 30 || (!c.value.isPlaying && c.value.isCompleted)) {
      c.seekTo(Duration(milliseconds: item.trimStart));
      if (!c.value.isPlaying) c.play();
    }
  }

  Future<void> _makeThumbs(EditItem item) async {
    if (item.thumbs != null || item.durationMs <= 0) return;
    const n = 8;
    item.thumbs = List<Uint8List?>.filled(n, null);
    for (var i = 0; i < n; i++) {
      final t = (item.durationMs * (i + 0.5) / n).round();
      final b = await VideoFrames.bytes(item.file.path, t);
      if (!mounted) return;
      item.thumbs![i] = b;
      setState(() {});
    }
  }

  void _select(int i) {
    if (i == _index) return;
    setState(() => _index = i);
    _openItem();
  }

  void _remove(int i) {
    if (_items.length <= 1) return;
    setState(() {
      _items[i].zoom?.dispose();
      _items.removeAt(i);
      if (_index >= _items.length) _index = _items.length - 1;
    });
    _openItem();
  }

  // ---------------------------------------------------------------- export

  Future<void> _next() async {
    if (_exporting) return;
    setState(() => _exporting = true);
    try {
      final out = <EditedMedia>[];
      for (var i = 0; i < _items.length; i++) {
        final item = _items[i];
        if (item.isVideo) {
          File? preview;
          if (!kIsWeb) {
            preview = await VideoFrames.file(item.file.path, item.trimStart,
                maxWidth: 720, quality: 80);
          }
          out.add(EditedMedia(
            file: item.file,
            isVideo: true,
            aspectRatio: item.videoAspect,
            edits: item.videoEdits,
            durationMs: item.trimmedMs,
            preview: preview,
          ));
          continue;
        }
        if (!item.photoEdited) {
          final n = item.natural ?? await _naturalOf(item);
          out.add(EditedMedia(
            file: item.file,
            isVideo: false,
            aspectRatio: n.width / n.height,
          ));
          continue;
        }
        // show it, wait for paint, capture
        if (_index != i) {
          setState(() => _index = i);
          await _openItem();
        }
        await _waitPainted(item);
        out.add(await _capture(item, i));
      }
      if (!mounted) return;
      if (widget.onDone != null) {
        widget.onDone!(out);
      } else {
        await Navigator.of(context).push(
          MaterialPageRoute<void>(
            builder: (_) => CreatePostScreen(items: out, mode: widget.mode),
          ),
        );
      }
    } catch (e) {
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(content: Text('Could not prepare media: $e')),
        );
      }
    } finally {
      if (mounted) setState(() => _exporting = false);
    }
  }

  Future<Size> _naturalOf(EditItem item) async {
    final c = Completer<Size>();
    final stream = FileImage(item.file).resolve(ImageConfiguration.empty);
    late ImageStreamListener l;
    l = ImageStreamListener((info, _) {
      if (!c.isCompleted) {
        c.complete(Size(info.image.width.toDouble(),
            info.image.height.toDouble()));
      }
      stream.removeListener(l);
    }, onError: (e, _) {
      if (!c.isCompleted) c.complete(const Size(1, 1));
      stream.removeListener(l);
    });
    stream.addListener(l);
    final s = await c.future.timeout(const Duration(seconds: 10),
        onTimeout: () => const Size(1, 1));
    item.natural ??= s;
    return s;
  }

  Future<void> _waitPainted(EditItem item) async {
    if (item.natural == null) await _naturalOf(item);
    if (mounted) await precacheImage(FileImage(item.file), context);
    for (var i = 0; i < 6; i++) {
      await WidgetsBinding.instance.endOfFrame;
    }
  }

  Future<EditedMedia> _capture(EditItem item, int i) async {
    final ctx = item.boundaryKey.currentContext;
    final ro = ctx?.findRenderObject();
    if (ro is! RenderRepaintBoundary) {
      throw StateError('editor not ready');
    }
    final w = ro.size.width;
    final h = ro.size.height;
    final targetW = (widget.mode == ComposeMode.story ? 1080.0 : 1350.0)
        .clamp(320.0, 1600.0);
    final ratio = (targetW / w).clamp(1.0, 6.0);
    final image = await ro.toImage(pixelRatio: ratio);
    final data = await image.toByteData(format: ui.ImageByteFormat.rawRgba);
    final width = image.width, height = image.height;
    image.dispose();
    final jpg = await compute(
      _encodeJpg,
      _Raw(data!.buffer.asUint8List(), width, height),
    );
    final dir = await Directory.systemTemp.createTemp('ig_edit');
    final file = File(
        '${dir.path}/edit_${DateTime.now().millisecondsSinceEpoch}_$i.jpg');
    await file.writeAsBytes(jpg, flush: true);
    return EditedMedia(file: file, isVideo: false, aspectRatio: w / h);
  }

  // ---------------------------------------------------------------- photo frame

  double _targetAspect(EditItem item) {
    final n = item.natural ?? const Size(1, 1);
    final na = item.turns.isOdd ? n.height / n.width : n.width / n.height;
    final r = item.aspect.ratio;
    if (r != null) return r;
    if (widget.mode == ComposeMode.photo) return na.clamp(0.8, 1.91);
    return na;
  }

  Widget _photoCanvas(EditItem item) {
    final n = item.natural;
    if (n == null) {
      return const Center(child: CircularProgressIndicator(strokeWidth: 2.5));
    }
    return LayoutBuilder(builder: (context, box) {
      final a = _targetAspect(item);
      final maxW = box.maxWidth - 24, maxH = box.maxHeight - 24;
      double fw, fh;
      if (maxW / maxH > a) {
        fh = maxH;
        fw = maxH * a;
      } else {
        fw = maxW;
        fh = maxW / a;
      }
      final na = item.turns.isOdd ? n.height / n.width : n.width / n.height;
      double cw, ch;
      if (na > a) {
        ch = fh;
        cw = fh * na;
      } else {
        cw = fw;
        ch = fw / na;
      }
      item.zoom ??= TransformationController(
        Matrix4.translationValues(-(cw - fw) / 2, -(ch - fh) / 2, 0),
      );

      final photo = SizedBox(
        width: cw,
        height: ch,
        child: applyMatrix(
          item.color.isNone ? null : item.color.matrix,
          Transform(
            alignment: Alignment.center,
            transform: Matrix4.diagonal3Values(item.flip ? -1 : 1, 1, 1),
            child: RotatedBox(
              quarterTurns: item.turns % 4,
              child: Image.file(
                item.file,
                fit: BoxFit.fill,
                gaplessPlayback: true,
              ),
            ),
          ),
        ),
      );

      return Center(
        child: SizedBox(
          width: fw,
          height: fh,
          child: Stack(
            children: [
              RepaintBoundary(
                key: item.boundaryKey,
                child: ClipRect(
                  child: ColoredBox(
                    color: Colors.black,
                    child: Stack(
                      children: [
                        Positioned.fill(
                          child: InteractiveViewer(
                            transformationController: item.zoom,
                            constrained: false,
                            minScale: 1,
                            maxScale: 5,
                            boundaryMargin: EdgeInsets.zero,
                            onInteractionStart: (_) =>
                                setState(() => _showGrid = true),
                            onInteractionEnd: (_) => setState(() {
                              _showGrid = false;
                              item.zoomChanged = true;
                            }),
                            child: photo,
                          ),
                        ),
                        for (final t in item.texts) _textLayer(item, t, fw, fh),
                      ],
                    ),
                  ),
                ),
              ),
              if (_showGrid || _tool == _Tool.crop)
                const Positioned.fill(
                  child: IgnorePointer(child: CustomPaint(painter: _Grid())),
                ),
            ],
          ),
        ),
      );
    });
  }

  Widget _textLayer(EditItem item, TextLayer t, double fw, double fh) {
    final fs = (t.size * fw).clamp(10.0, 120.0);
    final text = Text(
      t.text,
      textAlign: TextAlign.center,
      style: TextStyle(
        fontFamily: AppTheme.fontFamily,
        color: t.color,
        fontSize: fs,
        fontWeight: FontWeight.w800,
        height: 1.15,
        shadows: t.background
            ? null
            : const [Shadow(blurRadius: 6, color: Colors.black54)],
      ),
    );
    return Positioned(
      left: t.pos.dx * fw,
      top: t.pos.dy * fh,
      child: FractionalTranslation(
        translation: const Offset(-0.5, -0.5),
        child: GestureDetector(
          onPanUpdate: (d) => setState(() {
            t.pos = Offset(
              (t.pos.dx + d.delta.dx / fw).clamp(0.0, 1.0),
              (t.pos.dy + d.delta.dy / fh).clamp(0.0, 1.0),
            );
          }),
          onTap: () => _editText(item, t),
          child: ConstrainedBox(
            constraints: BoxConstraints(maxWidth: fw * 0.9),
            child: t.background
                ? Container(
                    padding: EdgeInsets.symmetric(
                        horizontal: fs * 0.4, vertical: fs * 0.15),
                    decoration: BoxDecoration(
                      color: t.color.computeLuminance() > 0.5
                          ? Colors.black87
                          : Colors.white,
                      borderRadius: BorderRadius.circular(fs * 0.3),
                    ),
                    child: text,
                  )
                : text,
          ),
        ),
      ),
    );
  }

  Future<void> _editText(EditItem item, TextLayer? layer) async {
    final res = await showModalBottomSheet<_TextResult>(
      context: context,
      isScrollControlled: true,
      backgroundColor: AppColors.surface,
      builder: (_) => _TextSheet(layer: layer),
    );
    if (res == null || !mounted) return;
    setState(() {
      if (res.delete) {
        if (layer != null) item.texts.remove(layer);
        return;
      }
      if (res.text.trim().isEmpty) {
        if (layer != null) item.texts.remove(layer);
        return;
      }
      if (layer == null) {
        item.texts.add(TextLayer(
          text: res.text.trim(),
          color: res.color,
          size: res.size,
          background: res.background,
        ));
      } else {
        layer
          ..text = res.text.trim()
          ..color = res.color
          ..size = res.size
          ..background = res.background;
      }
    });
  }

  // ---------------------------------------------------------------- video

  Widget _videoCanvas(EditItem item) {
    final c = _video;
    if (_videoError != null) {
      return Center(
        child: Text(_videoError!,
            style: const TextStyle(color: AppColors.textSecondary)),
      );
    }
    if (c == null || !_videoReady) {
      return const Center(child: CircularProgressIndicator(strokeWidth: 2.5));
    }
    return GestureDetector(
      onTap: () => setState(() {
        c.value.isPlaying ? c.pause() : c.play();
      }),
      child: Center(
        child: Padding(
          padding: const EdgeInsets.all(12),
          child: AspectRatio(
            aspectRatio: item.videoAspect,
            child: ClipRRect(
              borderRadius: BorderRadius.circular(14),
              child: Stack(
                fit: StackFit.expand,
                children: [
                  applyMatrix(
                    item.color.isNone ? null : item.color.matrix,
                    VideoPlayer(c),
                  ),
                  ValueListenableBuilder<VideoPlayerValue>(
                    valueListenable: c,
                    builder: (context, v, _) => v.isPlaying
                        ? const SizedBox.shrink()
                        : Center(
                            child: Icon(Icons.play_arrow_rounded,
                                size: 72,
                                color: Colors.white.withValues(alpha: 0.9)),
                          ),
                  ),
                  if (item.muted)
                    const Positioned(
                      right: 10,
                      top: 10,
                      child: Icon(Icons.volume_off, color: Colors.white),
                    ),
                ],
              ),
            ),
          ),
        ),
      ),
    );
  }

  // ---------------------------------------------------------------- panels

  Widget _panel() {
    switch (_tool) {
      case _Tool.filters:
        return _filtersPanel();
      case _Tool.adjust:
        return _adjustPanel();
      case _Tool.crop:
        return _cropPanel();
      case _Tool.text:
        return _textPanel();
      case _Tool.trim:
        return _trimPanel();
      case _Tool.sound:
        return _soundPanel();
    }
  }

  Widget _filtersPanel() {
    final item = _item;
    Widget sample(List<double> m) {
      if (!item.isVideo) {
        return applyMatrix(
          m,
          Image.file(item.file, fit: BoxFit.cover, cacheWidth: 160),
        );
      }
      final t = item.thumbs;
      final bytes = t == null
          ? null
          : t.firstWhere((b) => b != null, orElse: () => null) as Uint8List?;
      return applyMatrix(
        m,
        bytes != null
            ? Image.memory(bytes, fit: BoxFit.cover, gaplessPlayback: true)
            : const DecoratedBox(
                decoration: BoxDecoration(
                  gradient: LinearGradient(
                    colors: [Color(0xFFE8A06A), Color(0xFF3E6FB0)],
                  ),
                ),
              ),
      );
    }

    return ListView.separated(
      scrollDirection: Axis.horizontal,
      padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 8),
      itemCount: kFilterPresets.length,
      separatorBuilder: (context, index) => const SizedBox(width: 10),
      itemBuilder: (context, i) {
        final p = kFilterPresets[i];
        final sel = item.color.preset == i;
        return GestureDetector(
          onTap: () => setState(() => item.color = item.color.copyWith(preset: i)),
          child: Column(
            children: [
              Text(
                p.name,
                style: TextStyle(
                  fontSize: 12,
                  fontWeight: sel ? FontWeight.w800 : FontWeight.w500,
                  color: sel ? AppColors.lime : AppColors.textSecondary,
                ),
              ),
              const SizedBox(height: 6),
              Container(
                width: 64,
                height: 64,
                padding: const EdgeInsets.all(2),
                decoration: BoxDecoration(
                  borderRadius: BorderRadius.circular(12),
                  border: Border.all(
                    color: sel ? AppColors.lime : Colors.transparent,
                    width: 2,
                  ),
                ),
                child: ClipRRect(
                  borderRadius: BorderRadius.circular(9),
                  child: sample(p.matrix),
                ),
              ),
            ],
          ),
        );
      },
    );
  }

  double _adjustValue(ColorEdits c, _Adjust a) => switch (a) {
        _Adjust.brightness => c.brightness,
        _Adjust.contrast => c.contrast,
        _Adjust.saturation => c.saturation,
        _Adjust.warmth => c.warmth,
        _Adjust.fade => c.fade,
      };

  ColorEdits _setAdjust(ColorEdits c, _Adjust a, double v) => switch (a) {
        _Adjust.brightness => c.copyWith(brightness: v),
        _Adjust.contrast => c.copyWith(contrast: v),
        _Adjust.saturation => c.copyWith(saturation: v),
        _Adjust.warmth => c.copyWith(warmth: v),
        _Adjust.fade => c.copyWith(fade: v),
      };

  Widget _adjustPanel() {
    final item = _item;
    final v = _adjustValue(item.color, _adjust);
    final min = _adjust == _Adjust.fade ? 0.0 : -1.0;
    return Column(
      children: [
        SizedBox(
          height: 40,
          child: ListView(
            scrollDirection: Axis.horizontal,
            padding: const EdgeInsets.symmetric(horizontal: 12),
            children: [
              for (final a in _Adjust.values)
                Padding(
                  padding: const EdgeInsets.only(right: 6),
                  child: _Chip(
                    label: a.label,
                    icon: a.icon,
                    selected: a == _adjust,
                    dot: _adjustValue(item.color, a) != 0,
                    onTap: () => setState(() => _adjust = a),
                  ),
                ),
            ],
          ),
        ),
        Padding(
          padding: const EdgeInsets.fromLTRB(12, 6, 12, 0),
          child: Row(
            children: [
              SizedBox(
                width: 42,
                child: Text(
                  '${(v * 100).round()}',
                  textAlign: TextAlign.center,
                  style: const TextStyle(fontWeight: FontWeight.w700),
                ),
              ),
              Expanded(
                child: Slider(
                  value: v.clamp(min, 1.0),
                  min: min,
                  max: 1,
                  activeColor: AppColors.lime,
                  onChanged: (x) => setState(
                      () => item.color = _setAdjust(item.color, _adjust, x)),
                ),
              ),
              TextButton(
                onPressed: () => setState(() =>
                    item.color = ColorEdits(preset: item.color.preset)),
                child: const Text('Reset'),
              ),
            ],
          ),
        ),
      ],
    );
  }

  Widget _cropPanel() {
    final item = _item;
    return Column(
      mainAxisAlignment: MainAxisAlignment.center,
      children: [
        SizedBox(
          height: 40,
          child: ListView(
            scrollDirection: Axis.horizontal,
            padding: const EdgeInsets.symmetric(horizontal: 12),
            children: [
              for (final a in aspectsFor(widget.mode))
                Padding(
                  padding: const EdgeInsets.only(right: 6),
                  child: _Chip(
                    label: a.label,
                    icon: Icons.crop,
                    selected: item.aspect == a,
                    onTap: () => setState(() {
                      item.aspect = a;
                      item.resetZoom();
                    }),
                  ),
                ),
            ],
          ),
        ),
        const SizedBox(height: 10),
        Row(
          mainAxisAlignment: MainAxisAlignment.center,
          children: [
            _RoundAction(
              icon: Icons.rotate_90_degrees_ccw,
              label: 'Rotate',
              onTap: () => setState(() {
                item.turns = (item.turns + 3) % 4;
                item.resetZoom();
              }),
            ),
            _RoundAction(
              icon: Icons.flip,
              label: 'Flip',
              onTap: () => setState(() => item.flip = !item.flip),
            ),
            _RoundAction(
              icon: Icons.center_focus_strong_outlined,
              label: 'Reset',
              onTap: () => setState(() {
                item.turns = 0;
                item.flip = false;
                item.aspect = widget.mode == ComposeMode.story
                    ? CropAspect.story
                    : CropAspect.original;
                item.resetZoom();
              }),
            ),
          ],
        ),
        const Padding(
          padding: EdgeInsets.only(top: 6),
          child: Text('Pinch to zoom · drag to move',
              style: TextStyle(fontSize: 12, color: AppColors.textSecondary)),
        ),
      ],
    );
  }

  Widget _textPanel() {
    final item = _item;
    return Column(
      mainAxisAlignment: MainAxisAlignment.center,
      children: [
        FilledButton.icon(
          onPressed: () => _editText(item, null),
          style: FilledButton.styleFrom(
            backgroundColor: AppColors.lime,
            foregroundColor: Colors.black,
            textStyle: const TextStyle(
              fontFamily: AppTheme.fontFamily,
              fontWeight: FontWeight.w800,
            ),
          ),
          icon: const Icon(Icons.text_fields),
          label: const Text('Add text'),
        ),
        const SizedBox(height: 10),
        Text(
          item.texts.isEmpty
              ? 'Add words on your photo'
              : 'Drag text to move it · tap it to edit',
          style: const TextStyle(fontSize: 12, color: AppColors.textSecondary),
        ),
      ],
    );
  }

  Widget _trimPanel() {
    final item = _item;
    if (!_videoReady || item.durationMs <= 0) {
      return const Center(
        child: Text('Loading video…',
            style: TextStyle(color: AppColors.textSecondary)),
      );
    }
    final max = maxVideoMs(widget.mode);
    final total = item.durationMs.toDouble();
    final start = item.trimStart.toDouble().clamp(0.0, total);
    final end = (item.trimEnd > 0 ? item.trimEnd : item.durationMs)
        .toDouble()
        .clamp(start, total);
    final thumbs = item.thumbs;
    return Padding(
      padding: const EdgeInsets.symmetric(horizontal: 12),
      child: Column(
        mainAxisAlignment: MainAxisAlignment.center,
        children: [
          SizedBox(
            height: 56,
            child: Stack(
              alignment: Alignment.center,
              children: [
                Positioned.fill(
                  left: 22,
                  right: 22,
                  child: ClipRRect(
                    borderRadius: BorderRadius.circular(8),
                    child: Row(
                      children: [
                        for (var i = 0; i < 8; i++)
                          Expanded(
                            child: thumbs != null && thumbs[i] != null
                                ? Image.memory(thumbs[i] as Uint8List,
                                    fit: BoxFit.cover,
                                    height: 56,
                                    gaplessPlayback: true)
                                : Container(
                                    color: i.isEven
                                        ? const Color(0xFF1D2029)
                                        : const Color(0xFF262B35),
                                  ),
                          ),
                      ],
                    ),
                  ),
                ),
                SliderTheme(
                  data: SliderTheme.of(context).copyWith(
                    trackHeight: 56,
                    activeTrackColor: AppColors.lime.withValues(alpha: 0.18),
                    inactiveTrackColor: Colors.black.withValues(alpha: 0.55),
                    rangeTrackShape: const RectangularRangeSliderTrackShape(),
                    rangeThumbShape:
                        const RoundRangeSliderThumbShape(enabledThumbRadius: 9),
                    thumbColor: AppColors.lime,
                    overlayShape: SliderComponentShape.noOverlay,
                  ),
                  child: RangeSlider(
                    values: RangeValues(start, end),
                    min: 0,
                    max: total,
                    onChanged: (r) {
                      var s = r.start, e = r.end;
                      final movedStart = (s - start).abs() > (e - end).abs();
                      if (e - s > max) {
                        if (movedStart) {
                          e = s + max;
                        } else {
                          s = e - max;
                        }
                      }
                      if (e - s < 1000) {
                        if (movedStart) {
                          s = (e - 1000).clamp(0, total);
                        } else {
                          e = (s + 1000).clamp(0, total);
                        }
                      }
                      setState(() {
                        item.trimStart = s.round();
                        item.trimEnd = e.round();
                      });
                      _video?.seekTo(Duration(
                          milliseconds: movedStart ? s.round() : (e - 800).round()));
                    },
                    onChangeEnd: (_) {
                      _video?.seekTo(Duration(milliseconds: item.trimStart));
                      _video?.play();
                    },
                  ),
                ),
              ],
            ),
          ),
          const SizedBox(height: 8),
          Row(
            children: [
              Text(durationLabel(item.trimStart),
                  style: const TextStyle(fontSize: 12)),
              const Spacer(),
              Text(
                'Length ${durationLabel(item.trimmedMs)}'
                '  ·  max ${durationLabel(max)}',
                style: const TextStyle(
                    fontSize: 12.5,
                    fontWeight: FontWeight.w700,
                    color: AppColors.lime),
              ),
              const Spacer(),
              Text(durationLabel(end.round()),
                  style: const TextStyle(fontSize: 12)),
            ],
          ),
        ],
      ),
    );
  }

  Widget _soundPanel() {
    final item = _item;
    return Center(
      child: Padding(
        padding: const EdgeInsets.symmetric(horizontal: 16),
        child: SwitchListTile(
          value: !item.muted,
          activeThumbColor: AppColors.lime,
          contentPadding: EdgeInsets.zero,
          secondary: Icon(
            item.muted ? Icons.volume_off : Icons.volume_up,
            color: AppColors.lime,
          ),
          title: const Text('Original sound',
              style: TextStyle(fontWeight: FontWeight.w700)),
          subtitle: const Text('Turn off to post the video without sound'),
          onChanged: (on) {
            setState(() => item.muted = !on);
            _video?.setVolume(on ? 1 : 0);
          },
        ),
      ),
    );
  }

  String _toolLabel(_Tool t) => switch (t) {
        _Tool.filters => 'Filters',
        _Tool.adjust => 'Adjust',
        _Tool.crop => 'Crop',
        _Tool.text => 'Text',
        _Tool.trim => 'Trim',
        _Tool.sound => 'Sound',
      };

  IconData _toolIcon(_Tool t) => switch (t) {
        _Tool.filters => Icons.auto_awesome,
        _Tool.adjust => Icons.tune,
        _Tool.crop => Icons.crop_rotate,
        _Tool.text => Icons.text_fields,
        _Tool.trim => Icons.content_cut,
        _Tool.sound => Icons.music_note_outlined,
      };

  // ---------------------------------------------------------------- build

  @override
  Widget build(BuildContext context) {
    final item = _item;
    final title = switch (widget.mode) {
      ComposeMode.photo => 'Edit post',
      ComposeMode.clip => 'Edit clip',
      ComposeMode.story => 'Edit moment',
    };
    return Scaffold(
      backgroundColor: Colors.black,
      body: SafeArea(
        child: Stack(
          children: [
            Column(
              children: [
                // top bar
                Padding(
                  padding: const EdgeInsets.fromLTRB(4, 4, 12, 4),
                  child: Row(
                    children: [
                      IconButton(
                        tooltip: 'Close',
                        onPressed: () => Navigator.of(context).maybePop(),
                        icon: const Icon(Icons.close),
                      ),
                      Expanded(
                        child: Text(
                          _items.length > 1
                              ? '$title  ${_index + 1}/${_items.length}'
                              : title,
                          style: const TextStyle(
                              fontSize: 17, fontWeight: FontWeight.w800),
                        ),
                      ),
                      FilledButton(
                        key: const ValueKey('editor-next'),
                        onPressed: _exporting ? null : _next,
                        style: FilledButton.styleFrom(
                          backgroundColor: AppColors.lime,
                          foregroundColor: Colors.black,
                          visualDensity: VisualDensity.compact,
                          textStyle: const TextStyle(
                            fontFamily: AppTheme.fontFamily,
                            fontWeight: FontWeight.w800,
                          ),
                        ),
                        child: const Text('Next'),
                      ),
                    ],
                  ),
                ),
                Expanded(
                  child: item.isVideo ? _videoCanvas(item) : _photoCanvas(item),
                ),
                if (_items.length > 1) _strip(),
                SizedBox(height: 132, child: _panel()),
                // tool tabs
                Container(
                  height: 56,
                  decoration: const BoxDecoration(
                    border: Border(top: BorderSide(color: AppColors.border)),
                  ),
                  child: Row(
                    children: [
                      for (final t in _tools)
                        Expanded(
                          child: InkWell(
                            onTap: () => setState(() => _tool = t),
                            child: Column(
                              mainAxisAlignment: MainAxisAlignment.center,
                              children: [
                                Icon(
                                  _toolIcon(t),
                                  size: 21,
                                  color: _tool == t
                                      ? AppColors.lime
                                      : AppColors.textSecondary,
                                ),
                                const SizedBox(height: 3),
                                Text(
                                  _toolLabel(t),
                                  style: TextStyle(
                                    fontSize: 11.5,
                                    fontWeight: _tool == t
                                        ? FontWeight.w800
                                        : FontWeight.w500,
                                    color: _tool == t
                                        ? AppColors.lime
                                        : AppColors.textSecondary,
                                  ),
                                ),
                              ],
                            ),
                          ),
                        ),
                    ],
                  ),
                ),
              ],
            ),
            if (_exporting)
              const Positioned.fill(
                child: ColoredBox(
                  color: Color(0xAA000000),
                  child: Center(
                    child: Column(
                      mainAxisSize: MainAxisSize.min,
                      children: [
                        CircularProgressIndicator(),
                        SizedBox(height: 12),
                        Text('Preparing…'),
                      ],
                    ),
                  ),
                ),
              ),
          ],
        ),
      ),
    );
  }

  Widget _strip() {
    return SizedBox(
      height: 64,
      child: ListView.separated(
        scrollDirection: Axis.horizontal,
        padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 6),
        itemCount: _items.length,
        separatorBuilder: (context, index) => const SizedBox(width: 8),
        itemBuilder: (context, i) {
          final it = _items[i];
          final sel = i == _index;
          return GestureDetector(
            onTap: () => _select(i),
            child: Stack(
              clipBehavior: Clip.none,
              children: [
                Container(
                  width: 52,
                  height: 52,
                  decoration: BoxDecoration(
                    borderRadius: BorderRadius.circular(10),
                    border: Border.all(
                      color: sel ? AppColors.lime : AppColors.border,
                      width: sel ? 2 : 1,
                    ),
                  ),
                  clipBehavior: Clip.antiAlias,
                  child: it.isVideo
                      ? const ColoredBox(
                          color: AppColors.surface,
                          child: Icon(Icons.videocam, size: 22),
                        )
                      : Image.file(it.file, fit: BoxFit.cover, cacheWidth: 120),
                ),
                if (_items.length > 1)
                  Positioned(
                    right: -6,
                    top: -6,
                    child: GestureDetector(
                      onTap: () => _remove(i),
                      child: Container(
                        width: 20,
                        height: 20,
                        decoration: const BoxDecoration(
                          color: Colors.black,
                          shape: BoxShape.circle,
                        ),
                        child: const Icon(Icons.close, size: 14),
                      ),
                    ),
                  ),
              ],
            ),
          );
        },
      ),
    );
  }
}

// ---------------------------------------------------------------- helpers

class _Raw {
  const _Raw(this.data, this.width, this.height);
  final Uint8List data;
  final int width;
  final int height;
}

Uint8List _encodeJpg(_Raw r) {
  final im = img.Image.fromBytes(
    width: r.width,
    height: r.height,
    bytes: r.data.buffer,
    numChannels: 4,
    order: img.ChannelOrder.rgba,
  );
  return img.encodeJpg(im, quality: 90);
}

/// Rule-of-thirds lines.
class _Grid extends CustomPainter {
  const _Grid();

  @override
  void paint(Canvas canvas, Size size) {
    final p = Paint()
      ..color = Colors.white.withValues(alpha: 0.45)
      ..strokeWidth = 0.8;
    for (var i = 1; i < 3; i++) {
      final x = size.width * i / 3, y = size.height * i / 3;
      canvas.drawLine(Offset(x, 0), Offset(x, size.height), p);
      canvas.drawLine(Offset(0, y), Offset(size.width, y), p);
    }
    canvas.drawRect(
      Offset.zero & size,
      Paint()
        ..style = PaintingStyle.stroke
        ..color = Colors.white.withValues(alpha: 0.7)
        ..strokeWidth = 1.2,
    );
  }

  @override
  bool shouldRepaint(covariant _Grid oldDelegate) => false;
}

class _Chip extends StatelessWidget {
  const _Chip({
    required this.label,
    required this.icon,
    required this.selected,
    required this.onTap,
    this.dot = false,
  });

  final String label;
  final IconData icon;
  final bool selected;
  final bool dot;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    return Material(
      color: selected ? AppColors.lime : AppColors.surface,
      shape: StadiumBorder(
        side: BorderSide(color: selected ? AppColors.lime : AppColors.border),
      ),
      child: InkWell(
        customBorder: const StadiumBorder(),
        onTap: onTap,
        child: Padding(
          padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 7),
          child: Row(
            mainAxisSize: MainAxisSize.min,
            children: [
              Icon(icon,
                  size: 16, color: selected ? Colors.black : AppColors.lime),
              const SizedBox(width: 6),
              Text(
                label,
                style: TextStyle(
                  fontSize: 12.5,
                  fontWeight: FontWeight.w700,
                  color: selected ? Colors.black : AppColors.textPrimary,
                ),
              ),
              if (dot) ...[
                const SizedBox(width: 5),
                Container(
                  width: 6,
                  height: 6,
                  decoration: BoxDecoration(
                    color: selected ? Colors.black : AppColors.lime,
                    shape: BoxShape.circle,
                  ),
                ),
              ],
            ],
          ),
        ),
      ),
    );
  }
}

class _RoundAction extends StatelessWidget {
  const _RoundAction({
    required this.icon,
    required this.label,
    required this.onTap,
  });

  final IconData icon;
  final String label;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: const EdgeInsets.symmetric(horizontal: 12),
      child: GestureDetector(
        onTap: onTap,
        behavior: HitTestBehavior.opaque,
        child: Column(
          children: [
            Container(
              width: 44,
              height: 44,
              decoration: BoxDecoration(
                color: AppColors.surface,
                shape: BoxShape.circle,
                border: Border.all(color: AppColors.border),
              ),
              child: Icon(icon, size: 21),
            ),
            const SizedBox(height: 4),
            Text(label, style: const TextStyle(fontSize: 11.5)),
          ],
        ),
      ),
    );
  }
}

class _TextResult {
  const _TextResult({
    this.text = '',
    this.color = Colors.white,
    this.size = 0.08,
    this.background = false,
    this.delete = false,
  });
  final String text;
  final Color color;
  final double size;
  final bool background;
  final bool delete;
}

const List<Color> _textColors = [
  Colors.white,
  Colors.black,
  AppColors.lime,
  Color(0xFF62F0A4),
  Color(0xFFFF4D67),
  Color(0xFFFFC53D),
  Color(0xFF4DA3FF),
  Color(0xFFB97CFF),
];

class _TextSheet extends StatefulWidget {
  const _TextSheet({this.layer});
  final TextLayer? layer;

  @override
  State<_TextSheet> createState() => _TextSheetState();
}

class _TextSheetState extends State<_TextSheet> {
  late final _ctrl = TextEditingController(text: widget.layer?.text ?? '');
  late Color _color = widget.layer?.color ?? Colors.white;
  late double _size = widget.layer?.size ?? 0.08;
  late bool _bg = widget.layer?.background ?? false;

  @override
  void dispose() {
    _ctrl.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: EdgeInsets.only(
        left: 16,
        right: 16,
        top: 8,
        bottom: MediaQuery.of(context).viewInsets.bottom + 16,
      ),
      child: Column(
        mainAxisSize: MainAxisSize.min,
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          TextField(
            controller: _ctrl,
            autofocus: true,
            maxLines: 3,
            minLines: 1,
            maxLength: 120,
            style: TextStyle(
              fontSize: 20,
              fontWeight: FontWeight.w800,
              color: _color == Colors.black ? Colors.white : _color,
            ),
            decoration: const InputDecoration(
              hintText: 'Type something…',
              border: InputBorder.none,
            ),
          ),
          SizedBox(
            height: 36,
            child: ListView(
              scrollDirection: Axis.horizontal,
              children: [
                for (final c in _textColors)
                  GestureDetector(
                    onTap: () => setState(() => _color = c),
                    child: Container(
                      width: 30,
                      height: 30,
                      margin: const EdgeInsets.only(right: 8),
                      decoration: BoxDecoration(
                        color: c,
                        shape: BoxShape.circle,
                        border: Border.all(
                          color: _color == c ? AppColors.lime : Colors.white24,
                          width: _color == c ? 3 : 1,
                        ),
                      ),
                    ),
                  ),
              ],
            ),
          ),
          Row(
            children: [
              const Icon(Icons.format_size, size: 20),
              Expanded(
                child: Slider(
                  value: _size,
                  min: 0.04,
                  max: 0.18,
                  activeColor: AppColors.lime,
                  onChanged: (v) => setState(() => _size = v),
                ),
              ),
              IconButton(
                tooltip: 'Background',
                onPressed: () => setState(() => _bg = !_bg),
                icon: Icon(
                  _bg ? Icons.format_color_fill : Icons.format_color_reset,
                  color: _bg ? AppColors.lime : null,
                ),
              ),
            ],
          ),
          Row(
            children: [
              if (widget.layer != null)
                TextButton.icon(
                  onPressed: () => Navigator.pop(
                      context, const _TextResult(delete: true)),
                  icon: const Icon(Icons.delete_outline, color: AppColors.like),
                  label: const Text('Delete',
                      style: TextStyle(color: AppColors.like)),
                ),
              const Spacer(),
              FilledButton(
                onPressed: () => Navigator.pop(
                  context,
                  _TextResult(
                    text: _ctrl.text,
                    color: _color,
                    size: _size,
                    background: _bg,
                  ),
                ),
                style: FilledButton.styleFrom(
                  backgroundColor: AppColors.lime,
                  foregroundColor: Colors.black,
                  textStyle: const TextStyle(
                    fontFamily: AppTheme.fontFamily,
                    fontWeight: FontWeight.w800,
                  ),
                ),
                child: const Text('Done'),
              ),
            ],
          ),
        ],
      ),
    );
  }
}
