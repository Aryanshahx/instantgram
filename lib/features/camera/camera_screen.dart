import 'dart:async';
import 'dart:io';

import 'package:camera/camera.dart';
import 'package:clock/clock.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

import '../../core/services/media_service.dart';
import '../../core/services/music_player.dart';
import '../../core/theme/app_colors.dart';
import '../editor/edit_models.dart';
import '../editor/filters.dart';
import '../music/presentation/music_picker_sheet.dart';

/// What our camera gives back: the photo / video (or gallery picks) and
/// the song chosen in the camera.
class CameraResult {
  const CameraResult(this.media, {this.audio});
  final List<PickedMedia> media;
  final PickedAudio? audio;
}

/// Opens our camera (like Instagram): filters, music, length, timer,
/// flash, zoom, flip, record in parts. null = closed.
Future<CameraResult?> openCamera(
  BuildContext context, {
  required ComposeMode mode,
  bool video = true,
  PickedAudio? audio,
}) {
  return Navigator.of(context).push<CameraResult>(
    MaterialPageRoute(
      fullscreenDialog: true,
      builder: (_) => CameraScreen(mode: mode, startVideo: video, audio: audio),
    ),
  );
}

const String _kMusic = 'camera-music';

class CameraScreen extends StatefulWidget {
  const CameraScreen({
    super.key,
    required this.mode,
    this.startVideo = true,
    this.audio,
  });

  final ComposeMode mode;
  final bool startVideo;
  final PickedAudio? audio;

  /// Tests: no real cameras.
  static Future<List<CameraDescription>> Function() cameras = availableCameras;

  @override
  State<CameraScreen> createState() => _CameraScreenState();
}

class _CameraScreenState extends State<CameraScreen>
    with WidgetsBindingObserver {
  List<CameraDescription> _cams = const [];
  int _camIndex = 0;
  CameraController? _ctrl;
  bool _starting = false;
  String? _error;
  bool _withSound = true;

  late bool _video = widget.startVideo;
  late PickedAudio? _audio = widget.audio;

  // look
  int _filter = 0;
  bool _showFilters = false;
  bool _showFilterName = false;
  Timer? _filterNameTimer;
  double _swipeDx = 0;

  // controls
  FlashMode _flash = FlashMode.off;
  bool _torch = false;
  double _minZoom = 1;
  double _maxZoom = 1;
  double _zoom = 1;
  double _zoomAtStart = 1;
  Offset? _focusAt;
  Timer? _focusTimer;
  late int _maxSec = _maxAllowed;
  int _timer = 0;
  int? _countdown;
  Timer? _countdownTimer;

  // recording
  bool _recording = false; // a video file is open (recording or paused)
  bool _paused = false;
  bool _busy = false;
  bool _holding = false;
  bool _finishing = false;
  final List<int> _parts = [];
  final Stopwatch _sw = clock.stopwatch();
  Timer? _tick;

  int get _maxAllowed => widget.mode == ComposeMode.story ? 60 : 90;
  List<int> get _lengths =>
      [15, 30, 60, 90].where((s) => s <= _maxAllowed).toList();
  int get _recordedMs =>
      _parts.fold<int>(0, (a, b) => a + b) + _sw.elapsedMilliseconds;
  bool get _front =>
      _cams.isNotEmpty &&
      _cams[_camIndex].lensDirection == CameraLensDirection.front;

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addObserver(this);
    _init();
  }

  @override
  void dispose() {
    WidgetsBinding.instance.removeObserver(this);
    _tick?.cancel();
    _countdownTimer?.cancel();
    _filterNameTimer?.cancel();
    _focusTimer?.cancel();
    MusicPlayer.instance.stop(_kMusic);
    _ctrl?.dispose();
    super.dispose();
  }

  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    if (state == AppLifecycleState.inactive) {
      if (_starting) return; // the "allow camera" question
      if (_recording) {
        _finish(); // keep what was filmed
        return;
      }
      final c = _ctrl;
      if (c != null) {
        setState(() => _ctrl = null);
        c.dispose();
      }
    } else if (state == AppLifecycleState.resumed) {
      if (_ctrl == null && !_starting && _error == null && mounted) _init();
    }
  }

  // ------------------------------------------------------------- camera

  Future<void> _init() async {
    if (_starting) return;
    setState(() {
      _starting = true;
      _error = null;
    });
    try {
      if (_cams.isEmpty) {
        _cams = await CameraScreen.cameras();
        final back = _cams.indexWhere(
          (c) => c.lensDirection == CameraLensDirection.back,
        );
        _camIndex = back < 0 ? 0 : back;
      }
      if (_cams.isEmpty) {
        _fail('No camera found on this phone.');
        return;
      }
      await _open(_cams[_camIndex]);
    } on CameraException catch (e) {
      _fail(_why(e));
    } catch (e) {
      _fail('Camera could not start.');
    } finally {
      if (mounted) setState(() => _starting = false);
    }
  }

  Future<void> _open(CameraDescription cam) async {
    Future<CameraController> make(bool sound) async {
      final c = CameraController(
        cam,
        ResolutionPreset.veryHigh,
        enableAudio: sound,
        fps: 30,
      );
      try {
        await c.initialize();
      } catch (_) {
        await c.dispose();
        rethrow;
      }
      return c;
    }

    CameraController c;
    try {
      c = await make(_withSound);
    } on CameraException catch (e) {
      // microphone not allowed: film without sound
      if (!e.code.toLowerCase().contains('audio')) rethrow;
      _withSound = false;
      c = await make(false);
    }
    if (!mounted) {
      await c.dispose();
      return;
    }
    try {
      await c.lockCaptureOrientation(DeviceOrientation.portraitUp);
    } catch (_) {}
    var min = 1.0, max = 1.0;
    try {
      min = await c.getMinZoomLevel();
      max = await c.getMaxZoomLevel();
    } catch (_) {}
    try {
      await c.setFlashMode(_video ? FlashMode.off : _flash);
    } catch (_) {}
    _torch = false;
    setState(() {
      _ctrl = c;
      _minZoom = min;
      _maxZoom = max < min ? min : (max > 10 ? 10 : max);
      _zoom = min;
    });
  }

  String _why(CameraException e) {
    final c = e.code.toLowerCase();
    if (c.contains('denied') || c.contains('permission')) {
      return 'Allow the camera in your phone settings to film here.';
    }
    return 'Camera could not start (${e.description ?? e.code}).';
  }

  void _fail(String why) {
    if (!mounted) return;
    setState(() {
      _error = why;
      _starting = false;
    });
  }

  Future<void> _flip() async {
    if (_cams.length < 2 || _busy || _ctrl == null) return;
    final next = (_camIndex + 1) % _cams.length;
    final c = _ctrl!;
    _busy = true;
    try {
      if (_recording) {
        // keeps filming with the other camera
        await c.setDescription(_cams[next]);
        _camIndex = next;
      } else {
        setState(() => _ctrl = null);
        await c.dispose();
        _camIndex = next;
        await _open(_cams[next]);
      }
    } on CameraException catch (e) {
      _snack(_why(e));
    } catch (_) {
      _snack("Couldn't switch camera");
    } finally {
      _busy = false;
      if (mounted) setState(() {});
    }
  }

  Future<void> _setZoom(double z) async {
    final c = _ctrl;
    if (c == null) return;
    final v = z.clamp(_minZoom, _maxZoom).toDouble();
    if ((v - _zoom).abs() < 0.01) return;
    setState(() => _zoom = v);
    try {
      await c.setZoomLevel(v);
    } catch (_) {}
  }

  Future<void> _focus(TapUpDetails d, Size box) async {
    final c = _ctrl;
    if (c == null || !c.value.isInitialized) return;
    final p = Offset(
      (d.localPosition.dx / box.width).clamp(0.0, 1.0),
      (d.localPosition.dy / box.height).clamp(0.0, 1.0),
    );
    setState(() => _focusAt = d.localPosition);
    _focusTimer?.cancel();
    _focusTimer = Timer(const Duration(milliseconds: 900), () {
      if (mounted) setState(() => _focusAt = null);
    });
    try {
      if (c.value.focusPointSupported) await c.setFocusPoint(p);
      if (c.value.exposurePointSupported) await c.setExposurePoint(p);
    } catch (_) {}
  }

  Future<void> _toggleFlash() async {
    final c = _ctrl;
    if (c == null) return;
    try {
      if (_video) {
        final on = !_torch;
        await c.setFlashMode(on ? FlashMode.torch : FlashMode.off);
        setState(() => _torch = on);
      } else {
        final next = switch (_flash) {
          FlashMode.off => FlashMode.auto,
          FlashMode.auto => FlashMode.always,
          _ => FlashMode.off,
        };
        await c.setFlashMode(next);
        setState(() => _flash = next);
      }
    } catch (_) {
      _snack('Flash is not available');
    }
  }

  Future<void> _setMode(bool video) async {
    if (video == _video || _recording || _countdown != null) return;
    setState(() => _video = video);
    final c = _ctrl;
    if (c == null) return;
    try {
      await c.setFlashMode(video ? FlashMode.off : _flash);
      _torch = false;
    } catch (_) {}
  }

  void _setFilter(int i) {
    final n = kFilterPresets.length;
    setState(() {
      _filter = (i % n + n) % n;
      _showFilterName = true;
    });
    _filterNameTimer?.cancel();
    _filterNameTimer = Timer(const Duration(milliseconds: 900), () {
      if (mounted) setState(() => _showFilterName = false);
    });
  }

  void _snack(String text) {
    if (!mounted) return;
    ScaffoldMessenger.of(context)
      ..hideCurrentSnackBar()
      ..showSnackBar(SnackBar(content: Text(text)));
  }

  // -------------------------------------------------------------- music

  Future<void> _pickAudio() async {
    if (_recording) return;
    final a = await showMusicPicker(context);
    if (a != null && mounted) setState(() => _audio = a);
  }

  String get _audioSrc {
    final a = _audio;
    if (a == null) return '';
    return a.url.isNotEmpty ? a.url : a.file.path;
  }

  // ------------------------------------------------------------ capture

  /// Timer on: count down, then [go].
  void _afterTimer(VoidCallback go) {
    if (_timer == 0) {
      go();
      return;
    }
    setState(() => _countdown = _timer);
    _countdownTimer?.cancel();
    _countdownTimer = Timer.periodic(const Duration(seconds: 1), (t) {
      if (!mounted) return t.cancel();
      final left = (_countdown ?? 1) - 1;
      if (left <= 0) {
        t.cancel();
        setState(() => _countdown = null);
        go();
      } else {
        setState(() => _countdown = left);
      }
    });
  }

  void _cancelCountdown() {
    _countdownTimer?.cancel();
    setState(() => _countdown = null);
  }

  void _onShutterTap() {
    if (_countdown != null) return _cancelCountdown();
    if (_ctrl == null || _busy) return;
    if (!_video) return _afterTimer(_shoot);
    if (!_recording) return _afterTimer(_start);
    _paused ? _resume() : _pause();
  }

  void _onHoldStart() {
    if (!_video || _ctrl == null || _busy || _countdown != null) return;
    if (!_recording) {
      _holding = true;
      _start();
    } else if (_paused) {
      _holding = true;
      _resume();
    }
  }

  void _onHoldEnd() {
    if (!_holding) return;
    _holding = false;
    _pause();
  }

  Future<void> _shoot() async {
    final c = _ctrl;
    if (c == null || _busy) return;
    setState(() => _busy = true);
    try {
      final x = await c.takePicture();
      if (!mounted) return;
      Navigator.of(context).pop(
        CameraResult([
          PickedMedia(File(x.path), isVideo: false, filterPreset: _filter),
        ], audio: _audio),
      );
    } catch (_) {
      _snack("Couldn't take the photo. Try again.");
      if (mounted) setState(() => _busy = false);
    }
  }

  Future<void> _start() async {
    final c = _ctrl;
    if (c == null || _busy || _recording) return;
    setState(() => _busy = true);
    try {
      await c.startVideoRecording();
    } catch (_) {
      _holding = false;
      _snack("Couldn't start filming. Try again.");
      if (mounted) setState(() => _busy = false);
      return;
    }
    if (!mounted) return;
    _parts.clear();
    _sw
      ..reset()
      ..start();
    _startTick();
    final src = _audioSrc;
    if (src.isNotEmpty) {
      MusicPlayer.instance.play(_kMusic, src, startMs: _audio!.startMs);
    }
    setState(() {
      _recording = true;
      _paused = false;
      _busy = false;
      _showFilters = false;
    });
  }

  Future<void> _pause() async {
    final c = _ctrl;
    if (c == null || !_recording || _paused || _busy) return;
    _sw.stop();
    _tick?.cancel();
    MusicPlayer.instance.pause(_kMusic);
    setState(() => _busy = true);
    try {
      await c.pauseVideoRecording();
    } catch (_) {
      // this phone can't pause: keep what was filmed
      _busy = false;
      await _finish();
      return;
    }
    if (!mounted) return;
    _parts.add(_sw.elapsedMilliseconds);
    _sw.reset();
    setState(() {
      _paused = true;
      _busy = false;
    });
  }

  Future<void> _resume() async {
    final c = _ctrl;
    if (c == null || !_paused || _busy) return;
    setState(() => _busy = true);
    try {
      await c.resumeVideoRecording();
    } catch (_) {
      _holding = false;
      _snack("Couldn't continue. Tap ✓ to keep your video.");
      if (mounted) setState(() => _busy = false);
      return;
    }
    if (!mounted) return;
    _sw.start();
    _startTick();
    MusicPlayer.instance.resume(_kMusic);
    setState(() {
      _paused = false;
      _busy = false;
    });
  }

  void _startTick() {
    _tick?.cancel();
    _tick = Timer.periodic(const Duration(milliseconds: 50), (_) {
      if (!mounted) return;
      if (_recordedMs >= _maxSec * 1000) {
        _finish();
      } else {
        setState(() {});
      }
    });
  }

  /// Stops filming and goes on to the editor.
  Future<void> _finish() async {
    final c = _ctrl;
    if (c == null || !_recording || _finishing) return;
    _finishing = true;
    _holding = false;
    _sw.stop();
    _tick?.cancel();
    MusicPlayer.instance.stop(_kMusic);
    setState(() => _busy = true);
    try {
      final x = await c.stopVideoRecording();
      if (!mounted) return;
      Navigator.of(context).pop(
        CameraResult([
          PickedMedia(
            File(x.path),
            isVideo: true,
            filterPreset: _filter,
            muted: _audio != null,
          ),
        ], audio: _audio),
      );
    } catch (_) {
      _snack("Couldn't save the video. Try again.");
      _reset();
    } finally {
      _finishing = false;
    }
  }

  Future<void> _next() async {
    if (_busy && !_paused) return;
    if (_recordedMs < 500) {
      _snack('Film a little longer');
      return;
    }
    await _finish();
  }

  void _reset() {
    _tick?.cancel();
    _sw
      ..stop()
      ..reset();
    _parts.clear();
    if (mounted) {
      setState(() {
        _recording = false;
        _paused = false;
        _busy = false;
      });
    }
  }

  Future<void> _retake() async {
    final ok = await showDialog<bool>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: const Text('Start over?'),
        content: const Text('What you filmed will be deleted.'),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(ctx, false),
            child: const Text('Keep'),
          ),
          TextButton(
            key: const ValueKey('camera-retake-yes'),
            onPressed: () => Navigator.pop(ctx, true),
            child: const Text(
              'Start over',
              style: TextStyle(color: AppColors.like),
            ),
          ),
        ],
      ),
    );
    if (ok != true || !mounted) return;
    final c = _ctrl;
    MusicPlayer.instance.stop(_kMusic);
    _sw.stop();
    _tick?.cancel();
    setState(() => _busy = true);
    try {
      final x = await c?.stopVideoRecording();
      if (x != null) {
        final f = File(x.path);
        if (f.existsSync()) f.deleteSync();
      }
    } catch (_) {}
    _reset();
  }

  Future<void> _gallery() async {
    if (_recording) return;
    final m = await MediaService.instance.pickGallery(context);
    if (m.isEmpty || !mounted) return;
    Navigator.of(context).pop(CameraResult(m, audio: _audio));
  }

  Future<void> _systemCamera() async {
    final m = await MediaService.instance.systemCamera(
      context,
      video: _video,
      maxSeconds: _maxSec,
    );
    if (m == null || !mounted) return;
    Navigator.of(context).pop(CameraResult([m], audio: _audio));
  }

  Future<bool> _confirmLeave() async {
    if (!_recording) return true;
    final ok = await showDialog<bool>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: const Text('Discard video?'),
        content: const Text('What you filmed will be deleted.'),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(ctx, false),
            child: const Text('Keep filming'),
          ),
          TextButton(
            key: const ValueKey('camera-discard'),
            onPressed: () => Navigator.pop(ctx, true),
            child: const Text(
              'Discard',
              style: TextStyle(color: AppColors.like),
            ),
          ),
        ],
      ),
    );
    return ok == true;
  }

  Future<void> _close() async {
    if (!await _confirmLeave() || !mounted) return;
    Navigator.of(context).pop();
  }

  // ----------------------------------------------------------------- UI

  @override
  Widget build(BuildContext context) {
    return PopScope(
      canPop: !_recording,
      onPopInvokedWithResult: (didPop, _) {
        if (!didPop) _close();
      },
      child: Scaffold(
        key: const ValueKey('camera-screen'),
        backgroundColor: Colors.black,
        body: AnnotatedRegion<SystemUiOverlayStyle>(
          value: SystemUiOverlayStyle.light,
          child: SafeArea(
            child: Column(
              children: [
                Expanded(child: _viewfinder()),
                _bottomBar(),
              ],
            ),
          ),
        ),
      ),
    );
  }

  Widget _viewfinder() {
    return ClipRRect(
      borderRadius: BorderRadius.circular(18),
      child: LayoutBuilder(
        builder: (context, box) {
          final size = Size(box.maxWidth, box.maxHeight);
          return Stack(
            children: [
              Positioned.fill(child: _preview(size)),
              if (_video)
                Positioned(
                  left: 10,
                  right: 10,
                  top: 8,
                  child: _ProgressBar(
                    key: const ValueKey('camera-progress'),
                    parts: _parts,
                    currentMs: _sw.elapsedMilliseconds,
                    maxMs: _maxSec * 1000,
                  ),
                ),
              Positioned(left: 4, right: 4, top: 16, child: _topBar()),
              if (_error == null)
                Positioned(right: 8, top: 76, child: _tools()),
              if (_showFilters && !_recording)
                Positioned(
                  left: 0,
                  right: 0,
                  bottom: 10,
                  child: _filterStrip(),
                ),
              if (_focusAt case final f?)
                Positioned(
                  left: f.dx - 32,
                  top: f.dy - 32,
                  child: IgnorePointer(
                    child: Container(
                      key: const ValueKey('camera-focus'),
                      width: 64,
                      height: 64,
                      decoration: BoxDecoration(
                        shape: BoxShape.circle,
                        border: Border.all(color: Colors.white, width: 1.5),
                      ),
                    ),
                  ),
                ),
              Positioned.fill(
                child: IgnorePointer(
                  child: Center(
                    child: AnimatedOpacity(
                      opacity: _showFilterName ? 1 : 0,
                      duration: const Duration(milliseconds: 180),
                      child: Text(
                        kFilterPresets[_filter].name,
                        key: const ValueKey('camera-filter-name'),
                        style: const TextStyle(
                          fontSize: 26,
                          fontWeight: FontWeight.w800,
                          shadows: [Shadow(blurRadius: 12)],
                        ),
                      ),
                    ),
                  ),
                ),
              ),
              if (_countdown case final n?)
                Positioned.fill(
                  child: GestureDetector(
                    onTap: _cancelCountdown,
                    child: ColoredBox(
                      color: Colors.black26,
                      child: Center(
                        child: Text(
                          '$n',
                          key: const ValueKey('camera-countdown'),
                          style: const TextStyle(
                            fontSize: 96,
                            fontWeight: FontWeight.w900,
                          ),
                        ),
                      ),
                    ),
                  ),
                ),
              if (_zoom > _minZoom + 0.05)
                Positioned(
                  left: 0,
                  right: 0,
                  bottom: _showFilters ? 96 : 14,
                  child: Center(
                    child: Container(
                      padding: const EdgeInsets.symmetric(
                        horizontal: 9,
                        vertical: 3,
                      ),
                      decoration: BoxDecoration(
                        color: Colors.black45,
                        borderRadius: BorderRadius.circular(12),
                      ),
                      child: Text(
                        '${(_zoom / _minZoom).toStringAsFixed(1)}x',
                        style: const TextStyle(
                          fontSize: 12,
                          fontWeight: FontWeight.w700,
                        ),
                      ),
                    ),
                  ),
                ),
            ],
          );
        },
      ),
    );
  }

  Widget _preview(Size size) {
    final err = _error;
    if (err != null) {
      return ColoredBox(
        key: const ValueKey('camera-error'),
        color: AppColors.surface,
        child: Center(
          child: Padding(
            padding: const EdgeInsets.all(28),
            child: Column(
              mainAxisSize: MainAxisSize.min,
              children: [
                const Icon(
                  Icons.no_photography_outlined,
                  size: 44,
                  color: AppColors.textHint,
                ),
                const SizedBox(height: 12),
                Text(err, textAlign: TextAlign.center),
                const SizedBox(height: 16),
                FilledButton(
                  key: const ValueKey('camera-system'),
                  style: FilledButton.styleFrom(
                    backgroundColor: AppColors.lime,
                    foregroundColor: Colors.black,
                  ),
                  onPressed: _systemCamera,
                  child: const Text('Use phone camera'),
                ),
                TextButton(
                  key: const ValueKey('camera-retry'),
                  onPressed: _init,
                  child: const Text('Try again'),
                ),
              ],
            ),
          ),
        ),
      );
    }
    final c = _ctrl;
    if (c == null || !c.value.isInitialized) {
      return const ColoredBox(
        color: Colors.black,
        child: Center(child: CircularProgressIndicator(color: AppColors.lime)),
      );
    }
    final ratio = c.value.aspectRatio; // long side / short side
    return GestureDetector(
      key: const ValueKey('camera-preview'),
      behavior: HitTestBehavior.opaque,
      onDoubleTap: _flip,
      onTapUp: (d) => _focus(d, size),
      onScaleStart: (_) {
        _zoomAtStart = _zoom;
        _swipeDx = 0;
      },
      onScaleUpdate: (d) {
        if (d.pointerCount >= 2) {
          _setZoom(_zoomAtStart * d.scale);
        } else {
          _swipeDx += d.focalPointDelta.dx;
        }
      },
      onScaleEnd: (d) {
        if (d.pointerCount > 0 || _recording) return;
        final v = d.velocity.pixelsPerSecond.dx;
        if (_swipeDx.abs() > 50 || v.abs() > 500) {
          _setFilter(_filter + ((_swipeDx + v / 10) < 0 ? 1 : -1));
        }
      },
      child: ColorFiltered(
        colorFilter: ColorFilter.matrix(ColorEdits(preset: _filter).matrix),
        child: FittedBox(
          fit: BoxFit.cover,
          clipBehavior: Clip.hardEdge,
          child: SizedBox(
            width: 100,
            height: 100 * ratio,
            child: CameraPreview(c),
          ),
        ),
      ),
    );
  }

  Widget _round(Widget child, {Key? key, VoidCallback? onTap, String? tip}) {
    return Tooltip(
      message: tip ?? '',
      child: InkResponse(
        key: key,
        onTap: onTap,
        radius: 24,
        child: Container(
          width: 40,
          height: 40,
          decoration: const BoxDecoration(
            color: Colors.black38,
            shape: BoxShape.circle,
          ),
          alignment: Alignment.center,
          child: child,
        ),
      ),
    );
  }

  Widget _topBar() {
    final a = _audio;
    final flashIcon = _video
        ? (_torch ? Icons.flashlight_on : Icons.flashlight_off)
        : switch (_flash) {
            FlashMode.auto => Icons.flash_auto,
            FlashMode.always => Icons.flash_on,
            _ => Icons.flash_off,
          };
    return Row(
      children: [
        _round(
          const Icon(Icons.close, size: 24),
          key: const ValueKey('camera-close'),
          tip: 'Close',
          onTap: _close,
        ),
        Expanded(
          child: Center(
            child: Material(
              color: Colors.black45,
              shape: const StadiumBorder(),
              child: InkWell(
                key: const ValueKey('camera-add-audio'),
                customBorder: const StadiumBorder(),
                onTap: _recording ? null : _pickAudio,
                child: Padding(
                  padding: EdgeInsets.fromLTRB(
                    12,
                    8,
                    a == null || _recording ? 14 : 4,
                    8,
                  ),
                  child: Row(
                    mainAxisSize: MainAxisSize.min,
                    children: [
                      const Icon(Icons.music_note, size: 17),
                      const SizedBox(width: 6),
                      ConstrainedBox(
                        constraints: const BoxConstraints(maxWidth: 150),
                        child: Text(
                          a == null ? 'Add audio' : a.name,
                          maxLines: 1,
                          overflow: TextOverflow.ellipsis,
                          style: const TextStyle(
                            fontWeight: FontWeight.w700,
                            fontSize: 13,
                          ),
                        ),
                      ),
                      if (a != null && !_recording)
                        GestureDetector(
                          key: const ValueKey('camera-audio-remove'),
                          onTap: () => setState(() => _audio = null),
                          child: const Padding(
                            padding: EdgeInsets.symmetric(horizontal: 6),
                            child: Icon(Icons.close, size: 16),
                          ),
                        ),
                    ],
                  ),
                ),
              ),
            ),
          ),
        ),
        _round(
          Icon(flashIcon, size: 22),
          key: const ValueKey('camera-flash'),
          tip: 'Flash',
          onTap: _ctrl == null || _front ? null : _toggleFlash,
        ),
      ],
    );
  }

  Widget _tool({
    required Key key,
    required Widget icon,
    required String label,
    VoidCallback? onTap,
    bool on = false,
  }) {
    return Padding(
      padding: const EdgeInsets.only(bottom: 14),
      child: GestureDetector(
        key: key,
        behavior: HitTestBehavior.opaque,
        onTap: onTap,
        child: Opacity(
          opacity: onTap == null ? 0.45 : 1,
          child: Column(
            children: [
              Container(
                width: 40,
                height: 40,
                decoration: BoxDecoration(
                  color: on ? AppColors.lime : Colors.black38,
                  shape: BoxShape.circle,
                ),
                alignment: Alignment.center,
                child: IconTheme(
                  data: IconThemeData(
                    color: on ? Colors.black : Colors.white,
                    size: 22,
                  ),
                  child: DefaultTextStyle.merge(
                    style: TextStyle(
                      color: on ? Colors.black : Colors.white,
                      fontWeight: FontWeight.w800,
                      fontSize: 13,
                    ),
                    child: icon,
                  ),
                ),
              ),
              const SizedBox(height: 3),
              Text(
                label,
                style: const TextStyle(
                  fontSize: 10.5,
                  fontWeight: FontWeight.w600,
                  shadows: [Shadow(blurRadius: 6)],
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }

  Widget _tools() {
    final lengths = _lengths;
    return Column(
      children: [
        _tool(
          key: const ValueKey('camera-flip'),
          icon: const Icon(Icons.flip_camera_android),
          label: 'Flip',
          onTap: _cams.length < 2 ? null : _flip,
        ),
        if (_video)
          _tool(
            key: const ValueKey('camera-length'),
            icon: Text('$_maxSec'),
            label: 'Length',
            onTap: _recording
                ? null
                : () {
                    final i = lengths.indexOf(_maxSec);
                    setState(() => _maxSec = lengths[(i + 1) % lengths.length]);
                  },
          ),
        _tool(
          key: const ValueKey('camera-timer'),
          icon: _timer == 0
              ? const Icon(Icons.timer_outlined)
              : Text('${_timer}s'),
          label: 'Timer',
          on: _timer > 0,
          onTap: _recording
              ? null
              : () => setState(
                  () => _timer = switch (_timer) {
                    0 => 3,
                    3 => 10,
                    _ => 0,
                  },
                ),
        ),
        _tool(
          key: const ValueKey('camera-filters'),
          icon: const Icon(Icons.auto_awesome),
          label: 'Filters',
          on: _showFilters,
          onTap: _recording
              ? null
              : () => setState(() => _showFilters = !_showFilters),
        ),
      ],
    );
  }

  Widget _filterStrip() {
    return SizedBox(
      height: 84,
      child: ListView.builder(
        key: const ValueKey('camera-filter-strip'),
        scrollDirection: Axis.horizontal,
        padding: const EdgeInsets.symmetric(horizontal: 12),
        itemCount: kFilterPresets.length,
        itemBuilder: (_, i) {
          final on = i == _filter;
          return GestureDetector(
            key: ValueKey('camera-filter-$i'),
            onTap: () => _setFilter(i),
            child: Padding(
              padding: const EdgeInsets.symmetric(horizontal: 5),
              child: Column(
                children: [
                  Container(
                    width: 54,
                    height: 54,
                    padding: const EdgeInsets.all(2),
                    decoration: BoxDecoration(
                      shape: BoxShape.circle,
                      border: Border.all(
                        color: on ? AppColors.lime : Colors.white54,
                        width: on ? 2.5 : 1,
                      ),
                    ),
                    child: ClipOval(
                      child: ColorFiltered(
                        colorFilter: ColorFilter.matrix(
                          kFilterPresets[i].matrix,
                        ),
                        child: const DecoratedBox(
                          decoration: BoxDecoration(
                            gradient: LinearGradient(
                              begin: Alignment.topLeft,
                              end: Alignment.bottomRight,
                              colors: [
                                Color(0xFFF2A65A),
                                Color(0xFF5AA9E6),
                                Color(0xFF7FC8A9),
                              ],
                            ),
                          ),
                        ),
                      ),
                    ),
                  ),
                  const SizedBox(height: 4),
                  Text(
                    kFilterPresets[i].name,
                    style: TextStyle(
                      fontSize: 11,
                      fontWeight: on ? FontWeight.w800 : FontWeight.w500,
                      shadows: const [Shadow(blurRadius: 6)],
                    ),
                  ),
                ],
              ),
            ),
          );
        },
      ),
    );
  }

  Widget _bottomBar() {
    final canNext = _recording && _recordedMs >= 500;
    return Padding(
      padding: const EdgeInsets.fromLTRB(20, 14, 20, 6),
      child: Column(
        mainAxisSize: MainAxisSize.min,
        children: [
          SizedBox(
            height: 84,
            child: Row(
              children: [
                SizedBox(
                  width: 56,
                  child: _recording
                      ? _round(
                          const Icon(Icons.replay, size: 22),
                          key: const ValueKey('camera-retake'),
                          tip: 'Start over',
                          onTap: _busy && !_paused ? null : _retake,
                        )
                      : InkResponse(
                          key: const ValueKey('camera-gallery'),
                          onTap: _gallery,
                          child: Container(
                            width: 40,
                            height: 40,
                            decoration: BoxDecoration(
                              borderRadius: BorderRadius.circular(10),
                              border: Border.all(
                                color: Colors.white,
                                width: 1.5,
                              ),
                            ),
                            child: const Icon(
                              Icons.photo_library_outlined,
                              size: 20,
                            ),
                          ),
                        ),
                ),
                Expanded(child: Center(child: _shutter())),
                SizedBox(
                  width: 56,
                  child: _recording
                      ? AnimatedOpacity(
                          opacity: canNext ? 1 : 0.4,
                          duration: const Duration(milliseconds: 150),
                          child: InkResponse(
                            key: const ValueKey('camera-next'),
                            onTap: _next,
                            child: Container(
                              width: 44,
                              height: 44,
                              decoration: const BoxDecoration(
                                color: AppColors.lime,
                                shape: BoxShape.circle,
                              ),
                              child: const Icon(
                                Icons.check,
                                color: Colors.black,
                              ),
                            ),
                          ),
                        )
                      : null,
                ),
              ],
            ),
          ),
          const SizedBox(height: 6),
          if (_recording)
            Text(
              _paused
                  ? 'Paused · tap to film more'
                  : '${(_recordedMs / 1000).floor()}s / ${_maxSec}s',
              style: const TextStyle(
                fontSize: 12.5,
                color: AppColors.textSecondary,
              ),
            )
          else
            Row(
              mainAxisAlignment: MainAxisAlignment.center,
              children: [
                _modeButton('PHOTO', false),
                const SizedBox(width: 22),
                _modeButton('VIDEO', true),
              ],
            ),
        ],
      ),
    );
  }

  Widget _modeButton(String text, bool video) {
    final on = _video == video;
    return GestureDetector(
      key: ValueKey('camera-mode-${video ? 'video' : 'photo'}'),
      onTap: () => _setMode(video),
      child: Padding(
        padding: const EdgeInsets.symmetric(vertical: 6, horizontal: 4),
        child: Text(
          text,
          style: TextStyle(
            fontSize: 13,
            letterSpacing: 0.8,
            fontWeight: FontWeight.w800,
            color: on ? Colors.white : AppColors.textHint,
          ),
        ),
      ),
    );
  }

  Widget _shutter() {
    final live = _recording && !_paused;
    final Widget inner;
    if (!_video) {
      inner = const DecoratedBox(
        decoration: BoxDecoration(color: Colors.white, shape: BoxShape.circle),
        child: SizedBox(width: 62, height: 62),
      );
    } else {
      inner = AnimatedContainer(
        duration: const Duration(milliseconds: 160),
        width: live ? 30 : 62,
        height: live ? 30 : 62,
        decoration: BoxDecoration(
          color: const Color(0xFFFF3B3B),
          borderRadius: BorderRadius.circular(live ? 8 : 31),
        ),
      );
    }
    return GestureDetector(
      key: const ValueKey('camera-record'),
      onTap: _onShutterTap,
      onLongPressStart: (_) => _onHoldStart(),
      onLongPressEnd: (_) => _onHoldEnd(),
      onLongPressCancel: _onHoldEnd,
      child: Container(
        width: 80,
        height: 80,
        decoration: BoxDecoration(
          shape: BoxShape.circle,
          border: Border.all(color: Colors.white, width: 5),
        ),
        alignment: Alignment.center,
        child: inner,
      ),
    );
  }
}

/// Top bar: one piece per filmed part (Instagram style).
class _ProgressBar extends StatelessWidget {
  const _ProgressBar({
    super.key,
    required this.parts,
    required this.currentMs,
    required this.maxMs,
  });

  final List<int> parts;
  final int currentMs;
  final int maxMs;

  @override
  Widget build(BuildContext context) {
    return SizedBox(
      height: 4,
      child: CustomPaint(painter: _BarPainter([...parts, currentMs], maxMs)),
    );
  }
}

class _BarPainter extends CustomPainter {
  _BarPainter(this.parts, this.maxMs);
  final List<int> parts;
  final int maxMs;

  @override
  void paint(Canvas canvas, Size size) {
    final r = Radius.circular(size.height / 2);
    canvas.drawRRect(
      RRect.fromRectAndRadius(Offset.zero & size, r),
      Paint()..color = Colors.white30,
    );
    if (maxMs <= 0) return;
    var x = 0.0;
    final fill = Paint()..color = AppColors.lime;
    for (var i = 0; i < parts.length; i++) {
      final w = size.width * parts[i] / maxMs;
      if (w <= 0) continue;
      final right = (x + w).clamp(0.0, size.width).toDouble();
      canvas.drawRRect(RRect.fromLTRBR(x, 0, right, size.height, r), fill);
      x = right;
      // a small gap between parts
      if (i < parts.length - 1 && x < size.width) {
        canvas.drawRect(
          Rect.fromLTWH(x - 1.5, 0, 1.5, size.height),
          Paint()..color = Colors.black,
        );
      }
    }
  }

  @override
  bool shouldRepaint(_BarPainter old) =>
      old.maxMs != maxMs ||
      old.parts.length != parts.length ||
      old.parts.last != parts.last;
}
