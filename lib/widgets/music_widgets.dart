import 'package:flutter/material.dart';

import '../core/theme.dart';
import '../models/music.dart';
import '../models/post.dart';
import '../services/music_player.dart';

/// "♪ Track name" on the Clips screen (plain white text, readable on any video).
class MusicLabel extends StatelessWidget {
  const MusicLabel({super.key, required this.musicId});
  final String musicId;

  @override
  Widget build(BuildContext context) {
    final t = musicById(musicId);
    if (t == null) return const SizedBox.shrink();
    return Row(
      mainAxisSize: MainAxisSize.min,
      children: [
        const Icon(
          Icons.music_note_rounded,
          size: 16,
          color: Colors.white,
          shadows: [Shadow(blurRadius: 8, color: Colors.black54)],
        ),
        const SizedBox(width: 4),
        Flexible(
          child: Text(
            '${t.title}  \u00b7  InstantGram music',
            maxLines: 1,
            overflow: TextOverflow.ellipsis,
            style: const TextStyle(
              color: Colors.white,
              fontSize: 13,
              fontWeight: FontWeight.w700,
              shadows: [Shadow(blurRadius: 8, color: Colors.black54)],
            ),
          ),
        ),
      ],
    );
  }
}

/// On a photo post in Discover: tap to hear its music, tap again to stop.
class MusicToggleChip extends StatefulWidget {
  const MusicToggleChip({
    super.key,
    required this.post,
    this.interactive = true,
  });
  final Post post;

  /// false = only shows the track name (for clips that already play their music).
  final bool interactive;

  @override
  State<MusicToggleChip> createState() => _MusicToggleChipState();
}

class _MusicToggleChipState extends State<MusicToggleChip> {
  MusicPlayer? _player;
  bool _playing = false;
  bool _busy = false;

  MusicTrack? get _track => musicById(widget.post.musicId);

  Future<void> _toggle() async {
    final track = _track;
    if (track == null || _busy || !widget.interactive) return;
    if (_playing) {
      await _player?.pause();
      if (mounted) setState(() => _playing = false);
      return;
    }
    setState(() => _busy = true);
    var p = _player;
    if (p == null) {
      p = MusicPlayer(track);
      await p.init(volume: widget.post.musicVolume);
      if (!mounted) {
        await p.dispose();
        return;
      }
      _player = p;
    }
    await p.play();
    if (mounted) {
      setState(() {
        _playing = true;
        _busy = false;
      });
    }
  }

  @override
  void dispose() {
    _player?.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final t = _track;
    if (t == null) return const SizedBox.shrink();
    return GestureDetector(
      onTap: _toggle,
      child: Container(
        padding: const EdgeInsets.fromLTRB(10, 6, 12, 6),
        decoration: BoxDecoration(
          color: Colors.black54,
          borderRadius: BorderRadius.circular(18),
        ),
        child: Row(
          mainAxisSize: MainAxisSize.min,
          children: [
            Icon(
              _playing ? Icons.graphic_eq_rounded : Icons.music_note_rounded,
              size: 16,
              color: _playing ? AppTheme.volt : Colors.white,
            ),
            const SizedBox(width: 6),
            Text(
              t.title,
              style: const TextStyle(
                color: Colors.white,
                fontSize: 12.5,
                fontWeight: FontWeight.w700,
              ),
            ),
          ],
        ),
      ),
    );
  }
}

/// Bottom sheet with the app's music. Tap a track to hear it, then "Use".
/// Returns the chosen track (null when closed).
Future<MusicTrack?> pickMusic(BuildContext context, {String? currentId}) {
  return showModalBottomSheet<MusicTrack>(
    context: context,
    isScrollControlled: true,
    showDragHandle: true,
    builder: (_) => _MusicSheet(currentId: currentId),
  );
}

class _MusicSheet extends StatefulWidget {
  const _MusicSheet({this.currentId});
  final String? currentId;

  @override
  State<_MusicSheet> createState() => _MusicSheetState();
}

class _MusicSheetState extends State<_MusicSheet> {
  MusicPlayer? _player;
  String? _playingId;
  String? _loadingId;

  Future<void> _preview(MusicTrack t) async {
    final old = _player;
    _player = null;
    if (_playingId == t.id) {
      setState(() => _playingId = null);
      await old?.dispose();
      return;
    }
    setState(() {
      _playingId = null;
      _loadingId = t.id;
    });
    await old?.dispose();
    final p = MusicPlayer(t);
    await p.init();
    if (!mounted) {
      await p.dispose();
      return;
    }
    if (_loadingId != t.id) {
      await p.dispose(); // the user tapped another track meanwhile
      return;
    }
    _player = p;
    await p.play();
    if (mounted) {
      setState(() {
        _playingId = t.id;
        _loadingId = null;
      });
    }
  }

  @override
  void dispose() {
    _player?.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final h = MediaQuery.sizeOf(context).height;
    return ConstrainedBox(
      constraints: BoxConstraints(maxHeight: h * 0.75),
      child: Column(
        mainAxisSize: MainAxisSize.min,
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          const Padding(
            padding: EdgeInsets.fromLTRB(20, 0, 20, 4),
            child: Text(
              'Music',
              style: TextStyle(fontSize: 22, fontWeight: FontWeight.w900),
            ),
          ),
          Padding(
            padding: const EdgeInsets.fromLTRB(20, 0, 20, 8),
            child: Text(
              'Tracks made for InstantGram. Tap one to listen.',
              style: TextStyle(color: context.muted),
            ),
          ),
          Flexible(
            child: ListView.builder(
              shrinkWrap: true,
              padding: const EdgeInsets.fromLTRB(12, 0, 12, 20),
              itemCount: kMusicLibrary.length,
              itemBuilder: (context, i) {
                final t = kMusicLibrary[i];
                final playing = _playingId == t.id;
                final loading = _loadingId == t.id;
                final current = widget.currentId == t.id;
                return ListTile(
                  key: ValueKey(t.id),
                  onTap: () => _preview(t),
                  leading: Container(
                    width: 46,
                    height: 46,
                    decoration: BoxDecoration(
                      color: playing ? AppTheme.volt : context.cardHigh,
                      shape: BoxShape.circle,
                    ),
                    child: loading
                        ? const Padding(
                            padding: EdgeInsets.all(13),
                            child: CircularProgressIndicator(strokeWidth: 2.5),
                          )
                        : Icon(
                            playing
                                ? Icons.pause_rounded
                                : Icons.play_arrow_rounded,
                            color: playing ? AppTheme.ink : null,
                          ),
                  ),
                  title: Text(
                    t.title,
                    style: const TextStyle(fontWeight: FontWeight.w800),
                  ),
                  subtitle: Text('${t.mood}  \u00b7  ${t.bpm} BPM'),
                  trailing: FilledButton(
                    style: FilledButton.styleFrom(
                      minimumSize: const Size(72, 40),
                      padding: const EdgeInsets.symmetric(horizontal: 16),
                    ),
                    onPressed: () => Navigator.of(context).pop(t),
                    child: Text(current ? 'Selected' : 'Use'),
                  ),
                );
              },
            ),
          ),
        ],
      ),
    );
  }
}
