import 'dart:io';
import 'dart:math' as math;
import 'dart:ui' as ui;

import 'package:cached_network_image/cached_network_image.dart';
import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:flutter/scheduler.dart';
import 'package:video_player/video_player.dart';

import '../core/media_url.dart';
import '../models/finish.dart';
import '../services/playhead.dart';

/// Photos and videos placed over a clip (blend, chroma key, mask, animation), drawn live
/// while the clip plays, plus the smooth clock that moves them.

/// Test hook: makes video layers without opening a real player.
VideoPlayerController Function(String ref)? debugLayerController;

/// The clip's position in seconds, updated every frame while it plays (the player itself
/// only reports a few times a second).
class PlayerClock extends ValueNotifier<double> {
  PlayerClock(this.player) : super(_sec(player.value)) {
    player.addListener(_onPlayer);
    _ticker = Ticker(_onTick)..start();
    _onPlayer();
  }

  final ValueListenable<VideoPlayerValue> player;
  final PlayheadSmoother _smooth = PlayheadSmoother();
  late final Ticker _ticker;
  Duration _now = Duration.zero;

  static double _sec(VideoPlayerValue v) => v.position.inMicroseconds / 1e6;

  void _onPlayer() {
    final v = player.value;
    _smooth.rate = v.playbackSpeed <= 0 ? 1 : v.playbackSpeed;
    _smooth.report(_sec(v), v.isPlaying, _now);
    if (!v.isPlaying) value = _sec(v);
  }

  void _onTick(Duration now) {
    _now = now;
    if (!_smooth.playing) return;
    final d = player.value.duration.inMicroseconds / 1e6;
    var s = _smooth.value(now);
    if (d > 0 && s > d) s = d;
    value = s;
  }

  @override
  void dispose() {
    player.removeListener(_onPlayer);
    _ticker.dispose();
    super.dispose();
  }
}

/// Moves, turns, scales and fades [child] for one frame of an animation on a canvas of
/// [canvas] size.
Widget applyMotion(Widget child, MotionFrame m, Size canvas) {
  if (m.isRest) return child;
  var w = child;
  if (m.scale != 1 || m.turns != 0) {
    w = Transform(
      alignment: Alignment.center,
      transform: Matrix4.identity()
        ..scaleByDouble(m.scale, m.scale, 1, 1)
        ..rotateZ(m.turns * 2 * math.pi),
      child: w,
    );
  }
  if (m.dx != 0 || m.dy != 0) {
    w = Transform.translate(
      offset: Offset(m.dx * canvas.width, m.dy * canvas.height),
      child: w,
    );
  }
  if (m.opacity < 1) w = Opacity(opacity: m.opacity.clamp(0.0, 1.0), child: w);
  return w;
}

/// Shows only [mask]'s shape of [child] (with a soft edge), or everything but the shape.
class MaskedBox extends StatefulWidget {
  const MaskedBox({super.key, required this.mask, required this.child});
  final LayerMask? mask;
  final Widget child;

  @override
  State<MaskedBox> createState() => _MaskedBoxState();
}

class _MaskedBoxState extends State<MaskedBox> {
  ui.Image? _img;
  LayerMask? _for;
  Size _size = Size.zero;

  ui.Image _image(LayerMask m, Size s) {
    if (_img != null && _for == m && _size == s) return _img!;
    _img?.dispose();
    final rec = ui.PictureRecorder();
    final canvas = Canvas(rec);
    final blur = m.feather * math.min(s.width, s.height) / 2;
    final paint = Paint()..color = Colors.white;
    if (blur > 0.5) paint.maskFilter = MaskFilter.blur(BlurStyle.normal, blur);
    canvas.drawPath(m.path(s), paint);
    final w = math.max(1, s.width.ceil());
    final h = math.max(1, s.height.ceil());
    _img = rec.endRecording().toImageSync(w, h);
    _for = m;
    _size = s;
    return _img!;
  }

  @override
  void dispose() {
    _img?.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final m = widget.mask;
    if (m == null) return widget.child;
    return LayoutBuilder(
      builder: (context, box) {
        final s = box.biggest;
        if (!s.isFinite || s.isEmpty) return widget.child;
        final img = _image(m, s);
        return ShaderMask(
          key: const ValueKey('maskedBox'),
          blendMode: m.invert ? BlendMode.dstOut : BlendMode.dstIn,
          shaderCallback: (r) => ImageShader(
            img,
            TileMode.decal,
            TileMode.decal,
            (Matrix4.identity()..scaleByDouble(
                  r.width / img.width,
                  r.height / img.height,
                  1,
                  1,
                ))
                .storage,
          ),
          child: widget.child,
        );
      },
    );
  }
}

/// Blends [child] with what is under it ([mode] other than srcOver). Works over a playing
/// video: the layer starts see-through and is put down with the blend mode.
Widget blendWith(BlendMode mode, Widget child) {
  if (mode == BlendMode.srcOver) return child;
  return ClipRect(
    child: BackdropFilter(
      filter: const ColorFilter.matrix(<double>[
        0, 0, 0, 0, 0, //
        0, 0, 0, 0, 0, //
        0, 0, 0, 0, 0, //
        0, 0, 0, 0, 0,
      ]),
      blendMode: mode,
      child: child,
    ),
  );
}

/// The picture of one layer (photo, or a muted video kept in step with the clip).
class LayerPicture extends StatefulWidget {
  const LayerPicture({
    super.key,
    required this.layer,
    this.clock,
    this.playing,
  });
  final MediaLayer layer;

  /// The clip's position (video layers follow it).
  final ValueListenable<double>? clock;

  /// Whether the clip plays (video layers pause with it).
  final ValueListenable<bool>? playing;

  @override
  State<LayerPicture> createState() => _LayerPictureState();
}

class _LayerPictureState extends State<LayerPicture> {
  VideoPlayerController? _c;
  bool _ready = false;
  double _lastSeek = -10;

  @override
  void initState() {
    super.initState();
    if (widget.layer.video) _open();
  }

  @override
  void didUpdateWidget(LayerPicture old) {
    super.didUpdateWidget(old);
    if (old.layer.ref != widget.layer.ref) {
      _close();
      if (widget.layer.video) _open();
    }
    if (old.clock != widget.clock) {
      old.clock?.removeListener(_sync);
      widget.clock?.addListener(_sync);
    }
    if (old.playing != widget.playing) {
      old.playing?.removeListener(_sync);
      widget.playing?.addListener(_sync);
    }
  }

  void _open() {
    final ref = widget.layer.ref;
    final hook = debugLayerController;
    final c = hook != null
        ? hook(ref)
        : widget.layer.isLocal
        ? VideoPlayerController.file(File(ref))
        : VideoPlayerController.networkUrl(Uri.parse(resolveMediaUrl(ref)));
    _c = c;
    widget.clock?.addListener(_sync);
    widget.playing?.addListener(_sync);
    c
        .initialize()
        .then((_) async {
          if (!mounted || _c != c) return;
          await c.setVolume(0);
          await c.setLooping(true);
          setState(() => _ready = true);
          _sync();
        })
        .catchError((Object _) {});
  }

  void _close() {
    widget.clock?.removeListener(_sync);
    widget.playing?.removeListener(_sync);
    _c?.dispose();
    _c = null;
    _ready = false;
  }

  /// Keeps the layer at (clip position - layer start), looping if it is shorter.
  void _sync() {
    final c = _c;
    if (c == null || !_ready) return;
    final d = c.value.duration.inMicroseconds / 1e6;
    final clip = widget.clock?.value ?? 0;
    var want = math.max(0.0, clip - widget.layer.from);
    if (d > 0) want = want % d;
    final have = c.value.position.inMicroseconds / 1e6;
    final play = widget.playing?.value ?? true;
    if ((want - have).abs() > 0.25 && (clip - _lastSeek).abs() > 0.2) {
      _lastSeek = clip;
      c.seekTo(Duration(microseconds: (want * 1e6).round())).ignore();
    }
    if (play && !c.value.isPlaying) c.play().ignore();
    if (!play && c.value.isPlaying) c.pause().ignore();
  }

  @override
  void dispose() {
    _close();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final l = widget.layer;
    Widget pic;
    if (l.video) {
      final c = _c;
      pic = c != null && _ready
          ? VideoPlayer(c)
          : const ColoredBox(color: Color(0x33000000));
    } else if (l.isLocal) {
      pic = Image.file(File(l.ref), fit: BoxFit.cover, gaplessPlayback: true);
    } else {
      pic = CachedNetworkImage(
        imageUrl: resolveMediaUrl(l.ref),
        fit: BoxFit.cover,
        fadeInDuration: Duration.zero,
      );
    }
    final k = l.chroma;
    if (k != null) {
      pic = ColorFiltered(
        colorFilter: ColorFilter.matrix(k.matrix),
        child: pic,
      );
    }
    return MaskedBox(mask: l.mask, child: pic);
  }
}

/// Size of a layer on a canvas of [canvas].
Size layerSize(MediaLayer l, Size canvas) {
  final w = canvas.width * l.scale;
  return Size(w, w / (l.aspect <= 0 ? 1 : l.aspect));
}

/// The layers over a clip, shown in their time ranges and animated.
class LayerStack extends StatelessWidget {
  const LayerStack({
    super.key,
    required this.layers,
    this.clock,
    this.playing,
    this.clipSeconds = 0,
  });
  final List<MediaLayer> layers;
  final ValueListenable<double>? clock;
  final ValueListenable<bool>? playing;

  /// Length of the clip (an animation out of a layer shown to the end ends here).
  final double clipSeconds;

  @override
  Widget build(BuildContext context) {
    if (layers.isEmpty) return const SizedBox.shrink();
    return IgnorePointer(
      child: LayoutBuilder(
        builder: (context, box) {
          final canvas = box.biggest;
          final pics = [
            for (var i = 0; i < layers.length; i++)
              LayerPicture(
                key: ValueKey('layerPic$i${layers[i].ref}'),
                layer: layers[i],
                clock: clock,
                playing: playing,
              ),
          ];
          Widget frame(double sec) => Stack(
            clipBehavior: Clip.hardEdge,
            children: [
              for (var i = 0; i < layers.length; i++)
                if (layers[i].visibleAt(sec))
                  _placed(layers[i], pics[i], canvas, sec, i),
            ],
          );
          final c = clock;
          if (c == null) return frame(0);
          return ValueListenableBuilder<double>(
            valueListenable: c,
            builder: (_, sec, _) => frame(sec),
          );
        },
      ),
    );
  }

  Widget _placed(MediaLayer l, Widget pic, Size canvas, double sec, int i) {
    final s = layerSize(l, canvas);
    Widget w = SizedBox(width: s.width, height: s.height, child: pic);
    if (l.turns != 0) {
      w = Transform.rotate(angle: l.turns * 2 * math.pi, child: w);
    }
    if (l.opacity < 1) w = Opacity(opacity: l.opacity, child: w);
    w = applyMotion(
      w,
      motionAt(l.anim, sec, from: l.from, to: l.to, clipEnd: clipSeconds),
      canvas,
    );
    return Positioned(
      key: ValueKey('layer$i'),
      left: l.dx * canvas.width - s.width / 2,
      top: l.dy * canvas.height - s.height / 2,
      width: s.width,
      height: s.height,
      child: blendWith(l.blendMode, w),
    );
  }
}

/// [player]'s playing state as a listenable.
class PlayingFlag extends ValueNotifier<bool> {
  PlayingFlag(this.player) : super(player.value.isPlaying) {
    player.addListener(_on);
  }
  final ValueListenable<VideoPlayerValue> player;
  void _on() => value = player.value.isPlaying;

  @override
  void dispose() {
    player.removeListener(_on);
    super.dispose();
  }
}

/// Seconds of a clip from a player value (0 without one).
double playerSeconds(VideoPlayerValue? v) =>
    v == null ? 0 : v.duration.inMicroseconds / 1e6;

/// Starts the smooth clock for [player] when there is anything that moves.
PlayerClock? clockFor(ValueListenable<VideoPlayerValue>? player, bool needed) =>
    player != null && needed ? PlayerClock(player) : null;
