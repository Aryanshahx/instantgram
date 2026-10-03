import 'dart:io';
import 'dart:math' as math;

import 'package:flutter/material.dart';

import '../../core/theme.dart';
import '../../core/ui.dart';
import '../../services/photo_edit.dart';

class PhotoEditResult {
  const PhotoEditResult(this.file, this.edits);

  /// The photo to upload (the untouched original when [edits] is empty).
  final File file;
  final PhotoEdits edits;
}

/// Crop, rotate, flip, filters and light/colour adjustments for a photo. The preview is a small
/// copy; Done applies everything to the full photo and saves it as a quality 95 JPEG.
class PhotoEditorScreen extends StatefulWidget {
  const PhotoEditorScreen({super.key, required this.original, this.initial});

  final File original;
  final PhotoEdits? initial;

  @override
  State<PhotoEditorScreen> createState() => _PhotoEditorScreenState();
}

class _PhotoEditorScreenState extends State<PhotoEditorScreen> {
  PhotoProxy? _proxy;
  Object? _loadError;
  late PhotoEdits _e = widget.initial?.copy() ?? PhotoEdits();
  int _tab = 0;
  int _preset = 0; // index into _presets (0 = free)
  bool _busy = false;

  static const _presets = <(String, double?)>[
    ('Free', null),
    ('Original', -1),
    ('1:1', 1),
    ('4:5', 4 / 5),
    ('9:16', 9 / 16),
    ('16:9', 16 / 9),
    ('3:4', 3 / 4),
  ];

  @override
  void initState() {
    super.initState();
    _load();
  }

  Future<void> _load() async {
    try {
      final p = await PhotoEditor.makeProxy(widget.original);
      if (!mounted) {
        p.file.delete().ignore();
        return;
      }
      setState(() => _proxy = p);
    } catch (e) {
      if (mounted) setState(() => _loadError = e);
    }
  }

  @override
  void dispose() {
    _proxy?.file.delete().ignore();
    super.dispose();
  }

  /// Proportions of the photo after the turns (before cropping).
  double get _photoAspect {
    final p = _proxy!;
    final odd = _e.turns % 2 == 1;
    return odd ? p.height / p.width : p.width / p.height;
  }

  double? get _lock {
    final v = _presets[_preset].$2;
    if (v == null) return null;
    return v < 0 ? _photoAspect : v;
  }

  void _rotate(int dir) {
    setState(() {
      _e.turns = (_e.turns + dir) % 4;
      if (_e.turns < 0) _e.turns += 4;
      _e.crop = const Rect.fromLTWH(0, 0, 1, 1);
      _preset = 0;
    });
  }

  void _flip() {
    setState(() {
      _e.flip = !_e.flip;
      final c = _e.crop;
      _e.crop = Rect.fromLTWH(1 - c.left - c.width, c.top, c.width, c.height);
    });
  }

  void _pickPreset(int i) {
    setState(() {
      _preset = i;
      final v = _presets[i].$2;
      if (v == null) return;
      _e.crop = PhotoEditor.cropFor(_photoAspect, v < 0 ? _photoAspect : v);
    });
  }

  void _reset() {
    setState(() {
      _e = PhotoEdits();
      _preset = 0;
    });
  }

  Future<void> _done() async {
    if (_busy) return;
    if (_e.isEmpty) {
      Navigator.of(context).pop(PhotoEditResult(widget.original, _e));
      return;
    }
    setState(() => _busy = true);
    try {
      final f = await PhotoEditor.render(widget.original, _e);
      if (!mounted) return;
      Navigator.of(context).pop(PhotoEditResult(f, _e));
    } catch (_) {
      if (mounted) {
        setState(() => _busy = false);
        showToast(context, 'Could not save the edits. Try again.');
      }
    }
  }

  @override
  Widget build(BuildContext context) {
    return Theme(
      data: AppTheme.dark,
      child: Builder(
        builder: (context) => PopScope(
          canPop: !_busy,
          child: Scaffold(
            backgroundColor: Colors.black,
            appBar: AppBar(
              backgroundColor: Colors.black,
              leading: IconButton(
                icon: const Icon(Icons.close_rounded),
                onPressed: _busy ? null : () => Navigator.of(context).pop(),
              ),
              title: const Text('Edit photo'),
              actions: [
                TextButton(
                  onPressed: _busy || _proxy == null ? null : _reset,
                  child: const Text('Reset'),
                ),
                Padding(
                  padding: const EdgeInsets.only(right: 12, left: 4),
                  child: FilledButton(
                    style: FilledButton.styleFrom(
                      minimumSize: const Size(76, 40),
                      padding: const EdgeInsets.symmetric(horizontal: 18),
                    ),
                    onPressed: _busy || _proxy == null ? null : _done,
                    child: _busy
                        ? const SizedBox(
                            width: 18,
                            height: 18,
                            child: CircularProgressIndicator(
                              strokeWidth: 2.5,
                              color: AppTheme.ink,
                            ),
                          )
                        : const Text('Done'),
                  ),
                ),
              ],
            ),
            body: _body(context),
          ),
        ),
      ),
    );
  }

  Widget _body(BuildContext context) {
    if (_loadError != null) {
      return const Center(
        child: Padding(
          padding: EdgeInsets.all(32),
          child: Text(
            'This photo cannot be edited. You can still post it as it is.',
            textAlign: TextAlign.center,
          ),
        ),
      );
    }
    if (_proxy == null) {
      return const Center(child: CircularProgressIndicator());
    }
    return Column(
      children: [
        Expanded(
          child: Padding(
            padding: const EdgeInsets.fromLTRB(12, 4, 12, 12),
            child: LayoutBuilder(builder: _preview),
          ),
        ),
        _panel(context),
      ],
    );
  }

  Widget _imageWidget() {
    final p = _proxy!;
    return ColorFiltered(
      colorFilter: ColorFilter.matrix(_e.colorMatrix),
      child: Transform.flip(
        flipX: _e.flip,
        child: RotatedBox(
          quarterTurns: _e.turns,
          child: Image.file(
            p.file,
            fit: BoxFit.fill,
            gaplessPlayback: true,
            filterQuality: FilterQuality.medium,
          ),
        ),
      ),
    );
  }

  Widget _preview(BuildContext context, BoxConstraints c) {
    final cropping = _tab == 0;
    final full = _photoAspect;
    final crop = _e.crop;
    // proportions of what is shown: the whole photo while cropping, the result otherwise
    final shown = cropping ? full : full * crop.width / crop.height;
    var w = c.maxWidth;
    var h = w / shown;
    if (h > c.maxHeight) {
      h = c.maxHeight;
      w = h * shown;
    }

    Widget content;
    if (cropping) {
      content = Stack(
        fit: StackFit.expand,
        children: [
          _imageWidget(),
          CropOverlay(
            rect: crop,
            lock: _lock,
            photoAspect: full,
            onChanged: (r) => setState(() => _e.crop = r),
          ),
        ],
      );
    } else {
      final fullW = w / crop.width;
      final fullH = h / crop.height;
      final ax = crop.width >= 0.999
          ? 0.0
          : 2 * crop.left / (1 - crop.width) - 1;
      final ay = crop.height >= 0.999
          ? 0.0
          : 2 * crop.top / (1 - crop.height) - 1;
      content = ClipRect(
        child: Align(
          alignment: Alignment(ax, ay),
          widthFactor: crop.width,
          heightFactor: crop.height,
          child: SizedBox(width: fullW, height: fullH, child: _imageWidget()),
        ),
      );
    }
    return Center(
      child: SizedBox(width: w, height: h, child: content),
    );
  }

  Widget _panel(BuildContext context) {
    return SafeArea(
      top: false,
      child: Column(
        mainAxisSize: MainAxisSize.min,
        children: [
          SizedBox(
            height: 150,
            child: switch (_tab) {
              0 => _cropTools(),
              1 => _filterTools(),
              _ => _adjustTools(),
            },
          ),
          Row(
            children: [
              _tabButton(0, Icons.crop_rounded, 'Crop'),
              _tabButton(1, Icons.auto_awesome_rounded, 'Filters'),
              _tabButton(2, Icons.tune_rounded, 'Adjust'),
            ],
          ),
          const SizedBox(height: 6),
        ],
      ),
    );
  }

  Widget _tabButton(int i, IconData icon, String label) {
    final on = _tab == i;
    final color = on ? AppTheme.volt : Colors.white70;
    return Expanded(
      child: InkWell(
        onTap: () => setState(() => _tab = i),
        child: Padding(
          padding: const EdgeInsets.symmetric(vertical: 8),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              Icon(icon, color: color),
              const SizedBox(height: 3),
              Text(
                label,
                style: TextStyle(
                  color: color,
                  fontWeight: FontWeight.w800,
                  fontSize: 12.5,
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }

  Widget _cropTools() {
    return Column(
      mainAxisAlignment: MainAxisAlignment.center,
      children: [
        Row(
          mainAxisAlignment: MainAxisAlignment.center,
          children: [
            IconButton(
              tooltip: 'Rotate left',
              icon: const Icon(Icons.rotate_left_rounded),
              onPressed: () => _rotate(-1),
            ),
            IconButton(
              tooltip: 'Rotate right',
              icon: const Icon(Icons.rotate_right_rounded),
              onPressed: () => _rotate(1),
            ),
            IconButton(
              tooltip: 'Flip',
              icon: const Icon(Icons.flip_rounded),
              onPressed: _flip,
            ),
          ],
        ),
        SizedBox(
          height: 52,
          child: ListView.separated(
            scrollDirection: Axis.horizontal,
            padding: const EdgeInsets.symmetric(horizontal: 16),
            itemCount: _presets.length,
            separatorBuilder: (_, _) => const SizedBox(width: 8),
            itemBuilder: (context, i) => Center(
              child: ChoiceChip(
                label: Text(_presets[i].$1),
                selected: _preset == i,
                showCheckmark: false,
                selectedColor: AppTheme.volt,
                labelStyle: TextStyle(
                  fontWeight: FontWeight.w800,
                  color: _preset == i ? AppTheme.ink : Colors.white,
                ),
                onSelected: (_) => _pickPreset(i),
              ),
            ),
          ),
        ),
      ],
    );
  }

  Widget _filterTools() {
    final p = _proxy!;
    return ListView.separated(
      scrollDirection: Axis.horizontal,
      padding: const EdgeInsets.fromLTRB(16, 14, 16, 8),
      itemCount: kPhotoFilters.length,
      separatorBuilder: (_, _) => const SizedBox(width: 10),
      itemBuilder: (context, i) {
        final on = _e.filter == i;
        return GestureDetector(
          onTap: () => setState(() => _e.filter = i),
          child: Column(
            children: [
              Container(
                width: 68,
                height: 76,
                decoration: BoxDecoration(
                  border: Border.all(
                    color: on ? AppTheme.volt : Colors.transparent,
                    width: 2.5,
                  ),
                ),
                child: ColorFiltered(
                  colorFilter: ColorFilter.matrix(kPhotoFilters[i].matrix),
                  child: Image.file(p.file, fit: BoxFit.cover, cacheWidth: 160),
                ),
              ),
              const SizedBox(height: 4),
              Text(
                kPhotoFilters[i].name,
                style: TextStyle(
                  color: on ? AppTheme.volt : Colors.white70,
                  fontWeight: FontWeight.w800,
                  fontSize: 12,
                ),
              ),
            ],
          ),
        );
      },
    );
  }

  Widget _adjustTools() {
    Widget slider(
      String label,
      double value,
      double min,
      double max,
      double neutral,
      ValueChanged<double> onChanged,
    ) {
      return Row(
        children: [
          SizedBox(
            width: 92,
            child: Padding(
              padding: const EdgeInsets.only(left: 18),
              child: Text(
                label,
                style: const TextStyle(
                  fontWeight: FontWeight.w800,
                  fontSize: 13.5,
                ),
              ),
            ),
          ),
          Expanded(
            child: Slider(
              value: value.clamp(min, max),
              min: min,
              max: max,
              activeColor: AppTheme.volt,
              onChanged: (v) {
                // a little "snap" at the neutral value
                onChanged(
                  (v - neutral).abs() < (max - min) * 0.025 ? neutral : v,
                );
              },
            ),
          ),
          SizedBox(
            width: 44,
            child: Text(
              '${((value - neutral) / (max - min) * 200).round()}',
              textAlign: TextAlign.center,
              style: const TextStyle(color: Colors.white70, fontSize: 12.5),
            ),
          ),
        ],
      );
    }

    return Column(
      mainAxisAlignment: MainAxisAlignment.center,
      children: [
        slider(
          'Brightness',
          _e.brightness,
          -1,
          1,
          0,
          (v) => setState(() => _e.brightness = v),
        ),
        slider(
          'Contrast',
          _e.contrast,
          0.5,
          1.5,
          1,
          (v) => setState(() => _e.contrast = v),
        ),
        slider(
          'Colour',
          _e.saturation,
          0,
          2,
          1,
          (v) => setState(() => _e.saturation = v),
        ),
      ],
    );
  }
}

/// Draggable crop frame on top of a photo. Drag a corner to resize, drag inside to move.
/// With [lock] set (width / height in photo pixels) the shape stays fixed.
class CropOverlay extends StatefulWidget {
  const CropOverlay({
    super.key,
    required this.rect,
    required this.photoAspect,
    required this.onChanged,
    this.lock,
  });

  final Rect rect;
  final double photoAspect;
  final double? lock;
  final ValueChanged<Rect> onChanged;

  /// New crop for a corner dragged to [p] while the opposite corner [anchor] stays put.
  static Rect resize(Offset anchor, Offset p, double? lock, Size box) =>
      _CropOverlayState.resizeCrop(anchor, p, lock, box);

  @override
  State<CropOverlay> createState() => _CropOverlayState();
}

class _CropOverlayState extends State<CropOverlay> {
  static const _min = 0.1;
  int _mode = 0; // 0 nothing, 1 move, 2 corner
  Offset _anchor = Offset.zero; // fixed corner (fractions) while resizing

  Size _size = Size.zero;

  void _start(DragStartDetails d) {
    final r = widget.rect;
    final p = d.localPosition;
    final corners = [r.topLeft, r.topRight, r.bottomRight, r.bottomLeft];
    final opposite = [r.bottomRight, r.bottomLeft, r.topLeft, r.topRight];
    var best = -1;
    var bestDist = 44.0;
    for (var i = 0; i < 4; i++) {
      final px = Offset(
        corners[i].dx * _size.width,
        corners[i].dy * _size.height,
      );
      final dist = (px - p).distance;
      if (dist < bestDist) {
        best = i;
        bestDist = dist;
      }
    }
    if (best >= 0) {
      _mode = 2;
      _anchor = opposite[best];
    } else if (Rect.fromLTWH(
      r.left * _size.width,
      r.top * _size.height,
      r.width * _size.width,
      r.height * _size.height,
    ).contains(p)) {
      _mode = 1;
    } else {
      _mode = 0;
    }
  }

  void _update(DragUpdateDetails d) {
    if (_mode == 0 || _size.isEmpty) return;
    final r = widget.rect;
    if (_mode == 1) {
      final dx = d.delta.dx / _size.width;
      final dy = d.delta.dy / _size.height;
      final left = (r.left + dx).clamp(0.0, 1 - r.width);
      final top = (r.top + dy).clamp(0.0, 1 - r.height);
      widget.onChanged(Rect.fromLTWH(left, top, r.width, r.height));
      return;
    }
    final p = Offset(
      (d.localPosition.dx / _size.width).clamp(0.0, 1.0),
      (d.localPosition.dy / _size.height).clamp(0.0, 1.0),
    );
    widget.onChanged(resizeCrop(_anchor, p, widget.lock, _size));
  }

  /// New crop for a corner dragged to [p] while the opposite corner [anchor] stays put.
  static Rect resizeCrop(Offset anchor, Offset p, double? lock, Size box) {
    final dirX = p.dx >= anchor.dx ? 1.0 : -1.0;
    final dirY = p.dy >= anchor.dy ? 1.0 : -1.0;
    var w = (p.dx - anchor.dx).abs();
    var h = (p.dy - anchor.dy).abs();
    if (lock != null) {
      // keep (w * box.width) / (h * box.height) == lock
      final k = box.width / (lock * box.height);
      h = w * k;
      final maxW = dirX > 0 ? 1 - anchor.dx : anchor.dx;
      final maxH = dirY > 0 ? 1 - anchor.dy : anchor.dy;
      if (w > maxW) {
        w = maxW;
        h = w * k;
      }
      if (h > maxH) {
        h = maxH;
        w = h / k;
      }
      if (w < _min) {
        w = _min;
        h = w * k;
      }
      if (h > maxH) {
        h = maxH;
        w = h / k;
      }
    } else {
      w = math.max(w, _min);
      h = math.max(h, _min);
    }
    final left = dirX > 0 ? anchor.dx : anchor.dx - w;
    final top = dirY > 0 ? anchor.dy : anchor.dy - h;
    return Rect.fromLTWH(
      left.clamp(0.0, 1.0),
      top.clamp(0.0, 1.0),
      math.min(w, 1.0),
      math.min(h, 1.0),
    );
  }

  @override
  Widget build(BuildContext context) {
    return LayoutBuilder(
      builder: (context, c) {
        _size = Size(c.maxWidth, c.maxHeight);
        return GestureDetector(
          behavior: HitTestBehavior.opaque,
          onPanStart: _start,
          onPanUpdate: _update,
          onPanEnd: (_) => _mode = 0,
          child: CustomPaint(size: _size, painter: _CropPainter(widget.rect)),
        );
      },
    );
  }
}

class _CropPainter extends CustomPainter {
  _CropPainter(this.rect);
  final Rect rect;

  @override
  void paint(Canvas canvas, Size size) {
    final r = Rect.fromLTWH(
      rect.left * size.width,
      rect.top * size.height,
      rect.width * size.width,
      rect.height * size.height,
    );
    final dim = Path.combine(
      PathOperation.difference,
      Path()..addRect(Offset.zero & size),
      Path()..addRect(r),
    );
    canvas.drawPath(dim, Paint()..color = Colors.black.withValues(alpha: 0.62));

    final line = Paint()
      ..color = Colors.white.withValues(alpha: 0.35)
      ..strokeWidth = 1;
    for (var i = 1; i < 3; i++) {
      final x = r.left + r.width * i / 3;
      final y = r.top + r.height * i / 3;
      canvas.drawLine(Offset(x, r.top), Offset(x, r.bottom), line);
      canvas.drawLine(Offset(r.left, y), Offset(r.right, y), line);
    }
    canvas.drawRect(
      r,
      Paint()
        ..color = Colors.white
        ..style = PaintingStyle.stroke
        ..strokeWidth = 1.5,
    );

    final corner = Paint()
      ..color = AppTheme.volt
      ..strokeWidth = 4
      ..strokeCap = StrokeCap.square;
    const l = 22.0;
    void bracket(Offset o, double sx, double sy) {
      canvas.drawLine(o, o + Offset(l * sx, 0), corner);
      canvas.drawLine(o, o + Offset(0, l * sy), corner);
    }

    bracket(r.topLeft, 1, 1);
    bracket(r.topRight, -1, 1);
    bracket(r.bottomLeft, 1, -1);
    bracket(r.bottomRight, -1, -1);
  }

  @override
  bool shouldRepaint(_CropPainter old) => old.rect != rect;
}
