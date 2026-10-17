import 'package:flutter/material.dart';

import '../../../core/services/media_service.dart';
import '../../../core/services/music_player.dart';
import '../../../core/theme/app_colors.dart';
import '../../../shared/models/music.dart';
import '../../../shared/models/post.dart';
import '../../../shared/navigation.dart';
import '../../../shared/widgets/post_grid.dart';
import '../../post/data/post_repository.dart' show ViewSource;
import '../../post/presentation/create_sheet.dart';
import '../data/music_repository.dart';

/// Opens the song of [post] (tap on "♪ Song" on a post / clip).
/// Old posts without a song page: nothing happens.
void openMusicOf(BuildContext context, Post post) {
  if (post.musicId.isEmpty || !post.hasMusic) return;
  Navigator.of(context).push(
    MaterialPageRoute<void>(
      builder: (_) => MusicScreen(musicId: post.musicId, from: post),
    ),
  );
}

/// Music update: the page of one song - play it, "Use this audio", and
/// every post / clip made with it.
class MusicScreen extends StatefulWidget {
  const MusicScreen({super.key, required this.musicId, this.from});

  final String musicId;

  /// The post it was opened from (its start point is used).
  final Post? from;

  /// Tests: called instead of opening the camera roll.
  static void Function(PickedAudio audio)? debugUse;

  @override
  State<MusicScreen> createState() => _MusicScreenState();
}

class _MusicScreenState extends State<MusicScreen> {
  MusicTrack? _track;
  List<Post>? _posts;
  bool _failed = false;
  bool _missing = false;

  String get _owner => 'music-page-${widget.musicId}';

  @override
  void initState() {
    super.initState();
    _load();
  }

  @override
  void dispose() {
    MusicPlayer.instance.stop(_owner);
    super.dispose();
  }

  Future<void> _load() async {
    final repo = MusicRepository.instance;
    try {
      final t = await repo.track(widget.musicId);
      final posts = await repo.postsWith(widget.musicId);
      if (!mounted) return;
      setState(() {
        _track = t;
        _missing = t == null || t.hidden || t.url.isEmpty;
        _posts = posts;
        _failed = false;
      });
    } catch (_) {
      if (mounted) setState(() => _failed = true);
    }
  }

  int get _startMs => widget.from?.audioStartMs ?? 0;

  void _togglePlay(MusicTrack t) {
    final p = MusicPlayer.instance;
    if (p.isOwner(_owner)) {
      p.stop(_owner);
    } else {
      p.play(_owner, t.url, startMs: _startMs);
    }
  }

  Future<void> _use(MusicTrack t) async {
    await MusicPlayer.instance.stop(_owner);
    final audio = PickedAudio.online(
      url: t.url,
      name: t.label,
      musicId: t.id,
      startMs: _startMs,
      durationMs: t.durationMs,
    );
    final hook = MusicScreen.debugUse;
    if (hook != null) return hook(audio);
    if (!mounted) return;
    await startCompose(context, ComposeMode.clip, audio: audio);
  }

  Widget _header(MusicTrack? t) {
    final title = t?.title ?? widget.from?.audioName ?? 'Song';
    final kind = t == null
        ? ''
        : t.isAi
        ? 'AI song'
        : t.isOriginal
        ? 'Original audio'
        : t.mood.isNotEmpty && t.mood != 'other'
        ? t.mood[0].toUpperCase() + t.mood.substring(1)
        : '';
    final n = _posts?.length ?? 0;
    return Padding(
      padding: const EdgeInsets.fromLTRB(16, 6, 16, 12),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          Row(
            children: [
              ValueListenableBuilder<String?>(
                valueListenable: MusicPlayer.instance.owner,
                builder: (_, now, _) {
                  final on = now == _owner;
                  return GestureDetector(
                    key: const ValueKey('music-page-play'),
                    onTap: t == null || _missing ? null : () => _togglePlay(t),
                    child: Container(
                      width: 92,
                      height: 92,
                      decoration: BoxDecoration(
                        borderRadius: BorderRadius.circular(14),
                        gradient: const LinearGradient(
                          begin: Alignment.topLeft,
                          end: Alignment.bottomRight,
                          colors: [Color(0xFF1F2A12), Color(0xFF0E1A16)],
                        ),
                        border: Border.all(color: AppColors.border),
                      ),
                      child: Stack(
                        alignment: Alignment.center,
                        children: [
                          const Icon(
                            Icons.music_note,
                            size: 40,
                            color: AppColors.lime,
                          ),
                          if (!_missing)
                            Positioned(
                              right: 6,
                              bottom: 6,
                              child: Container(
                                width: 28,
                                height: 28,
                                decoration: const BoxDecoration(
                                  color: AppColors.lime,
                                  shape: BoxShape.circle,
                                ),
                                child: Icon(
                                  on ? Icons.pause : Icons.play_arrow,
                                  size: 18,
                                  color: Colors.black,
                                ),
                              ),
                            ),
                        ],
                      ),
                    ),
                  );
                },
              ),
              const SizedBox(width: 14),
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text(
                      title,
                      key: const ValueKey('music-page-title'),
                      maxLines: 2,
                      overflow: TextOverflow.ellipsis,
                      style: const TextStyle(
                        fontSize: 19,
                        fontWeight: FontWeight.w800,
                      ),
                    ),
                    if ((t?.artist ?? '').isNotEmpty)
                      Text(
                        t!.artist,
                        maxLines: 1,
                        overflow: TextOverflow.ellipsis,
                        style: const TextStyle(color: AppColors.textSecondary),
                      ),
                    const SizedBox(height: 4),
                    Text(
                      [
                        if (kind.isNotEmpty) kind,
                        n == 1 ? '1 share' : '$n shares',
                      ].join(' · '),
                      key: const ValueKey('music-page-count'),
                      style: const TextStyle(
                        fontSize: 12.5,
                        color: AppColors.textSecondary,
                      ),
                    ),
                  ],
                ),
              ),
            ],
          ),
          const SizedBox(height: 14),
          if (_missing)
            const Text(
              'This song is not available anymore.',
              key: ValueKey('music-page-missing'),
              textAlign: TextAlign.center,
              style: TextStyle(color: AppColors.textSecondary),
            )
          else
            FilledButton.icon(
              key: const ValueKey('music-use'),
              onPressed: t == null ? null : () => _use(t),
              style: FilledButton.styleFrom(
                backgroundColor: AppColors.lime,
                foregroundColor: Colors.black,
                minimumSize: const Size.fromHeight(44),
                textStyle: const TextStyle(fontWeight: FontWeight.w800),
              ),
              icon: const Icon(Icons.video_call_outlined),
              label: const Text('Use this audio'),
            ),
        ],
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    final posts = _posts;
    return Scaffold(
      appBar: AppBar(title: const Text('Audio')),
      body: posts == null
          ? Center(
              child: _failed
                  ? TextButton(
                      key: const ValueKey('music-page-retry'),
                      onPressed: () {
                        setState(() => _failed = false);
                        _load();
                      },
                      child: const Text("Couldn't load. Tap to try again"),
                    )
                  : const CircularProgressIndicator(),
            )
          : Column(
              crossAxisAlignment: CrossAxisAlignment.stretch,
              children: [
                _header(_track),
                Expanded(
                  child: RefreshIndicator(
                    color: AppColors.lime,
                    onRefresh: _load,
                    child: PostGrid(
                      key: const ValueKey('music-grid'),
                      posts: posts,
                      onTap: (i) => openPost(
                        context,
                        posts,
                        i,
                        source: ViewSource.explore,
                      ),
                      emptyIcon: Icons.music_note,
                      emptyTitle: 'Nothing with this song yet',
                      emptySubtitle: 'Be the first to use it.',
                    ),
                  ),
                ),
              ],
            ),
    );
  }
}
