import 'dart:math' as math;

import 'package:geolocator/geolocator.dart';

import '../core/errors.dart';

/// Where the phone is right now.
class Where {
  const Where(this.lat, this.lng);
  final double lat;
  final double lng;
}

/// Asks for permission when needed and returns the current position.
Future<Where> currentLocation() async {
  if (!await Geolocator.isLocationServiceEnabled()) {
    throw const MediaException('Turn on location (GPS) on your phone first.');
  }
  var perm = await Geolocator.checkPermission();
  if (perm == LocationPermission.denied) {
    perm = await Geolocator.requestPermission();
  }
  if (perm == LocationPermission.denied ||
      perm == LocationPermission.deniedForever) {
    throw const MediaException(
      'Location permission is needed. Allow it in the phone settings.',
    );
  }
  try {
    final p = await Geolocator.getCurrentPosition(
      locationSettings: const LocationSettings(
        accuracy: LocationAccuracy.high,
        timeLimit: Duration(seconds: 20),
      ),
    );
    return Where(p.latitude, p.longitude);
  } catch (_) {
    throw const MediaException(
      'Could not find your location. Move to an open area and try again.',
    );
  }
}

/// Position of a point on the OpenStreetMap tile grid.
class MapSpot {
  const MapSpot({required this.x, required this.y, required this.zoom});

  /// Tile coordinates with a fraction (the point inside its tile).
  final double x;
  final double y;
  final int zoom;

  int get tileX => x.floor();
  int get tileY => y.floor();
}

/// Web-mercator tile maths (https://wiki.openstreetmap.org/wiki/Slippy_map_tilenames).
MapSpot mapSpot(double lat, double lng, int zoom) {
  final la = lat.clamp(-85.0511, 85.0511);
  final n = math.pow(2, zoom).toDouble();
  final x = (lng + 180) / 360 * n;
  final r = la * math.pi / 180;
  final y = (1 - math.log(math.tan(r) + 1 / math.cos(r)) / math.pi) / 2 * n;
  return MapSpot(x: x, y: y, zoom: zoom);
}

/// "26.8467, 80.9462"
String formatCoords(double lat, double lng) =>
    '${lat.toStringAsFixed(5)}, ${lng.toStringAsFixed(5)}';

Uri mapsUri(double lat, double lng) =>
    Uri.parse('https://www.google.com/maps/search/?api=1&query=$lat,$lng');
