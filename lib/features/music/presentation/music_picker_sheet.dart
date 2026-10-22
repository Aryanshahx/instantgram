import 'package:flutter/material.dart';

import 'dart:async';

import '../../../core/services/api_client.dart';
import '../../../core/services/chat_prefs.dart';
import '../../../core/services/media_service.dart';
import '../../../core/services/music_player.dart';
import '../../../core/theme/app_colors.dart';
import '../../../core/utils/time_ago.dart';
import '../../../shared/models/music.dart';
import '../../../shared/widgets/net_image.dart';
import '../data/music_repository.dart';
import '../../../shared/widgets/skeleton.dart';

const String _kPreview = 'music-picker';

/// Stops a song preview of this sheet (each song plays as its own owner).
void _stopPreview() {
  final o = MusicPlayer.instance.owner.value;
  if (o != null && o.startsWith(_kPreview)) MusicPlayer.instance.stop(o);
}

void _snack(BuildContext context, String text) {
  ScaffoldMessenger.maybeOf(context)
    ?..hideCurrentSnackBar()
    ..showSnackBar(SnackBar(content: Text(text)));
}

/// Music update: choose a song for a post / clip / moment.
/// Like Instagram: search songs + audios, Trending (Epidemic Sound songs),
/// Original (audios people made, most used first), Saved, Phone (a music
/// file) and AI song ("Coming soon" until [MusicPickerSheet.aiSongsReady]
/// is true). null = nothing chosen.
Future<PickedAudio?> showMusicPicker(BuildContext context) async {
  final picked = await showModalBottomSheet<PickedAudio>(
    context: context,
    isScrollControlled: true,
    useSafeArea: true,
    backgroundColor: AppColors.background,
    shape: const RoundedRectangleBorder(
      borderRadius: BorderRadius.vertical(top: Radius.circular(18)),
    ),
    builder: (_) => const MusicPickerSheet(),
  );
  _stopPreview();
  return picked;
}

class MusicPickerSheet extends StatefulWidget {
  const MusicPickerSheet({super.key});

  /// AI songs are switched off for now: the tab shows "Coming soon".
  /// Set to true to turn them on again (the server part is ready).
  static bool aiSongsReady = false;

  @override
  State<MusicPickerSheet> createState() => _MusicPickerSheetState();
}

class _MusicPickerSheetState extends State<MusicPickerSheet> {
  final _searchCtrl = TextEditingController();
  String _query = '';

  /// Epidemic song being saved for us (shows "Getting song…").
  String? _getting;

  @override
  void dispose() {
    _stopPreview();
    _searchCtrl.dispose();
    super.dispose();
  }

  Future<void> _use(MusicTrack t) async {
    if (_getting != null) return;
    _stopPreview();
    var track = t;
    if (t.isEpidemic && t.url.isEmpty) {
      // first time anyone uses this song: the server keeps a copy
      setState(() => _getting = t.id);
      try {
        track = await MusicRepository.instance.esUse(t);
      } catch (e) {
        if (!mounted) return;
        setState(() => _getting = null);
        _snack(
          context,
          e is ApiException ? e.message : "Couldn't get this song. Try again.",
        );
        return;
      }
      if (!mounted) return;
    }
    Navigator.of(context).pop(
      PickedAudio.online(
        url: track.url,
        name: track.label,
        musicId: track.id,
        startMs: track.startMs,
        durationMs: track.durationMs,
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    final h = MediaQuery.sizeOf(context).height;
    return SizedBox(
      height: h * 0.86,
      child: Stack(
        children: [
          Positioned.fill(child: _body()),
          if (_getting != null)
            Positioned.fill(
              child: ColoredBox(
                key: const ValueKey('es-getting'),
                color: Colors.black54,
                child: Center(
                  child: Container(
                    padding: const EdgeInsets.symmetric(
                      horizontal: 20,
                      vertical: 14,
                    ),
                    decoration: BoxDecoration(
                      color: AppColors.surfaceHigh,
                      borderRadius: BorderRadius.circular(14),
                    ),
                    child: const Row(
                      mainAxisSize: MainAxisSize.min,
                      children: [
                        SizedBox(
                          width: 18,
                          height: 18,
                          child: CircularProgressIndicator(
                            strokeWidth: 2,
                            color: AppColors.lime,
                          ),
                        ),
                        SizedBox(width: 12),
                        Text('Getting song…'),
                      ],
                    ),
                  ),
                ),
              ),
            ),
        ],
      ),
    );
  }

  Widget _body() => DefaultTabController(
    length: 5,
    child: Column(
      children: [
        // the sheet already shows one drag bar (theme), no second one here
        Padding(
          padding: const EdgeInsets.fromLTRB(14, 0, 14, 2),
          child: TextField(
            key: const ValueKey('audio-search'),
            controller: _searchCtrl,
            textInputAction: TextInputAction.search,
            onChanged: (v) => setState(() => _query = v.trim()),
            decoration: InputDecoration(
              isDense: true,
              hintText: 'Search songs and audio',
              prefixIcon: const Icon(Icons.search, size: 20),
              suffixIcon: _query.isEmpty
                  ? null
                  : IconButton(
                      key: const ValueKey('audio-search-clear'),
                      icon: const Icon(Icons.close, size: 18),
                      onPressed: () {
                        _searchCtrl.clear();
                        setState(() => _query = '');
                      },
                    ),
              filled: true,
              fillColor: AppColors.surfaceHigh,
              border: OutlineInputBorder(
                borderRadius: BorderRadius.circular(12),
                borderSide: BorderSide.none,
              ),
            ),
          ),
        ),
        if (_query.isNotEmpty)
          Expanded(
            child: _SearchResults(query: _query, onUse: _use),
          )
        else ...[
          const TabBar(
            key: ValueKey('music-tabs'),
            indicatorColor: AppColors.lime,
            labelColor: AppColors.textPrimary,
            unselectedLabelColor: AppColors.textSecondary,
            dividerColor: AppColors.border,
            labelPadding: EdgeInsets.zero,
            labelStyle: TextStyle(fontWeight: FontWeight.w700, fontSize: 13),
            tabs: [
              Tab(key: ValueKey('music-tab-trending'), text: 'Trending'),
              Tab(key: ValueKey('music-tab-original'), text: 'Original'),
              Tab(key: ValueKey('music-tab-saved'), text: 'Saved'),
              Tab(key: ValueKey('music-tab-phone'), text: 'Phone'),
              Tab(key: ValueKey('music-tab-ai'), text: 'AI song'),
            ],
          ),
          Expanded(
            child: TabBarView(
              children: [
                _EsTab(onUse: _use),
                _OriginalTab(onUse: _use),
                _SavedTab(onUse: _use),
                const _PhoneTab(),
                if (MusicPickerSheet.aiSongsReady)
                  _AiTab(onUse: _use)
                else
                  const _AiSoon(),
              ],
            ),
          ),
        ],
      ],
    ),
  );
}

// ------------------------------------------------------------------ rows

/// Plays / stops the preview of [t] (Epidemic songs: a short-lived link).
Future<void> togglePreview(BuildContext context, MusicTrack t) async {
  final mp = MusicPlayer.instance;
  final owner = '$_kPreview-${t.id}';
  if (mp.isOwner(owner)) {
    await mp.stop(owner);
    return;
  }
  if (t.isEpidemic && t.url.isEmpty) {
    try {
      final u = await MusicRepository.instance.esPreview(t.esId);
      await mp.play(owner, u, hls: true);
    } catch (_) {
      if (context.mounted) _snack(context, "Couldn't play this song");
    }
    return;
  }
  await mp.play(owner, t.url);
}

/// One audio: cover / play button, name, artist, uses, save, Use.
/// Tap the row = play / stop the preview.
class TrackRow extends StatelessWidget {
  const TrackRow({super.key, required this.track, required this.onUse});

  final MusicTrack track;
  final VoidCallback onUse;

  @override
  Widget build(BuildContext context) {
    final t = track;
    final owner = '$_kPreview-${t.id}';
    final info = [
      if (t.artist.isNotEmpty) t.artist,
      if (trackTime(t.durationMs).isNotEmpty) trackTime(t.durationMs),
      if (t.uses > 0) audioUses(t.uses, compactCount),
    ].join(' · ');
    void toggle() => togglePreview(context, t);
    return InkWell(
      key: ValueKey('track-${t.id}'),
      onTap: toggle,
      child: Padding(
        padding: const EdgeInsets.fromLTRB(14, 7, 8, 7),
        child: Row(
          children: [
            ValueListenableBuilder<String?>(
              valueListenable: MusicPlayer.instance.owner,
              builder: (_, now, _) {
                final on = now == owner;
                final icon = Icon(
                  on ? Icons.pause : Icons.play_arrow,
                  color: on && t.cover.isEmpty
                      ? Colors.black
                      : AppColors.textPrimary,
                );
                return GestureDetector(
                  key: ValueKey('track-play-${t.id}'),
                  onTap: toggle,
                  child: Container(
                    width: 42,
                    height: 42,
                    clipBehavior: Clip.antiAlias,
                    decoration: BoxDecoration(
                      color: on && t.cover.isEmpty
                          ? AppColors.lime
                          : AppColors.surfaceHigh,
                      borderRadius: BorderRadius.circular(10),
                      border: on && t.cover.isNotEmpty
                          ? Border.all(color: AppColors.lime, width: 2)
                          : null,
                    ),
                    child: t.cover.isEmpty
                        ? icon
                        : Stack(
                            fit: StackFit.expand,
                            children: [
                              NetImage(t.cover),
                              const ColoredBox(color: Colors.black38),
                              icon,
                            ],
                          ),
                  ),
                );
              },
            ),
            const SizedBox(width: 12),
            Expanded(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Row(
                    children: [
                      Flexible(
                        child: Text(
                          t.title,
                          maxLines: 1,
                          overflow: TextOverflow.ellipsis,
                          style: const TextStyle(
                            fontWeight: FontWeight.w700,
                            fontSize: 14.5,
                          ),
                        ),
                      ),
                      if (t.isAi) ...[
                        const SizedBox(width: 6),
                        const _Tag('AI'),
                      ],
                      if (t.explicit) ...[
                        const SizedBox(width: 6),
                        const _Tag('E'),
                      ],
                    ],
                  ),
                  if (info.isNotEmpty)
                    Text(
                      info,
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                      style: const TextStyle(
                        fontSize: 12,
                        color: AppColors.textSecondary,
                      ),
                    ),
                ],
              ),
            ),
            SaveAudioButton(musicId: t.id),
            TextButton(
              key: ValueKey('track-use-${t.id}'),
              onPressed: onUse,
              style: TextButton.styleFrom(foregroundColor: AppColors.lime),
              child: const Text(
                'Use',
                style: TextStyle(fontWeight: FontWeight.w800),
              ),
            ),
          ],
        ),
      ),
    );
  }
}

/// Bookmark: save / unsave an audio (only you see your saved audios).
class SaveAudioButton extends StatelessWidget {
  const SaveAudioButton({super.key, required this.musicId, this.size = 22});

  final String musicId;
  final double size;

  @override
  Widget build(BuildContext context) {
    return ValueListenableBuilder<ChatPrefsData>(
      valueListenable: ChatPrefs.instance.value,
      builder: (context, prefs, _) {
        final on = prefs.isAudioSaved(musicId);
        return IconButton(
          key: ValueKey('track-save-$musicId'),
          tooltip: on ? 'Saved' : 'Save audio',
          visualDensity: VisualDensity.compact,
          icon: Icon(
            on ? Icons.bookmark : Icons.bookmark_border,
            size: size,
            color: on ? AppColors.lime : AppColors.textSecondary,
          ),
          onPressed: () async {
            final ok = await ChatPrefs.instance.toggleSavedAudio(musicId);
            if (!ok && context.mounted) {
              ScaffoldMessenger.of(context)
                ..hideCurrentSnackBar()
                ..showSnackBar(
                  const SnackBar(
                    content: Text('You saved 500 audios. Remove some first.'),
                  ),
                );
            }
          },
        );
      },
    );
  }
}

class _Tag extends StatelessWidget {
  const _Tag(this.text);
  final String text;

  @override
  Widget build(BuildContext context) => Container(
    padding: const EdgeInsets.symmetric(horizontal: 5, vertical: 1),
    decoration: BoxDecoration(
      border: Border.all(color: AppColors.lime),
      borderRadius: BorderRadius.circular(5),
    ),
    child: Text(
      text,
      style: const TextStyle(
        fontSize: 9.5,
        fontWeight: FontWeight.w800,
        color: AppColors.lime,
      ),
    ),
  );
}

class _Empty extends StatelessWidget {
  const _Empty(this.icon, this.title, this.subtitle);
  final IconData icon;
  final String title;
  final String subtitle;

  @override
  Widget build(BuildContext context) => Padding(
    padding: const EdgeInsets.fromLTRB(24, 40, 24, 24),
    child: Column(
      children: [
        Icon(icon, size: 40, color: AppColors.textHint),
        const SizedBox(height: 10),
        Text(title, style: const TextStyle(fontWeight: FontWeight.w700)),
        const SizedBox(height: 4),
        Text(
          subtitle,
          textAlign: TextAlign.center,
          style: const TextStyle(color: AppColors.textSecondary, fontSize: 13),
        ),
      ],
    ),
  );
}

// ---------------------------------------------------------- audio lists

/// A list of audios with loading / error / empty states.
class _AudioList extends StatelessWidget {
  const _AudioList({
    required this.listKey,
    required this.tracks,
    required this.failed,
    required this.onUse,
    required this.onRetry,
    required this.empty,
    this.onRefresh,
  });

  final String listKey;
  final List<MusicTrack>? tracks;
  final bool failed;
  final ValueChanged<MusicTrack> onUse;
  final VoidCallback onRetry;
  final Widget empty;
  final Future<void> Function()? onRefresh;

  @override
  Widget build(BuildContext context) {
    final l = tracks;
    if (l == null) {
      return Align(
        alignment: failed ? Alignment.center : Alignment.topCenter,
        child: failed
            ? TextButton(
                key: ValueKey('$listKey-retry'),
                onPressed: onRetry,
                child: const Text("Couldn't load. Tap to try again"),
              )
            : const Skeleton(kind: SkeletonKind.tracks),
      );
    }
    final list = ListView.builder(
      key: ValueKey(listKey),
      physics: const AlwaysScrollableScrollPhysics(),
      padding: const EdgeInsets.only(top: 4, bottom: 24),
      itemCount: l.isEmpty ? 1 : l.length,
      itemBuilder: (_, i) =>
          l.isEmpty ? empty : TrackRow(track: l[i], onUse: () => onUse(l[i])),
    );
    final r = onRefresh;
    return r == null
        ? list
        : RefreshIndicator(color: AppColors.lime, onRefresh: r, child: list);
  }
}

/// Trending: popular Epidemic Sound songs + their playlists
/// ("Trending on TikTok", moods, ...). Tap a chip to see a playlist.
class _EsTab extends StatefulWidget {
  const _EsTab({required this.onUse});
  final ValueChanged<MusicTrack> onUse;

  @override
  State<_EsTab> createState() => _EsTabState();
}

class _EsTabState extends State<_EsTab> with AutomaticKeepAliveClientMixin {
  EsHome? _home;
  bool _failed = false;

  /// The server has no Epidemic key yet.
  bool _notReady = false;

  /// '' = popular songs, else a playlist id.
  String _sel = '';
  final Map<String, List<MusicTrack>> _lists = {};
  final Set<String> _listFailed = {};

  @override
  bool get wantKeepAlive => true;

  @override
  void initState() {
    super.initState();
    _load();
  }

  Future<void> _load({bool fresh = false}) async {
    try {
      final h = await MusicRepository.instance.esHome(fresh: fresh);
      if (mounted) {
        setState(() {
          _home = h;
          _failed = false;
          _notReady = false;
        });
      }
    } on ApiException catch (e) {
      if (mounted) {
        setState(() {
          _failed = true;
          _notReady = e.statusCode == 503;
        });
      }
    } catch (_) {
      if (mounted) setState(() => _failed = true);
    }
  }

  Future<void> _open(String id) async {
    setState(() => _sel = id);
    if (id.isEmpty || _lists.containsKey(id)) return;
    _listFailed.remove(id);
    try {
      final l = await MusicRepository.instance.esPlaylist(id);
      if (mounted) setState(() => _lists[id] = l);
    } catch (_) {
      if (mounted) setState(() => _listFailed.add(id));
    }
  }

  Widget _chip(String id, String label) {
    final on = _sel == id;
    return Padding(
      padding: const EdgeInsets.only(right: 8),
      child: ChoiceChip(
        key: ValueKey(id.isEmpty ? 'es-chip-popular' : 'es-chip-$id'),
        label: Text(label),
        selected: on,
        showCheckmark: false,
        onSelected: (_) => _open(id),
        selectedColor: AppColors.lime,
        backgroundColor: AppColors.surfaceHigh,
        side: BorderSide.none,
        visualDensity: VisualDensity.compact,
        labelStyle: TextStyle(
          color: on ? Colors.black : AppColors.textPrimary,
          fontWeight: FontWeight.w700,
          fontSize: 12.5,
        ),
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    super.build(context);
    final h = _home;
    if (h == null && _notReady) {
      return const _Empty(
        Icons.music_note_outlined,
        'Songs are coming soon',
        'For now use Original, Saved or a song from your phone.',
      );
    }
    final tracks = h == null ? null : (_sel.isEmpty ? h.tracks : _lists[_sel]);
    return Column(
      children: [
        if (h != null && h.playlists.isNotEmpty)
          SizedBox(
            height: 44,
            child: ListView(
              key: const ValueKey('es-chips'),
              scrollDirection: Axis.horizontal,
              padding: const EdgeInsets.fromLTRB(14, 6, 6, 4),
              children: [
                _chip('', 'Popular'),
                for (final p in h.playlists) _chip(p.id, p.name),
              ],
            ),
          ),
        Expanded(
          child: _AudioList(
            listKey: 'audio-trending',
            tracks: tracks,
            failed: h == null ? _failed : _listFailed.contains(_sel),
            onUse: widget.onUse,
            onRetry: () {
              if (h == null) {
                setState(() => _failed = false);
                _load(fresh: true);
              } else {
                final id = _sel;
                setState(() => _listFailed.remove(id));
                _lists.remove(id);
                _open(id);
              }
            },
            onRefresh: _sel.isEmpty ? () => _load(fresh: true) : null,
            empty: const _Empty(
              Icons.music_off_outlined,
              'No songs here',
              'Try another playlist or search.',
            ),
          ),
        ),
        const Padding(
          key: ValueKey('es-credit'),
          padding: EdgeInsets.fromLTRB(14, 2, 14, 8),
          child: Text(
            'Music by Epidemic Sound',
            style: TextStyle(fontSize: 11, color: AppColors.textHint),
          ),
        ),
      ],
    );
  }
}

/// Original: every audio people made, most used first.
class _OriginalTab extends StatefulWidget {
  const _OriginalTab({required this.onUse});
  final ValueChanged<MusicTrack> onUse;

  @override
  State<_OriginalTab> createState() => _OriginalTabState();
}

class _OriginalTabState extends State<_OriginalTab>
    with AutomaticKeepAliveClientMixin {
  List<MusicTrack>? _all;
  bool _failed = false;

  @override
  bool get wantKeepAlive => true;

  @override
  void initState() {
    super.initState();
    _load();
  }

  Future<void> _load({bool fresh = false}) async {
    try {
      final l = await MusicRepository.instance.all(fresh: fresh);
      if (mounted) {
        setState(() {
          _all = l;
          _failed = false;
        });
      }
    } catch (_) {
      if (mounted) setState(() => _failed = true);
    }
  }

  @override
  Widget build(BuildContext context) {
    super.build(context);
    return _AudioList(
      listKey: 'audio-original',
      tracks: _all,
      failed: _failed,
      onUse: widget.onUse,
      onRetry: () {
        setState(() => _failed = false);
        _load(fresh: true);
      },
      onRefresh: () => _load(fresh: true),
      empty: const _Empty(
        Icons.graphic_eq,
        'No audios yet',
        'When people post with music, their audio shows here.',
      ),
    );
  }
}

/// Saved: audios you bookmarked (newest first).
class _SavedTab extends StatefulWidget {
  const _SavedTab({required this.onUse});
  final ValueChanged<MusicTrack> onUse;

  @override
  State<_SavedTab> createState() => _SavedTabState();
}

class _SavedTabState extends State<_SavedTab>
    with AutomaticKeepAliveClientMixin {
  List<MusicTrack>? _list;
  bool _failed = false;
  List<String> _ids = const [];

  @override
  bool get wantKeepAlive => true;

  @override
  void initState() {
    super.initState();
    ChatPrefs.instance.value.addListener(_changed);
    _load();
  }

  @override
  void dispose() {
    ChatPrefs.instance.value.removeListener(_changed);
    super.dispose();
  }

  /// Unsaving keeps the row until you leave (so it can be saved again);
  /// a new save loads the list again.
  void _changed() {
    final now = ChatPrefs.instance.value.value.savedAudio;
    if (now.any((id) => !_ids.contains(id))) _load();
  }

  Future<void> _load() async {
    final ids = ChatPrefs.instance.value.value.savedAudio;
    _ids = ids;
    try {
      final l = await MusicRepository.instance.saved(ids);
      if (mounted && identical(ids, _ids)) {
        setState(() {
          _list = l;
          _failed = false;
        });
      }
    } catch (_) {
      if (mounted) setState(() => _failed = true);
    }
  }

  @override
  Widget build(BuildContext context) {
    super.build(context);
    return _AudioList(
      listKey: 'audio-saved',
      tracks: _list,
      failed: _failed,
      onUse: widget.onUse,
      onRetry: () {
        setState(() => _failed = false);
        _load();
      },
      onRefresh: _load,
      empty: const _Empty(
        Icons.bookmark_border,
        'No saved audios',
        'Tap the bookmark on an audio to save it for later.',
      ),
    );
  }
}

/// Search in all audios (name or @username).
class _SearchResults extends StatefulWidget {
  const _SearchResults({required this.query, required this.onUse});
  final String query;
  final ValueChanged<MusicTrack> onUse;

  @override
  State<_SearchResults> createState() => _SearchResultsState();
}

class _SearchResultsState extends State<_SearchResults> {
  List<MusicTrack>? _found;
  bool _failed = false;
  Timer? _wait;

  @override
  void initState() {
    super.initState();
    _search();
  }

  @override
  void didUpdateWidget(covariant _SearchResults old) {
    super.didUpdateWidget(old);
    if (old.query != widget.query) {
      _wait?.cancel();
      _wait = Timer(const Duration(milliseconds: 250), _search);
    }
  }

  @override
  void dispose() {
    _wait?.cancel();
    super.dispose();
  }

  /// Epidemic songs first, then audios people made. One of them failing
  /// still shows the other.
  Future<void> _search() async {
    final q = widget.query;
    final repo = MusicRepository.instance;
    Future<List<MusicTrack>?> safe(Future<List<MusicTrack>> f) async {
      try {
        return await f;
      } catch (_) {
        return null;
      }
    }

    final r = await Future.wait([safe(repo.esSearch(q)), safe(repo.search(q))]);
    if (!mounted || q != widget.query) return;
    if (r[0] == null && r[1] == null) {
      setState(() => _failed = true);
      return;
    }
    setState(() {
      _found = [...?r[0], ...?r[1]];
      _failed = false;
    });
  }

  @override
  Widget build(BuildContext context) => _AudioList(
    listKey: 'audio-results',
    tracks: _found,
    failed: _failed,
    onUse: widget.onUse,
    onRetry: () {
      setState(() => _failed = false);
      _search();
    },
    empty: _Empty(
      Icons.search_off,
      'No audio found',
      'Nothing called "${widget.query}". Try a song name, a mood or @username.',
    ),
  );
}

// --------------------------------------------------------------- AI songs

class _AiTab extends StatefulWidget {
  const _AiTab({required this.onUse});
  final ValueChanged<MusicTrack> onUse;

  @override
  State<_AiTab> createState() => _AiTabState();
}

class _AiTabState extends State<_AiTab> with AutomaticKeepAliveClientMixin {
  final _idea = TextEditingController();
  SongInfo? _info;
  bool _infoFailed = false;
  List<MusicTrack> _mine = const [];
  bool _full = false;
  bool _instrumental = false;
  bool _making = false;
  String _error = '';

  @override
  bool get wantKeepAlive => true;

  @override
  void initState() {
    super.initState();
    _load();
  }

  @override
  void dispose() {
    _idea.dispose();
    super.dispose();
  }

  Future<void> _load() async {
    final repo = MusicRepository.instance;
    try {
      final info = await repo.songInfo();
      if (mounted) {
        setState(() {
          _info = info;
          _infoFailed = false;
        });
      }
    } catch (_) {
      if (mounted) setState(() => _infoFailed = true);
    }
    try {
      final mine = await repo.mySongs();
      if (mounted) setState(() => _mine = mine);
    } catch (_) {}
  }

  int get _cost => _full ? (_info?.fullCost ?? 2) : 1;

  Future<void> _make() async {
    final idea = _idea.text.trim();
    if (idea.length < 3) {
      setState(() => _error = 'Write what the song should be about.');
      return;
    }
    FocusScope.of(context).unfocus();
    setState(() {
      _making = true;
      _error = '';
    });
    try {
      final (song, info) = await MusicRepository.instance.makeSong(
        prompt: idea,
        full: _full,
        instrumental: _instrumental,
      );
      if (!mounted) return;
      setState(() {
        _info = info;
        _mine = [song, ..._mine.where((t) => t.id != song.id)];
        _idea.clear();
      });
      MusicPlayer.instance.play('$_kPreview-${song.id}', song.url);
    } catch (e) {
      if (!mounted) return;
      setState(
        () => _error = e is ApiException
            ? e.message
            : 'Could not make the song. Try again.',
      );
    } finally {
      if (mounted) setState(() => _making = false);
    }
  }

  Widget _chip(String key, String label, bool on, ValueChanged<bool> set) =>
      FilterChip(
        key: ValueKey(key),
        label: Text(label),
        selected: on,
        showCheckmark: false,
        selectedColor: AppColors.lime,
        backgroundColor: AppColors.surface,
        labelStyle: TextStyle(
          color: on ? Colors.black : AppColors.textPrimary,
          fontWeight: FontWeight.w700,
          fontSize: 12.5,
        ),
        side: BorderSide(color: on ? AppColors.lime : AppColors.border),
        onSelected: _making ? null : set,
      );

  @override
  Widget build(BuildContext context) {
    super.build(context);
    final info = _info;
    final Widget maker;
    if (info == null) {
      maker = Padding(
        padding: const EdgeInsets.all(30),
        child: Center(
          child: _infoFailed
              ? TextButton(
                  key: const ValueKey('ai-retry'),
                  onPressed: () {
                    setState(() => _infoFailed = false);
                    _load();
                  },
                  child: const Text("Couldn't load. Tap to try again"),
                )
              : const Skeleton(kind: SkeletonKind.tracks, count: 3),
        ),
      );
    } else if (!info.enabled) {
      maker = const _Empty(
        Icons.auto_awesome_outlined,
        'AI songs are not on yet',
        'Use a song from the library or your phone.',
      );
    } else {
      final enough = info.left >= _cost;
      maker = Padding(
        padding: const EdgeInsets.fromLTRB(14, 12, 14, 6),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            TextField(
              key: const ValueKey('ai-idea'),
              controller: _idea,
              enabled: !_making,
              maxLength: 300,
              minLines: 2,
              maxLines: 4,
              decoration: InputDecoration(
                hintText:
                    'Describe your song. Example: happy lofi beat '
                    'for a sunset bike ride',
                filled: true,
                fillColor: AppColors.surface,
                border: OutlineInputBorder(
                  borderRadius: BorderRadius.circular(12),
                  borderSide: BorderSide.none,
                ),
              ),
            ),
            Wrap(
              spacing: 8,
              children: [
                _chip(
                  'ai-full',
                  'Full song (uses ${info.fullCost})',
                  _full,
                  (v) => setState(() => _full = v),
                ),
                _chip(
                  'ai-instrumental',
                  'No singing',
                  _instrumental,
                  (v) => setState(() => _instrumental = v),
                ),
              ],
            ),
            const SizedBox(height: 8),
            FilledButton.icon(
              key: const ValueKey('ai-make'),
              onPressed: _making || !enough ? null : _make,
              style: FilledButton.styleFrom(
                backgroundColor: AppColors.lime,
                foregroundColor: Colors.black,
                minimumSize: const Size.fromHeight(46),
                textStyle: const TextStyle(fontWeight: FontWeight.w800),
              ),
              icon: _making
                  ? const SizedBox(
                      width: 18,
                      height: 18,
                      child: CircularProgressIndicator(
                        strokeWidth: 2,
                        color: Colors.black,
                      ),
                    )
                  : const Icon(Icons.auto_awesome),
              label: Text(_making ? 'Making your song…' : 'Make song'),
            ),
            const SizedBox(height: 6),
            Text(
              _making
                  ? 'This can take up to 2 minutes. You can close this '
                        '- the song will be in "My AI songs".'
                  : '${info.left} left today · new songs every day',
              key: const ValueKey('ai-left'),
              textAlign: TextAlign.center,
              style: const TextStyle(
                fontSize: 12,
                color: AppColors.textSecondary,
              ),
            ),
            if (_error.isNotEmpty)
              Padding(
                padding: const EdgeInsets.only(top: 6),
                child: Text(
                  _error,
                  key: const ValueKey('ai-error'),
                  textAlign: TextAlign.center,
                  style: const TextStyle(color: AppColors.like, fontSize: 13),
                ),
              ),
          ],
        ),
      );
    }
    return ListView(
      children: [
        maker,
        if (_mine.isNotEmpty) ...[
          const Padding(
            padding: EdgeInsets.fromLTRB(14, 14, 14, 4),
            child: Text(
              'My AI songs',
              style: TextStyle(fontWeight: FontWeight.w800, fontSize: 15),
            ),
          ),
          for (final t in _mine)
            TrackRow(track: t, onUse: () => widget.onUse(t)),
        ],
        const SizedBox(height: 20),
      ],
    );
  }
}

// ------------------------------------------------------------ coming soon

/// AI song tab while AI songs are switched off.
class _AiSoon extends StatelessWidget {
  const _AiSoon();

  @override
  Widget build(BuildContext context) => const Center(
    key: ValueKey('ai-soon'),
    child: Padding(
      padding: EdgeInsets.all(24),
      child: Column(
        mainAxisSize: MainAxisSize.min,
        children: [
          Icon(Icons.auto_awesome, size: 40, color: AppColors.lime),
          SizedBox(height: 12),
          Text(
            'Coming soon',
            style: TextStyle(fontSize: 18, fontWeight: FontWeight.w800),
          ),
          SizedBox(height: 6),
          Text(
            'Make your own song with AI.\nWe are working on it.',
            textAlign: TextAlign.center,
            style: TextStyle(fontSize: 13, color: AppColors.textSecondary),
          ),
        ],
      ),
    ),
  );
}

// ------------------------------------------------------------------ phone

class _PhoneTab extends StatelessWidget {
  const _PhoneTab();

  Future<void> _pick(BuildContext context) async {
    try {
      final a = await MediaService.instance.pickAudio();
      if (a == null || !context.mounted) return;
      Navigator.of(context).pop(a);
    } catch (e) {
      if (!context.mounted) return;
      final msg = e is StateError ? e.message : 'Could not open music: $e';
      ScaffoldMessenger.of(context)
        ..hideCurrentSnackBar()
        ..showSnackBar(SnackBar(content: Text(msg)));
    }
  }

  @override
  Widget build(BuildContext context) {
    return Center(
      child: Padding(
        padding: const EdgeInsets.all(24),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            const Icon(
              Icons.folder_open_outlined,
              size: 40,
              color: AppColors.textHint,
            ),
            const SizedBox(height: 12),
            FilledButton.icon(
              key: const ValueKey('music-phone'),
              onPressed: () => _pick(context),
              style: FilledButton.styleFrom(
                backgroundColor: AppColors.lime,
                foregroundColor: Colors.black,
                textStyle: const TextStyle(fontWeight: FontWeight.w800),
              ),
              icon: const Icon(Icons.music_note),
              label: const Text('Pick from phone'),
            ),
            const SizedBox(height: 10),
            const Text(
              'MP3, M4A, AAC, WAV or OGG · up to 20 MB.\n'
              'Only use music you are allowed to share.',
              textAlign: TextAlign.center,
              style: TextStyle(fontSize: 12, color: AppColors.textSecondary),
            ),
          ],
        ),
      ),
    );
  }
}

// ------------------------------------------------------------ start point

/// "Starts at 0:12" slider for the chosen song.
class MusicStartSlider extends StatelessWidget {
  const MusicStartSlider({
    super.key,
    required this.startMs,
    required this.lengthMs,
    required this.onChanged,
    required this.onChangeEnd,
  });

  final int startMs;
  final int lengthMs;
  final ValueChanged<int> onChanged;
  final ValueChanged<int> onChangeEnd;

  @override
  Widget build(BuildContext context) {
    // the last 5 s can't be the start
    final max = lengthMs - 5000;
    if (max <= 1000) return const SizedBox.shrink();
    final v = startMs.clamp(0, max).toDouble();
    return Row(
      children: [
        SizedBox(
          width: 92,
          child: Text(
            'Starts ${trackTime(v.round()).isEmpty ? '0:00' : trackTime(v.round())}',
            key: const ValueKey('music-start-label'),
            style: const TextStyle(
              fontSize: 12,
              color: AppColors.textSecondary,
            ),
          ),
        ),
        Expanded(
          child: SliderTheme(
            data: SliderTheme.of(context).copyWith(
              trackHeight: 3,
              activeTrackColor: AppColors.lime,
              thumbColor: AppColors.lime,
              inactiveTrackColor: AppColors.border,
              overlayShape: SliderComponentShape.noOverlay,
            ),
            child: Slider(
              key: const ValueKey('music-start'),
              value: v,
              max: max.toDouble(),
              onChanged: (x) => onChanged(x.round()),
              onChangeEnd: (x) => onChangeEnd(x.round()),
            ),
          ),
        ),
      ],
    );
  }
}
