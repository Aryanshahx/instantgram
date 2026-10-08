import 'dart:async';

import 'package:flutter/material.dart';

import '../core/errors.dart';
import '../core/media_url.dart';
import '../core/theme.dart';
import '../core/ui.dart';
import '../models/music.dart';
import '../models/post.dart';
import '../services/device_audio.dart';
import '../services/itunes_service.dart';
import '../services/music_player.dart';
import 'state_views.dart';

/// "♪ Track name": shown right under the username on posts and on clips.
/// [onDark] = white text with a soft shadow (on top of a video); otherwise the muted theme colour.
class MusicLabel extends StatelessWidget {
  const MusicLabel({super.key, required this.musicId, this.onDark = true});
  final String musicId;
  final bool onDark;

  @override
  Widget build(BuildContext context) {
    final t = musicById(musicId);
    if (t == null) return const SizedBox.shrink();
    final color = onDark ? Colors.white : context.muted;
    final shadows = onDark
        ? const [Shadow(blurRadius: 8, color: Colors.black54)]
        : null;
    return Row(
      mainAxisSize: MainAxisSize.min,
      children: [
        Icon(
          Icons.music_note_rounded,
          size: 14,
          color: color,
          shadows: shadows,
        ),
        const SizedBox(width: 3),
        Flexible(
          child: Text(
            t.label,
            maxLines: 1,
            overflow: TextOverflow.ellipsis,
            style: TextStyle(
              color: color,
              fontSize: 12.5,
              fontWeight: FontWeight.w600,
              shadows: shadows,
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
    this.showName = true,
  });
  final Post post;

  /// false = only the round music button (the name is shown under the username).
  final bool showName;

  /// false = only shows the track name (for clips that already play their music).
  final bool interactive;

  @override
  State<MusicToggleChip> createState() => _MusicToggleChipState();
}

class _MusicToggleChipState extends State<MusicToggleChip> {
  MusicPlayer? _player;
  bool _playing = false;
  bool _busy = false;

  MusicTrack? get _track => widget.post.playableMusic;

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
        padding: widget.showName
            ? const EdgeInsets.fromLTRB(10, 6, 12, 6)
            : const EdgeInsets.all(9),
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
            if (widget.showName) ...[
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
          ],
        ),
      ),
    );
  }
}

/// Bottom sheet with audio: a file from the phone, the InstantGram picks, hit songs and
/// free music.
/// Tap a track to hear it, then "Use". Returns the chosen track (null when closed).
/// [current] is the track that is chosen now; a song from the phone that was picked before
/// is shown again in the first tab.
/// What the "My phone" tab says under the title (v1.19.3: your own audio, spelled out).
const String kPhoneNote =
    'Pick an audio file (mp3, m4a, wav...) from your phone. The first minute is used. On a clip it replaces the sound of your video. Any song you own is fine.';

/// What the "InstantGram audio" tab says under its rows.
const String kInstantNote =
    'Picked rows, refreshed from Apple. Real songs, 30 second previews. You can also use your own audio: open "My phone" and choose a file.';

Future<MusicTrack?> pickMusic(
  BuildContext context, {
  String? currentId,
  MusicTrack? current,
}) {
  return showModalBottomSheet<MusicTrack>(
    context: context,
    isScrollControlled: true,
    showDragHandle: true,
    builder: (_) => _MusicSheet(
      currentId: currentId ?? current?.id,
      mine: (current?.isLocal ?? false) ? current : null,
    ),
  );
}

class _MusicSheet extends StatefulWidget {
  const _MusicSheet({this.currentId, this.mine});
  final String? currentId;
  final MusicTrack? mine;

  @override
  State<_MusicSheet> createState() => _MusicSheetState();
}

class _MusicSheetState extends State<_MusicSheet> {
  MusicPlayer? _player;
  String? _playingId;
  String? _loadingId;

  // tabs: 0 = my phone (your own audio), 1 = InstantGram audio (picked rows)
  int _tab = 0;
  MusicTrack? _mine;
  bool _importing = false;
  List<StationTracks> _stations = [];
  bool _curLoading = false;
  Object? _curError;

  @override
  void initState() {
    super.initState();
    _mine = widget.mine;
    // An older post can carry a song from the tabs that are gone (it: or ov:). It keeps
    // playing; it is just not offered for new posts any more.
    _tab = 0;
  }

  /// Fills the InstantGram audio tab (kept for 30 minutes inside the service).
  Future<void> _loadCurated({bool force = false}) async {
    setState(() {
      _curLoading = true;
      _curError = null;
    });
    try {
      final list = await ItunesService.instance.curated(force: force);
      if (!mounted) return;
      setState(() {
        _stations = list;
        _curLoading = false;
      });
    } catch (e) {
      if (!mounted) return;
      setState(() {
        _curLoading = false;
        _curError = e;
      });
    }
  }

  /// Opens the phone's file picker; the file is turned into a small AAC file right here.
  Future<void> _fromPhone() async {
    if (_importing) return;
    final old = _player;
    _player = null;
    setState(() {
      _importing = true;
      _playingId = null;
      _loadingId = null;
    });
    await old?.dispose();
    try {
      final t = await DeviceAudio.pick();
      if (!mounted) return;
      setState(() {
        _importing = false;
        if (t != null) _mine = t;
      });
    } catch (e) {
      if (!mounted) return;
      setState(() => _importing = false);
      showToast(context, friendlyError(e));
    }
  }

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
    if (!p.ready) {
      await p.dispose();
      if (!mounted) return;
      setState(() => _loadingId = null);
      showToast(context, 'Could not play this track. Check your connection.');
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

  Widget _row(MusicTrack t, String subtitle) {
    final playing = _playingId == t.id;
    final loading = _loadingId == t.id;
    final current = widget.currentId == t.id;
    return ListTile(
      key: ValueKey(t.id),
      onTap: () => _preview(t),
      leading: Container(
        width: 46,
        height: 46,
        clipBehavior: Clip.antiAlias,
        decoration: BoxDecoration(
          color: playing ? AppTheme.volt : context.cardHigh,
          shape: BoxShape.circle,
        ),
        child: loading
            ? const Padding(
                padding: EdgeInsets.all(13),
                child: CircularProgressIndicator(strokeWidth: 2.5),
              )
            : Stack(
                fit: StackFit.expand,
                children: [
                  if (t.cover.isNotEmpty && !playing)
                    Image.network(
                      t.cover,
                      fit: BoxFit.cover,
                      errorBuilder: (_, _, _) => const SizedBox.shrink(),
                    ),
                  Icon(
                    playing ? Icons.pause_rounded : Icons.play_arrow_rounded,
                    color: playing
                        ? AppTheme.ink
                        : (t.cover.isNotEmpty ? Colors.white : null),
                    shadows: t.cover.isNotEmpty && !playing
                        ? const [Shadow(blurRadius: 6, color: Colors.black87)]
                        : null,
                  ),
                ],
              ),
      ),
      title: Text(
        t.title,
        maxLines: 1,
        overflow: TextOverflow.ellipsis,
        style: const TextStyle(fontWeight: FontWeight.w800),
      ),
      subtitle: Text(subtitle, maxLines: 1, overflow: TextOverflow.ellipsis),
      trailing: FilledButton(
        key: ValueKey('use_${t.id}'),
        style: FilledButton.styleFrom(
          minimumSize: const Size(72, 40),
          padding: const EdgeInsets.symmetric(horizontal: 16),
        ),
        onPressed: () => Navigator.of(context).pop(t),
        child: Text(current ? 'Selected' : 'Use'),
      ),
    );
  }

  Widget _tabs() {
    Widget chip(int i, String label) => Expanded(
      child: GestureDetector(
        key: ValueKey('musicTab$i'),
        onTap: () {
          if (_tab == i) return;
          setState(() => _tab = i);
          if (i == 1 && _stations.isEmpty && !_curLoading) _loadCurated();
        },
        child: Container(
          height: 38,
          alignment: Alignment.center,
          decoration: BoxDecoration(
            color: _tab == i ? AppTheme.volt : Colors.transparent,
            borderRadius: BorderRadius.circular(19),
          ),
          child: Text(
            label,
            style: TextStyle(
              fontWeight: FontWeight.w800,
              color: _tab == i ? AppTheme.ink : null,
            ),
          ),
        ),
      ),
    );
    return Container(
      margin: const EdgeInsets.fromLTRB(20, 0, 20, 10),
      padding: const EdgeInsets.all(3),
      decoration: BoxDecoration(
        color: context.cardHigh,
        borderRadius: BorderRadius.circular(22),
      ),
      child: Row(
        children: [
          chip(0, 'My phone'),
          chip(1, 'InstantGram audio'),
        ],
      ),
    );
  }

  Widget _phoneTab() {
    final mine = _mine;
    return ListView(
      padding: const EdgeInsets.fromLTRB(20, 4, 20, 24),
      children: [
        Container(
          padding: const EdgeInsets.all(18),
          decoration: BoxDecoration(
            color: context.cardHigh,
            borderRadius: BorderRadius.circular(20),
          ),
          child: Column(
            children: [
              const Icon(Icons.library_music_rounded, size: 40),
              const SizedBox(height: 10),
              const Text(
                'Use a sound from your phone',
                textAlign: TextAlign.center,
                style: TextStyle(fontSize: 16, fontWeight: FontWeight.w800),
              ),
              const SizedBox(height: 6),
              Text(
                kPhoneNote,
                key: const ValueKey('phoneNote'),
                textAlign: TextAlign.center,
                style: TextStyle(color: context.muted, fontSize: 12.5),
              ),
              const SizedBox(height: 14),
              FilledButton.icon(
                key: const ValueKey('pickDeviceAudio'),
                onPressed: _importing ? null : _fromPhone,
                icon: _importing
                    ? const SizedBox(
                        width: 18,
                        height: 18,
                        child: CircularProgressIndicator(strokeWidth: 2.5),
                      )
                    : const Icon(Icons.folder_open_rounded),
                label: Text(
                  _importing
                      ? 'Getting your audio ready...'
                      : (mine == null ? 'Choose audio' : 'Choose another'),
                ),
              ),
            ],
          ),
        ),
        if (mine != null) ...[
          const SizedBox(height: 12),
          _row(
            mine,
            'From your phone${mine.seconds > 0 ? '  \u00b7  ${formatDuration(mine.seconds)}' : ''}',
          ),
        ],
      ],
    );
  }

  /// The InstantGram audio tab: rows of picked songs, no typing needed.
  Widget _instantTab() {
    if (_curLoading) {
      return const CenteredLoader(key: ValueKey('instantLoading'));
    }
    if (_curError != null) {
      return ErrorState(
        error: _curError!,
        onRetry: () => _loadCurated(force: true),
      );
    }
    if (_stations.isEmpty) {
      return EmptyState(
        icon: Icons.music_off_rounded,
        title: 'No songs right now',
        subtitle: 'Check your connection and try again.',
        action: FilledButton(
          onPressed: () => _loadCurated(force: true),
          child: const Text('Try again'),
        ),
      );
    }
    return ListView(
      key: const ValueKey('instantList'),
      padding: const EdgeInsets.fromLTRB(12, 0, 12, 20),
      children: [
        Padding(
          padding: const EdgeInsets.fromLTRB(8, 4, 8, 6),
          child: Row(
            children: [
              Expanded(
                child: Text(
                  kInstantNote,
                  key: const ValueKey('instantNote'),
                  style: TextStyle(color: context.muted, fontSize: 12),
                ),
              ),
              TextButton(
                key: const ValueKey('instantRefresh'),
                onPressed: () => _loadCurated(force: true),
                child: const Text('Refresh'),
              ),
            ],
          ),
        ),
        for (final st in _stations) ...[
          Padding(
            padding: const EdgeInsets.fromLTRB(8, 14, 8, 2),
            child: Text(
              st.station.name,
              style: const TextStyle(fontSize: 15, fontWeight: FontWeight.w900),
            ),
          ),
          for (final t in st.tracks)
            _row(
              t,
              '${t.artist}${t.seconds > 0 ? '  \u00b7  ${formatDuration(t.seconds)}' : ''}',
            ),
        ],
      ],
    );
  }

  @override
  Widget build(BuildContext context) {
    final h = MediaQuery.sizeOf(context).height;
    final kb = MediaQuery.viewInsetsOf(context).bottom;
    return Padding(
      padding: EdgeInsets.only(bottom: kb),
      child: SizedBox(
        height: h * 0.75,
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            const Padding(
              padding: EdgeInsets.fromLTRB(20, 0, 20, 8),
              child: Text(
                'Audio',
                style: TextStyle(fontSize: 22, fontWeight: FontWeight.w900),
              ),
            ),
            _tabs(),
            Expanded(
              child: _tab == 0 ? _phoneTab() : _instantTab(),
            ),
          ],
        ),
      ),
    );
  }
}
