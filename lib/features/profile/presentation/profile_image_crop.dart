import 'dart:io';
import 'dart:ui' as ui;

import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:image/image.dart' as img;

import '../../../core/theme/app_colors.dart';
import '../../../shared/widgets/skeleton.dart';

/// Banner shape on the profile page (width : height).
const double kBannerAspect = 2.5;

/// Size + shape of a profile picture or banner.
class ProfileImageSpec {
  const ProfileImageSpec._(this.aspect, this.width, this.height, this.hint);

  final double aspect;
  final int width;
  final int height;

  /// Helpful text shown in Edit profile.
  final String hint;

  /// Round profile photo: square.
  static const ProfileImageSpec photo = ProfileImageSpec._(
    1,
    1080,
    1080,
    'Square photo · best 1080 × 1080 px (at least 400 × 400)',
  );

  /// Banner on top of the profile: wide 5:2.
  static const ProfileImageSpec banner = ProfileImageSpec._(
    kBannerAspect,
    1500,
    600,
    'Wide photo 5:2 · best 1500 × 600 px',
  );
}

/// Part of the picture that is inside the frame, in picture pixels.
/// [frame] = frame size on screen, [imageW]/[imageH] = picture size,
/// [scale]/[dx]/[dy] = zoom + move of the picture (picture first fills
/// the frame like BoxFit.cover).
@visibleForTesting
Rect cropRect({
  required Size frame,
  required int imageW,
  required int imageH,
  required double scale,
  required double dx,
  required double dy,
}) {
  final fit = [
    frame.width / imageW,
    frame.height / imageH,
  ].reduce((a, b) => a > b ? a : b); // cover
  final s = fit * scale;
  var left = -dx / s;
  var top = -dy / s;
  var w = frame.width / s;
  var h = frame.height / s;
  w = w.clamp(1.0, imageW.toDouble());
  h = h.clamp(1.0, imageH.toDouble());
  left = left.clamp(0.0, imageW - w);
  top = top.clamp(0.0, imageH - h);
  return Rect.fromLTWH(left, top, w, h);
}

/// Crops + resizes (never makes it bigger) + saves as JPEG.
@visibleForTesting
Uint8List cropAndResize(Uint8List bytes, Rect r, int outW, int outH) {
  final decoded = img.decodeImage(bytes);
  if (decoded == null) throw StateError('Not a picture');
  final src = img.bakeOrientation(decoded);
  final cropped = img.copyCrop(
    src,
    x: r.left.round(),
    y: r.top.round(),
    width: r.width.round().clamp(1, src.width),
    height: r.height.round().clamp(1, src.height),
  );
  final out = cropped.width > outW
      ? img.copyResize(
          cropped,
          width: outW,
          height: outH,
          interpolation: img.Interpolation.average,
        )
      : cropped;
  return Uint8List.fromList(img.encodeJpg(out, quality: 90));
}

Uint8List _cropJob(Map<String, Object> a) => cropAndResize(
  a['bytes']! as Uint8List,
  a['rect']! as Rect,
  a['w']! as int,
  a['h']! as int,
);

/// Full-screen "move and zoom" step. Returns the cropped file (or null).
Future<File?> cropProfileImage(
  BuildContext context,
  File file,
  ProfileImageSpec spec,
) => Navigator.of(context).push<File>(
  MaterialPageRoute(
    fullscreenDialog: true,
    builder: (_) => ProfileCropScreen(file: file, spec: spec),
  ),
);

class ProfileCropScreen extends StatefulWidget {
  const ProfileCropScreen({super.key, required this.file, required this.spec});

  final File file;
  final ProfileImageSpec spec;

  @override
  State<ProfileCropScreen> createState() => _ProfileCropScreenState();
}

class _ProfileCropScreenState extends State<ProfileCropScreen> {
  final TransformationController _t = TransformationController();
  Uint8List? _bytes;
  int _w = 0;
  int _h = 0;
  Size _frame = Size.zero;
  bool _saving = false;
  String _error = '';

  @override
  void initState() {
    super.initState();
    _load();
  }

  Future<void> _load() async {
    try {
      final bytes = await widget.file.readAsBytes();
      final codec = await ui.instantiateImageCodec(bytes);
      final frame = await codec.getNextFrame();
      if (!mounted) return;
      setState(() {
        _bytes = bytes;
        _w = frame.image.width;
        _h = frame.image.height;
      });
      frame.image.dispose();
    } catch (_) {
      if (mounted) setState(() => _error = "Couldn't open this picture");
    }
  }

  @override
  void dispose() {
    _t.dispose();
    super.dispose();
  }

  Future<void> _done() async {
    final bytes = _bytes;
    if (bytes == null || _frame == Size.zero) return;
    setState(() => _saving = true);
    try {
      final m = _t.value;
      final r = cropRect(
        frame: _frame,
        imageW: _w,
        imageH: _h,
        scale: m.getMaxScaleOnAxis(),
        dx: m.getTranslation().x,
        dy: m.getTranslation().y,
      );
      final out = await compute(_cropJob, <String, Object>{
        'bytes': bytes,
        'rect': r,
        'w': widget.spec.width,
        'h': widget.spec.height,
      });
      final dir = await Directory.systemTemp.createTemp('ig_crop');
      final f = File(
        '${dir.path}/crop_${DateTime.now().millisecondsSinceEpoch}.jpg',
      );
      await f.writeAsBytes(out, flush: true);
      if (mounted) Navigator.of(context).pop(f);
    } catch (_) {
      if (mounted) {
        setState(() => _saving = false);
        ScaffoldMessenger.of(context).showSnackBar(
          const SnackBar(content: Text("Couldn't crop this picture")),
        );
      }
    }
  }

  @override
  Widget build(BuildContext context) {
    final spec = widget.spec;
    final round = spec.aspect == 1;
    return Scaffold(
      backgroundColor: Colors.black,
      appBar: AppBar(
        backgroundColor: Colors.black,
        title: Text(round ? 'Profile photo' : 'Banner'),
        actions: [
          TextButton(
            key: const ValueKey('crop-done'),
            onPressed: _bytes == null || _saving ? null : _done,
            child: _saving
                ? const SizedBox(
                    width: 18,
                    height: 18,
                    child: CircularProgressIndicator(strokeWidth: 2),
                  )
                : const Text(
                    'Done',
                    style: TextStyle(
                      color: AppColors.lime,
                      fontWeight: FontWeight.w700,
                    ),
                  ),
          ),
        ],
      ),
      body: _error.isNotEmpty
          ? Center(child: Text(_error))
          : _bytes == null
          ? const Padding(
              padding: EdgeInsets.all(16),
              child: ShimmerFill(radius: 16),
            )
          : LayoutBuilder(
              builder: (context, box) {
                final fw = box.maxWidth - 32;
                final fh = (fw / spec.aspect).clamp(80.0, box.maxHeight - 120);
                final frame = Size(fh * spec.aspect, fh);
                _frame = frame;
                final fit = [
                  frame.width / _w,
                  frame.height / _h,
                ].reduce((a, b) => a > b ? a : b);
                final cw = _w * fit;
                final ch = _h * fit;
                return Column(
                  mainAxisAlignment: MainAxisAlignment.center,
                  children: [
                    Center(
                      child: SizedBox(
                        width: frame.width,
                        height: frame.height,
                        child: ClipRRect(
                          borderRadius: BorderRadius.circular(
                            round ? frame.width / 2 : 16,
                          ),
                          child: _CenteredViewer(
                            controller: _t,
                            frame: frame,
                            child: SizedBox(
                              width: cw,
                              height: ch,
                              child: Image.memory(
                                _bytes!,
                                fit: BoxFit.fill,
                                gaplessPlayback: true,
                              ),
                            ),
                          ),
                        ),
                      ),
                    ),
                    const SizedBox(height: 18),
                    Text(
                      'Pinch to zoom, drag to move',
                      style: TextStyle(
                        color: Colors.white.withValues(alpha: 0.8),
                        fontWeight: FontWeight.w600,
                      ),
                    ),
                    const SizedBox(height: 4),
                    Text(
                      spec.hint,
                      style: const TextStyle(
                        color: AppColors.textSecondary,
                        fontSize: 12.5,
                      ),
                    ),
                  ],
                );
              },
            ),
    );
  }
}

/// InteractiveViewer that starts with the picture centered in the frame.
class _CenteredViewer extends StatefulWidget {
  const _CenteredViewer({
    required this.controller,
    required this.frame,
    required this.child,
  });

  final TransformationController controller;
  final Size frame;
  final SizedBox child;

  @override
  State<_CenteredViewer> createState() => _CenteredViewerState();
}

class _CenteredViewerState extends State<_CenteredViewer> {
  Size? _centeredFor;

  void _center() {
    final f = widget.frame;
    if (_centeredFor == f) return;
    _centeredFor = f;
    final dx = (f.width - (widget.child.width ?? f.width)) / 2;
    final dy = (f.height - (widget.child.height ?? f.height)) / 2;
    // never set the controller during build
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (!mounted) return;
      widget.controller.value = Matrix4.translationValues(dx, dy, 0);
    });
  }

  @override
  Widget build(BuildContext context) {
    _center();
    return InteractiveViewer(
      transformationController: widget.controller,
      constrained: false,
      boundaryMargin: EdgeInsets.zero,
      minScale: 1,
      maxScale: 6,
      child: widget.child,
    );
  }
}
