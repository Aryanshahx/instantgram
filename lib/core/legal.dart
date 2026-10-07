import 'package:flutter/widgets.dart';
import 'package:url_launcher/url_launcher.dart';

/// Where the Privacy Policy and the Terms of Use pages live. They are the files
/// `docs/privacy.md` and `docs/terms.md` of the repository, shown by GitHub Pages.
/// Change the address here if you host them somewhere else.
const String kLegalBaseUrl = 'https://aryanshahx.github.io/instantgram';

/// The two pages the app opens, right in the repository, so they are always the current
/// version and there is nothing to publish:
///   https://github.com/Aryanshahx/instantgram/blob/main/docs/privacy.md
///   https://github.com/Aryanshahx/instantgram/blob/main/docs/terms.md
const String kRepoBaseUrl = 'https://github.com/Aryanshahx/instantgram/blob/main/docs';
const String kPrivacyUrl = '$kRepoBaseUrl/privacy.md';
const String kTermsUrl = '$kRepoBaseUrl/terms.md';

/// Opens [url] in the browser. Returns false when that did not work, so the caller can show
/// the in-app copy of the text instead.
Future<bool> openLegalUrl(String url) async {
  try {
    return await launchUrl(
      Uri.parse(url),
      mode: LaunchMode.externalApplication,
    );
  } catch (_) {
    return false;
  }
}

/// Opens the page in the browser, or runs [fallback] (the in-app page) when that fails.
Future<void> openLegal(
  BuildContext context,
  String url,
  VoidCallback fallback,
) async {
  final ok = await openLegalUrl(url);
  if (!ok && context.mounted) fallback();
}

/// The link of a profile (the landing page `docs/profile.html` shows who it is and how to
/// find the person in the app) and the text that goes with it when it is shared.
String profileLinkFor(String username) =>
    '$kLegalBaseUrl/profile.html?u=${Uri.encodeQueryComponent(username)}';

String profileShareText(String username) =>
    'Follow @$username on InstantGram\n${profileLinkFor(username)}';
