import 'dart:async';

import 'package:flutter/material.dart';

import '../core/errors.dart';
import '../core/media_url.dart';
import '../core/theme.dart';
import '../core/ui.dart';
import '../models/music.dart';
import '../models/post.dart';
import '../services/epidemic_service.dart';
import '../services/music_player.dart';

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

/// Bottom sheet with music: the app's own tracks and the Epidemic Sound catalogue.
/// Tap a track to hear it, then "Use". Returns the chosen track (null when closed).
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

  // Epidemic Sound tab
  int _tab = 0;
  final TextEditingController _term = TextEditingController();
  final ScrollController _scroll = ScrollController();
  Timer? _debounce;
  List<MusicTrack> _found = [];
  bool _searching = false;
  bool _more = false;
  bool _loadedOnce = false;
  String? _searchError;
  int _searchGen = 0;

  @override
  void initState() {
    super.initState();
    _tab = (widget.currentId ?? '').startsWith(kEpidemicPrefix) ? 1 : 0;
    _scroll.addListener(() {
      if (_scroll.position.extentAfter < 300) _loadMore();
    });
    if (_tab == 1) _search();
  }

  Future<void> _search({bool more = false}) async {
    final gen = ++_searchGen;
    setState(() {
      _searching = true;
      _searchError = null;
      if (!more) _found = [];
    });
    try {
      final page = await EpidemicService.instance.search(
        _term.text,
        offset: more ? _found.length : 0,
      );
      if (!mounted || gen != _searchGen) return;
      setState(() {
        _found = more ? [..._found, ...page.tracks] : page.tracks;
        _more = page.hasMore;
        _searching = false;
        _loadedOnce = true;
      });
    } catch (e) {
      if (!mounted || gen != _searchGen) return;
      setState(() {
        _searching = false;
        _loadedOnce = true;
        _searchError = friendlyError(e);
      });
    }
  }

  void _loadMore() {
    if (_tab != 1 || _searching || !_more || _searchError != null) return;
    _search(more: true);
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
    _debounce?.cancel();
    _term.dispose();
    _scroll.dispose();
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
          if (i == 1 && !_loadedOnce) _search();
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
      child: Row(children: [chip(0, 'InstantGram'), chip(1, 'Epidemic Sound')]),
    );
  }

  Widget _ownList() {
    return ListView.builder(
      shrinkWrap: true,
      padding: const EdgeInsets.fromLTRB(12, 0, 12, 20),
      itemCount: kMusicLibrary.length,
      itemBuilder: (context, i) {
        final t = kMusicLibrary[i];
        return _row(t, '${t.mood}  \u00b7  ${t.bpm} BPM');
      },
    );
  }

  Widget _epidemicList() {
    return Column(
      children: [
        Padding(
          padding: const EdgeInsets.fromLTRB(20, 0, 20, 8),
          child: TextField(
            key: const ValueKey('musicSearch'),
            controller: _term,
            textInputAction: TextInputAction.search,
            decoration: InputDecoration(
              hintText: 'Search songs, moods, artists',
              prefixIcon: const Icon(Icons.search_rounded),
              suffixIcon: _term.text.isEmpty
                  ? null
                  : IconButton(
                      icon: const Icon(Icons.close_rounded),
                      onPressed: () {
                        _term.clear();
                        _search();
                      },
                    ),
            ),
            onChanged: (_) {
              _debounce?.cancel();
              _debounce = Timer(const Duration(milliseconds: 450), _search);
              setState(() {});
            },
            onSubmitted: (_) => _search(),
          ),
        ),
        Expanded(
          child: _searchError != null
              ? Center(
                  child: Padding(
                    padding: const EdgeInsets.all(24),
                    child: Column(
                      mainAxisSize: MainAxisSize.min,
                      children: [
                        Text(_searchError!, textAlign: TextAlign.center),
                        const SizedBox(height: 12),
                        OutlinedButton(
                          onPressed: _search,
                          child: const Text('Try again'),
                        ),
                      ],
                    ),
                  ),
                )
              : _found.isEmpty
              ? Center(
                  child: _searching
                      ? const CircularProgressIndicator()
                      : Text(
                          'No tracks found',
                          style: TextStyle(color: context.muted),
                        ),
                )
              : ListView.builder(
                  controller: _scroll,
                  padding: const EdgeInsets.fromLTRB(12, 0, 12, 20),
                  itemCount: _found.length + (_searching ? 1 : 0),
                  itemBuilder: (context, i) {
                    if (i >= _found.length) {
                      return const Padding(
                        padding: EdgeInsets.all(16),
                        child: Center(child: CircularProgressIndicator()),
                      );
                    }
                    final t = _found[i];
                    final len = t.seconds > 0
                        ? '  \u00b7  ${formatDuration(t.seconds)}'
                        : '';
                    return _row(t, '${t.artist}$len');
                  },
                ),
        ),
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
                'Music',
                style: TextStyle(fontSize: 22, fontWeight: FontWeight.w900),
              ),
            ),
            _tabs(),
            Expanded(
              child: _tab == 0
                  ? Align(alignment: Alignment.topCenter, child: _ownList())
                  : _epidemicList(),
            ),
          ],
        ),
      ),
    );
  }
}
