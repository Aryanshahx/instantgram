/// Where uploads are authorised (the signer on Vercel) and where files are read from
/// (the public Tigris bucket address). Set both with:
///   bash tools/set_media_url.sh
const String kMediaApiUrl = 'https://CHANGE-ME.vercel.app/api';
const String kMediaPublicUrl = 'https://CHANGE-ME.t3.tigrisfiles.io';

/// Longest clip users may upload.
const int kMaxVideoSeconds = 60;

/// Biggest files the media service accepts (same limits are enforced in signer/lib/core.js).
/// Clips above the limit are shrunk on the phone automatically.
const int kMaxVideoMb = 300;
const int kMaxImageMb = 30;
