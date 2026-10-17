import 'package:flutter/material.dart';

import '../../../core/services/api_client.dart';
import '../../../core/services/media_service.dart';
import '../../../core/services/music_player.dart';
import '../../../core/theme/app_colors.dart';
import '../../../shared/models/music.dart';
import '../data/music_repository.dart';

const String _kPreview = 'music-picker';

/// Stops a song preview of this sheet (each song plays as its own owner).
void _stopPreview() {
  final o = MusicPlayer.instance.owner.value;
  if (o != null && o.startsWith(_kPreview)) MusicPlayer.instance.stop(o);
}

/// Music update: choose a song for a post / clip / moment.
/// Library (songs the admin added), AI song (made with Google Lyria,
/// a few per day), Phone (a music file). null = nothing chosen.
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

  @override
  State<MusicPickerSheet> createState() => _MusicPickerSheetState();
}

class _MusicPickerSheetState extends State<MusicPickerSheet> {
  @override
  void dispose() {
    _stopPreview();
    super.dispose();
  }

  void _use(MusicTrack t) {
    _stopPreview();
    Navigator.of(context).pop(
      PickedAudio.online(
        url: t.url,
        name: t.label,
        musicId: t.id,
        durationMs: t.durationMs,
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    final h = MediaQuery.sizeOf(context).height;
    return SizedBox(
      height: h * 0.86,
      child: DefaultTabController(
        length: 3,
        child: Column(
          children: [
            const SizedBox(height: 8),
            Container(
              width: 36,
              height: 4,
              decoration: BoxDecoration(
                color: AppColors.border,
                borderRadius: BorderRadius.circular(2),
              ),
            ),
            const TabBar(
              key: ValueKey('music-tabs'),
              indicatorColor: AppColors.lime,
              labelColor: AppColors.textPrimary,
              unselectedLabelColor: AppColors.textSecondary,
              dividerColor: AppColors.border,
              labelStyle: TextStyle(fontWeight: FontWeight.w700),
              tabs: [
                Tab(key: ValueKey('music-tab-library'), text: 'Library'),
                Tab(key: ValueKey('music-tab-ai'), text: 'AI song'),
                Tab(key: ValueKey('music-tab-phone'), text: 'Phone'),
              ],
            ),
            Expanded(
              child: TabBarView(
                children: [
                  _LibraryTab(onUse: _use),
                  _AiTab(onUse: _use),
                  const _PhoneTab(),
                ],
              ),
            ),
          ],
        ),
      ),
    );
  }
}

// ------------------------------------------------------------------ rows

/// One song: play button, name, artist, Use.
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
      if (t.uses > 0) t.uses == 1 ? '1 use' : '${t.uses} uses',
    ].join(' · ');
    return InkWell(
      key: ValueKey('track-${t.id}'),
      onTap: onUse,
      child: Padding(
        padding: const EdgeInsets.fromLTRB(14, 7, 8, 7),
        child: Row(
          children: [
            ValueListenableBuilder<String?>(
              valueListenable: MusicPlayer.instance.owner,
              builder: (_, now, _) {
                final on = now == owner;
                return GestureDetector(
                  key: ValueKey('track-play-${t.id}'),
                  onTap: () => on
                      ? MusicPlayer.instance.stop(owner)
                      : MusicPlayer.instance.play(owner, t.url),
                  child: Container(
                    width: 42,
                    height: 42,
                    decoration: BoxDecoration(
                      color: on ? AppColors.lime : AppColors.surfaceHigh,
                      borderRadius: BorderRadius.circular(10),
                    ),
                    child: Icon(
                      on ? Icons.pause : Icons.play_arrow,
                      color: on ? Colors.black : AppColors.textPrimary,
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

// ---------------------------------------------------------------- library

class _LibraryTab extends StatefulWidget {
  const _LibraryTab({required this.onUse});
  final ValueChanged<MusicTrack> onUse;

  @override
  State<_LibraryTab> createState() => _LibraryTabState();
}

class _LibraryTabState extends State<_LibraryTab>
    with AutomaticKeepAliveClientMixin {
  List<MusicTrack>? _all;
  bool _failed = false;
  String _q = '';

  @override
  bool get wantKeepAlive => true;

  @override
  void initState() {
    super.initState();
    _load();
  }

  Future<void> _load({bool fresh = false}) async {
    try {
      final l = await MusicRepository.instance.library(fresh: fresh);
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
    final all = _all;
    if (all == null) {
      return Center(
        child: _failed
            ? TextButton(
                key: const ValueKey('music-retry'),
                onPressed: () {
                  setState(() => _failed = false);
                  _load(fresh: true);
                },
                child: const Text("Couldn't load. Tap to try again"),
              )
            : const CircularProgressIndicator(),
      );
    }
    final shown = searchTracks(all, _q);
    return Column(
      children: [
        Padding(
          padding: const EdgeInsets.fromLTRB(14, 10, 14, 4),
          child: TextField(
            key: const ValueKey('music-search'),
            onChanged: (v) => setState(() => _q = v),
            decoration: InputDecoration(
              isDense: true,
              hintText: 'Search songs, artists, moods',
              prefixIcon: const Icon(Icons.search, size: 20),
              filled: true,
              fillColor: AppColors.surface,
              border: OutlineInputBorder(
                borderRadius: BorderRadius.circular(12),
                borderSide: BorderSide.none,
              ),
            ),
          ),
        ),
        Expanded(
          child: RefreshIndicator(
            color: AppColors.lime,
            onRefresh: () => _load(fresh: true),
            child: shown.isEmpty
                ? ListView(
                    children: [
                      all.isEmpty
                          ? const _Empty(
                              Icons.library_music_outlined,
                              'No songs yet',
                              'New songs come soon. Try an AI song or a song '
                                  'from your phone.',
                            )
                          : const _Empty(
                              Icons.search_off,
                              'No song found',
                              'Try other words.',
                            ),
                    ],
                  )
                : ListView.builder(
                    key: const ValueKey('music-list'),
                    itemCount: shown.length,
                    itemBuilder: (_, i) => TrackRow(
                      track: shown[i],
                      onUse: () => widget.onUse(shown[i]),
                    ),
                  ),
          ),
        ),
      ],
    );
  }
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
              : const CircularProgressIndicator(),
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
                hintText: 'Describe your song. Example: happy lofi beat '
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
