import 'package:flutter/material.dart';

/// v0.13: pull to refresh could not reach the server.
void refreshFailed(BuildContext context) {
  ScaffoldMessenger.maybeOf(context)
    ?..hideCurrentSnackBar()
    ..showSnackBar(
      const SnackBar(
        content: Text(
          "Couldn't refresh: the internet is slow or off. Showing saved posts.",
        ),
      ),
    );
}
