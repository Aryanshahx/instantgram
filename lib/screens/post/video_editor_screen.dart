import 'dart:io';

import 'package:flutter/material.dart';
import 'package:video_player/video_player.dart';

import '../../core/theme.dart';

/// Trim, sound, speed and rotation of a clip. Times are whole seconds.
class VideoEdits {
  const VideoEdits({
    required this.start,
    required this.end,
    required this.total,
    this.mute = false,
    this.speed = 1,
    this.turns = 0,
    this.parts = const [],
  });

  final int start;
  final int end;

  /// Length of the whole clip, rounded up.
  final int total;
  final bool mute;

  /// 0.5 = slow motion, 2 = twice as fast (the picture only; songs keep their speed).
  final double speed;

  /// Quarter turns to the right (0-3).
  final int turns;

  /// After Split: the parts that are kept (seconds of the original video, in order).
  /// Empty = the whole range from [start] to [end].
  final List<(int, int)> parts;

  /// The kept parts (one part when nothing was split off).
  List<(int, int)> get kept => parts.isEmpty ? [(start, end)] : parts;

  /// Parts were removed from the middle.
  bool get split => kept.length > 1;

  bool get trimmed => start > 0 || end < total || split;
  bool get changesSpeed => speed != 1;
  bool get rotated => turns % 4 != 0;
  bool get isEmpty => !trimmed && !mute && !changesSpeed && !rotated;

  /// Seconds of the video that are kept.
  int get length => kept.fold(0, (a, p) => a + p.$2 - p.$1);

  /// Seconds the clip lasts once the speed is applied.
  int get playSeconds {
    final s = speed <= 0 ? 1.0 : speed;
    final v = (length / s).round();
    return v < 1 ? 1 : v;
  }
}

/// Pick the part of the clip to keep and switch the sound off. The preview plays only the
/// part that will be kept.
class VideoEditorScreen extends StatefulWidget {
  const VideoEditorScreen({
    super.key,
    required this.file,
    this.initial,
    this.maxSeconds,
    this.title = 'Edit clip',
  });

  final File file;
  final VideoEdits? initial;

  /// Longest part that may be kept (for example 30 s for a moment); null = no limit.
  final int? maxSeconds;
  final String title;

  @override
  State<VideoEditorScreen> createState() => _VideoEditorScreenState();
}

class _VideoEditorScreenState extends State<VideoEditorScreen> {
  VideoPlayerController? _c;
  Object? _error;
  int _total = 1;
  double _start = 0;
  double _end = 1;
  bool _mute = false;
  bool _paused = false;

  @override
  void initState() {
    super.initState();
    _load();
  }

  Future<void> _load() async {
    final c = VideoPlayerController.file(widget.file);
    try {
      await c.initialize();
      if (!mounted) {
        await c.dispose();
        return;
      }
      final total = (c.value.duration.inMilliseconds / 1000).ceil().clamp(
        1,
        1 << 20,
      );
      final init = widget.initial;
      setState(() {
        _c = c;
        _total = total;
        _start = (init?.start ?? 0).toDouble().clamp(0, total - 1);
        _end = (init?.end ?? total).toDouble().clamp(
          _start + 1,
          total.toDouble(),
        );
        final cap = widget.maxSeconds;
        if (cap != null && _end - _start > cap) _end = _start + cap;
        _mute = init?.mute ?? false;
      });
      await c.setLooping(false);
      await c.setVolume(_mute ? 0 : 1);
      c.addListener(_tick);
      await c.seekTo(Duration(seconds: _start.round()));
      await c.play();
    } catch (e) {
      await c.dispose();
      if (mounted) setState(() => _error = e);
    }
  }

  void _tick() {
    final c = _c;
    if (c == null || _paused) return;
    final v = c.value;
    final end = Duration(milliseconds: (_end * 1000).round());
    if (v.isInitialized &&
        (v.position >= end ||
            (v.position >= v.duration && v.duration > Duration.zero))) {
      c.seekTo(Duration(seconds: _start.round()));
      c.play();
    }
  }

  @override
  void dispose() {
    _c?.removeListener(_tick);
    _c?.dispose();
    super.dispose();
  }

  static String _t(double s) {
    final v = s.round();
    return '${v ~/ 60}:${(v % 60).toString().padLeft(2, '0')}';
  }

  void _togglePause() {
    final c = _c;
    if (c == null) return;
    setState(() => _paused = !_paused);
    if (_paused) {
      c.pause();
    } else {
      c.play();
    }
  }

  void _done() {
    Navigator.of(context).pop(
      VideoEdits(
        start: _start.round(),
        end: _end.round(),
        total: _total,
        mute: _mute,
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    final c = _c;
    return Theme(
      data: AppTheme.dark,
      child: Builder(
        builder: (context) => Scaffold(
          backgroundColor: Colors.black,
          appBar: AppBar(
            backgroundColor: Colors.black,
            leading: IconButton(
              key: const ValueKey('editorClose'),
              icon: const Icon(Icons.close_rounded),
              onPressed: () => Navigator.of(context).pop(),
            ),
            title: Text(widget.title),
            actions: [
              Padding(
                padding: const EdgeInsets.only(right: 8),
                child: TextButton(
                  key: const ValueKey('editorDone'),
                  onPressed: c == null ? null : _done,
                  child: const Text(
                    'Done',
                    style: TextStyle(fontSize: 17, fontWeight: FontWeight.w900),
                  ),
                ),
              ),
            ],
          ),
          body: _error != null
              ? const Center(
                  child: Padding(
                    padding: EdgeInsets.all(32),
                    child: Text(
                      'This clip cannot be edited here. You can still post it as it is.',
                      textAlign: TextAlign.center,
                    ),
                  ),
                )
              : c == null
              ? const Center(child: CircularProgressIndicator())
              : _editor(context, c),
        ),
      ),
    );
  }

  Widget _editor(BuildContext context, VideoPlayerController c) {
    final keep = (_end - _start).round();
    return Column(
      children: [
        Expanded(
          child: GestureDetector(
            behavior: HitTestBehavior.opaque,
            onTap: _togglePause,
            child: Padding(
              padding: const EdgeInsets.fromLTRB(12, 4, 12, 12),
              child: Center(
                child: AspectRatio(
                  aspectRatio: c.value.aspectRatio,
                  child: Stack(
                    fit: StackFit.expand,
                    children: [
                      VideoPlayer(c),
                      if (_paused)
                        const Center(
                          child: Icon(
                            Icons.play_arrow_rounded,
                            size: 72,
                            color: Colors.white,
                            shadows: [
                              Shadow(blurRadius: 14, color: Colors.black54),
                            ],
                          ),
                        ),
                    ],
                  ),
                ),
              ),
            ),
          ),
        ),
        SafeArea(
          top: false,
          child: Padding(
            padding: const EdgeInsets.fromLTRB(20, 0, 20, 12),
            child: Column(
              mainAxisSize: MainAxisSize.min,
              children: [
                Row(
                  children: [
                    const Icon(Icons.content_cut_rounded, size: 18),
                    const SizedBox(width: 8),
                    const Text(
                      'Trim',
                      style: TextStyle(fontWeight: FontWeight.w900),
                    ),
                    const Spacer(),
                    Text(
                      '${_t(_start)} - ${_t(_end)}  \u00b7  $keep s',
                      style: const TextStyle(
                        color: Colors.white70,
                        fontWeight: FontWeight.w700,
                      ),
                    ),
                  ],
                ),
                RangeSlider(
                  values: RangeValues(_start, _end),
                  min: 0,
                  max: _total.toDouble(),
                  divisions: _total > 1 ? _total : null,
                  activeColor: AppTheme.volt,
                  onChanged: _total <= 1
                      ? null
                      : (v) {
                          var s = v.start.roundToDouble();
                          var e = v.end.roundToDouble();
                          if (e - s < 1) {
                            if (s != _start) {
                              s = e - 1;
                            } else {
                              e = s + 1;
                            }
                          }
                          s = s.clamp(0, _total - 1);
                          e = e.clamp(s + 1, _total.toDouble());
                          final cap = widget.maxSeconds;
                          if (cap != null && e - s > cap) {
                            // keep the length within the limit: the other handle follows
                            if (s != _start) {
                              e = s + cap;
                            } else {
                              s = e - cap;
                            }
                          }
                          final movedStart = s != _start;
                          setState(() {
                            _start = s;
                            _end = e;
                          });
                          c.seekTo(
                            Duration(
                              seconds: movedStart
                                  ? s.round()
                                  : (e - 1).round().clamp(0, _total),
                            ),
                          );
                        },
                ),
                const SizedBox(height: 4),
                Row(
                  children: [
                    GestureDetector(
                      key: const ValueKey('muteToggle'),
                      behavior: HitTestBehavior.opaque,
                      onTap: () {
                        setState(() => _mute = !_mute);
                        c.setVolume(_mute ? 0 : 1);
                      },
                      child: Container(
                        width: 44,
                        height: 44,
                        decoration: BoxDecoration(
                          color: _mute ? AppTheme.volt : Colors.white12,
                          shape: BoxShape.circle,
                        ),
                        child: Icon(
                          _mute
                              ? Icons.volume_off_rounded
                              : Icons.volume_up_rounded,
                          color: _mute ? AppTheme.ink : Colors.white,
                        ),
                      ),
                    ),
                    const SizedBox(width: 12),
                    Text(
                      _mute ? 'Sound removed' : 'Original sound',
                      style: const TextStyle(fontWeight: FontWeight.w800),
                    ),
                    const Spacer(),
                    TextButton.icon(
                      key: const ValueKey('editorPlayPause'),
                      onPressed: _togglePause,
                      icon: Icon(
                        _paused
                            ? Icons.play_arrow_rounded
                            : Icons.pause_rounded,
                      ),
                      label: Text(_paused ? 'Play' : 'Pause'),
                    ),
                  ],
                ),
                const SizedBox(height: 6),
                Text(
                  widget.maxSeconds != null
                      ? 'Up to ${widget.maxSeconds} seconds. Trimming or removing the sound saves the clip again (up to 1080p).'
                      : 'Trimming or removing the sound saves the clip again (up to 1080p).',
                  style: const TextStyle(color: Colors.white54, fontSize: 12.5),
                ),
              ],
            ),
          ),
        ),
      ],
    );
  }
}
