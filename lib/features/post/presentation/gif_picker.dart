import 'dart:async';
import 'dart:io';

import 'package:flutter/material.dart';
import 'package:path_provider/path_provider.dart';

import '../../../core/services/gif_search.dart';
import '../../../core/services/media_service.dart';
import '../../../core/theme/app_colors.dart';
import '../../../core/utils/errors.dart';
import '../../../shared/widgets/net_image.dart';

/// What was chosen in the GIF picker: a GIPHY GIF or a gallery GIF file.
class PickedGif {
  const PickedGif.search(GifResult this.gif) : file = null;
  const PickedGif.file(File this.file) : gif = null;

  final GifResult? gif;
  final File? file;
}

/// GIF search (GIPHY) + "From gallery" (v0.8 comments).
Future<PickedGif?> showGifPicker(BuildContext context) =>
    showModalBottomSheet<PickedGif>(
      context: context,
      isScrollControlled: true,
      useSafeArea: true,
      builder: (_) => const GifPickerSheet(),
    );

class GifPickerSheet extends StatefulWidget {
  const GifPickerSheet({super.key});

  @override
  State<GifPickerSheet> createState() => _GifPickerSheetState();
}

class _GifPickerSheetState extends State<GifPickerSheet> {
  final _query = TextEditingController();
  final _scroll = ScrollController();
  Timer? _debounce;
  final List<GifResult> _gifs = [];
  int? _next = 0;
  bool _loading = false;
  bool _off = false; // server has no GIPHY key
  String _error = '';
  int _searchId = 0;

  @override
  void initState() {
    super.initState();
    _scroll.addListener(() {
      if (_scroll.position.extentAfter < 400) _load();
    });
    _load(reset: true);
  }

  @override
  void dispose() {
    _debounce?.cancel();
    _query.dispose();
    _scroll.dispose();
    super.dispose();
  }

  void _onQuery(String _) {
    _debounce?.cancel();
    _debounce = Timer(
      const Duration(milliseconds: 450),
      () => _load(reset: true),
    );
  }

  Future<void> _load({bool reset = false}) async {
    if (reset) {
      _searchId++;
      _gifs.clear();
      _next = 0;
      _loading = false;
      _error = '';
    }
    final offset = _next;
    if (_loading || offset == null || _off) return;
    final id = _searchId;
    setState(() => _loading = true);
    try {
      final page = await GifSearch.instance.search(_query.text, offset: offset);
      if (!mounted || id != _searchId) return;
      setState(() {
        _gifs.addAll(page.gifs);
        _next = page.next;
      });
    } on GifSearchOff {
      if (mounted) setState(() => _off = true);
    } catch (e) {
      if (mounted && id == _searchId) setState(() => _error = friendlyError(e));
    } finally {
      if (mounted && id == _searchId) setState(() => _loading = false);
    }
  }

  Future<void> _fromGallery() async {
    try {
      var f = await MediaService.instance.pickGalleryGif();
      if (f == null) return;
      if (!f.path.toLowerCase().endsWith('.gif')) {
        final dir = await getTemporaryDirectory();
        f = await f.copy(
          '${dir.path}/gif_${DateTime.now().millisecondsSinceEpoch}.gif',
        );
      }
      if (await f.length() > 15 * 1024 * 1024) {
        throw const FormatException('This GIF is too big (max 15 MB)');
      }
      if (mounted) Navigator.pop(context, PickedGif.file(f));
    } catch (e) {
      if (!mounted) return;
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(
          content: Text(e is FormatException ? e.message : friendlyError(e)),
        ),
      );
    }
  }

  @override
  Widget build(BuildContext context) {
    return SizedBox(
      height: MediaQuery.sizeOf(context).height * 0.7,
      child: Padding(
        padding: EdgeInsets.only(
          bottom: MediaQuery.viewInsetsOf(context).bottom,
        ),
        child: Column(
          children: [
            Padding(
              padding: const EdgeInsets.fromLTRB(12, 0, 12, 8),
              child: Row(
                children: [
                  Expanded(
                    child: TextField(
                      key: const ValueKey('gif-search'),
                      controller: _query,
                      enabled: !_off,
                      onChanged: _onQuery,
                      textInputAction: TextInputAction.search,
                      decoration: InputDecoration(
                        isDense: true,
                        prefixIcon: const Icon(Icons.search, size: 20),
                        hintText: 'Search GIFs',
                        filled: true,
                        fillColor: AppColors.background,
                        contentPadding: const EdgeInsets.symmetric(
                          vertical: 10,
                        ),
                        border: OutlineInputBorder(
                          borderRadius: BorderRadius.circular(22),
                          borderSide: BorderSide.none,
                        ),
                      ),
                    ),
                  ),
                  const SizedBox(width: 8),
                  TextButton.icon(
                    key: const ValueKey('gif-gallery'),
                    onPressed: _fromGallery,
                    icon: const Icon(Icons.photo_library_outlined, size: 18),
                    label: const Text('Gallery'),
                  ),
                ],
              ),
            ),
            Expanded(child: _body()),
            if (!_off)
              const Padding(
                padding: EdgeInsets.symmetric(vertical: 6),
                child: Text(
                  'Powered by GIPHY',
                  key: ValueKey('giphy-attribution'),
                  style: TextStyle(
                    fontSize: 11,
                    fontWeight: FontWeight.w700,
                    color: AppColors.textSecondary,
                  ),
                ),
              ),
          ],
        ),
      ),
    );
  }

  Widget _body() {
    if (_off) {
      return Center(
        child: Padding(
          padding: const EdgeInsets.all(24),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              const Icon(Icons.gif_box_outlined, size: 44),
              const SizedBox(height: 10),
              const Text(
                'GIF search is not set up yet.',
                key: ValueKey('gif-off'),
                textAlign: TextAlign.center,
                style: TextStyle(fontWeight: FontWeight.w700),
              ),
              const SizedBox(height: 4),
              const Text(
                'You can send a GIF from your gallery.',
                textAlign: TextAlign.center,
                style: TextStyle(color: AppColors.textSecondary),
              ),
              const SizedBox(height: 14),
              FilledButton.icon(
                onPressed: _fromGallery,
                icon: const Icon(Icons.photo_library_outlined),
                label: const Text('Choose a GIF'),
              ),
            ],
          ),
        ),
      );
    }
    if (_gifs.isEmpty) {
      if (_loading) {
        return const Center(child: CircularProgressIndicator());
      }
      return Center(
        child: Text(
          _error.isNotEmpty ? _error : 'No GIFs found',
          style: const TextStyle(color: AppColors.textSecondary),
        ),
      );
    }
    return GridView.builder(
      controller: _scroll,
      padding: const EdgeInsets.symmetric(horizontal: 8),
      gridDelegate: const SliverGridDelegateWithFixedCrossAxisCount(
        crossAxisCount: 3,
        mainAxisSpacing: 4,
        crossAxisSpacing: 4,
      ),
      itemCount: _gifs.length,
      itemBuilder: (context, i) {
        final g = _gifs[i];
        return GestureDetector(
          key: ValueKey('gif-$i'),
          onTap: () => Navigator.pop(context, PickedGif.search(g)),
          child: ClipRRect(
            borderRadius: BorderRadius.circular(6),
            child: ColoredBox(
              color: AppColors.surfaceHigh,
              child: NetImage(g.preview),
            ),
          ),
        );
      },
    );
  }
}
