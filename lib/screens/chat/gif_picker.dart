import 'dart:async';

import 'package:cached_network_image/cached_network_image.dart';
import 'package:flutter/material.dart';

import '../../core/errors.dart';
import '../../core/theme.dart';
import '../../services/giphy.dart';

/// Search Giphy and pick a GIF.
Future<GifItem?> showGifPicker(BuildContext context, {GiphyClient? client}) {
  return showModalBottomSheet<GifItem>(
    context: context,
    isScrollControlled: true,
    useSafeArea: true,
    showDragHandle: true,
    builder: (_) => FractionallySizedBox(
      heightFactor: 0.9,
      child: GifPicker(client: client ?? GiphyClient()),
    ),
  );
}

class GifPicker extends StatefulWidget {
  const GifPicker({super.key, required this.client});
  final GiphyClient client;

  @override
  State<GifPicker> createState() => _GifPickerState();
}

class _GifPickerState extends State<GifPicker> {
  final _q = TextEditingController();
  Timer? _debounce;
  List<GifItem> _items = const [];
  bool _loading = true;
  String? _error;
  int _token = 0;

  @override
  void initState() {
    super.initState();
    _run('');
  }

  @override
  void dispose() {
    _debounce?.cancel();
    _q.dispose();
    super.dispose();
  }

  void _changed(String v) {
    _debounce?.cancel();
    _debounce = Timer(const Duration(milliseconds: 400), () => _run(v));
  }

  Future<void> _run(String q) async {
    final t = ++_token;
    setState(() {
      _loading = true;
      _error = null;
    });
    try {
      final r = await widget.client.search(q);
      if (!mounted || t != _token) return;
      setState(() {
        _items = r;
        _loading = false;
      });
    } catch (e) {
      if (!mounted || t != _token) return;
      setState(() {
        _error = e is MediaException ? e.message : 'Could not load GIFs.';
        _loading = false;
      });
    }
  }

  @override
  Widget build(BuildContext context) {
    final cols = MediaQuery.sizeOf(context).width > 700 ? 4 : 2;
    return Column(
      children: [
        Padding(
          padding: const EdgeInsets.fromLTRB(16, 0, 16, 10),
          child: TextField(
            key: const ValueKey('gifSearch'),
            controller: _q,
            onChanged: _changed,
            textInputAction: TextInputAction.search,
            decoration: const InputDecoration(
              hintText: 'Search GIFs',
              prefixIcon: Icon(Icons.search_rounded),
            ),
          ),
        ),
        Expanded(child: _body(cols)),
        Padding(
          padding: const EdgeInsets.symmetric(vertical: 6),
          child: Text(
            'Powered by GIPHY',
            style: TextStyle(
              color: context.muted,
              fontSize: 11.5,
              fontWeight: FontWeight.w700,
            ),
          ),
        ),
      ],
    );
  }

  Widget _body(int cols) {
    if (_loading && _items.isEmpty) {
      return const Center(child: CircularProgressIndicator());
    }
    if (_error != null) {
      return Center(
        child: Padding(
          padding: const EdgeInsets.all(24),
          child: Text(_error!, textAlign: TextAlign.center),
        ),
      );
    }
    if (_items.isEmpty) return const Center(child: Text('No GIFs found.'));
    return GridView.builder(
      padding: const EdgeInsets.symmetric(horizontal: 12),
      gridDelegate: SliverGridDelegateWithFixedCrossAxisCount(
        crossAxisCount: cols,
        mainAxisSpacing: 8,
        crossAxisSpacing: 8,
        childAspectRatio: 1.15,
      ),
      itemCount: _items.length,
      itemBuilder: (context, i) {
        final g = _items[i];
        return GestureDetector(
          key: ValueKey('gif_${g.id}'),
          onTap: () => Navigator.pop(context, g),
          child: ClipRRect(
            borderRadius: BorderRadius.circular(12),
            child: CachedNetworkImage(
              imageUrl: g.previewUrl,
              fit: BoxFit.cover,
              placeholder: (_, _) => ColoredBox(color: context.softFill),
              errorWidget: (_, _, _) => ColoredBox(color: context.softFill),
            ),
          ),
        );
      },
    );
  }
}
