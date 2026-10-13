import 'package:flutter/widgets.dart';

/// Knows which screens are covered by another full screen (v0.8).
/// Moments open as a see-through page, so the feed below still counted as
/// "on screen" and its video played in the background. Videos ask
/// [isCovered] and listen to [changes].
///
/// Sheets and dialogs (comments, menus) do NOT count as covering.
class PageCover extends NavigatorObserver {
  PageCover._();
  static final PageCover instance = PageCover._();

  /// Goes up whenever a page opens or closes.
  final ValueNotifier<int> changes = ValueNotifier<int>(0);
  final List<Route<dynamic>> _stack = [];

  /// True when a page was opened on top of [route].
  bool isCovered(Route<dynamic>? route) {
    if (route == null) return false;
    final i = _stack.indexOf(route);
    if (i < 0) return false;
    for (var k = i + 1; k < _stack.length; k++) {
      if (_stack[k] is PageRoute) return true;
    }
    return false;
  }

  void _changed() => changes.value++;

  @override
  void didPush(Route<dynamic> route, Route<dynamic>? previousRoute) {
    _stack.add(route);
    _changed();
  }

  @override
  void didPop(Route<dynamic> route, Route<dynamic>? previousRoute) {
    _stack.remove(route);
    _changed();
  }

  @override
  void didRemove(Route<dynamic> route, Route<dynamic>? previousRoute) {
    _stack.remove(route);
    _changed();
  }

  @override
  void didReplace({Route<dynamic>? newRoute, Route<dynamic>? oldRoute}) {
    final i = oldRoute == null ? -1 : _stack.indexOf(oldRoute);
    if (newRoute != null) {
      if (i >= 0) {
        _stack[i] = newRoute;
      } else {
        _stack.add(newRoute);
      }
    } else if (i >= 0) {
      _stack.removeAt(i);
    }
    _changed();
  }

  @visibleForTesting
  void debugReset() {
    _stack.clear();
    _changed();
  }
}

/// For a State: [pageCovered] is true while another page is on top.
/// Override [onPageCoverChanged] to pause / play.
mixin PageCoverAware<T extends StatefulWidget> on State<T> {
  bool pageCovered = false;
  ModalRoute<dynamic>? _route;
  bool _listening = false;

  void onPageCoverChanged(bool covered) {}

  void _check() {
    if (!mounted) return;
    final now = PageCover.instance.isCovered(_route);
    if (now == pageCovered) return;
    pageCovered = now;
    onPageCoverChanged(now);
  }

  @override
  void didChangeDependencies() {
    super.didChangeDependencies();
    _route = ModalRoute.of(context);
    if (!_listening) {
      _listening = true;
      PageCover.instance.changes.addListener(_check);
    }
    pageCovered = PageCover.instance.isCovered(_route);
  }

  @override
  void dispose() {
    PageCover.instance.changes.removeListener(_check);
    super.dispose();
  }
}
