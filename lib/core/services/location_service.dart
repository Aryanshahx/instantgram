import 'package:geocoding/geocoding.dart';
import 'package:geolocator/geolocator.dart';

/// Where you are now, for a chat location card (v0.9).
/// Free: phone GPS + the phone's own geocoder (no API key).
class PickedLocation {
  const PickedLocation(this.lat, this.lng, this.address);
  final double lat;
  final double lng;
  final String address;
}

class LocationProblem implements Exception {
  const LocationProblem(this.message, {this.openSettings = false});
  final String message;

  /// Permission was denied for ever: only the settings can fix it.
  final bool openSettings;
  @override
  String toString() => message;
}

class LocationService {
  LocationService._();
  static final LocationService instance = LocationService._();

  Future<PickedLocation> current() async {
    if (!await Geolocator.isLocationServiceEnabled()) {
      throw const LocationProblem('Turn on Location on your phone.');
    }
    var perm = await Geolocator.checkPermission();
    if (perm == LocationPermission.denied) {
      perm = await Geolocator.requestPermission();
    }
    if (perm == LocationPermission.deniedForever) {
      throw const LocationProblem(
        'Location permission is off. Allow it in Settings.',
        openSettings: true,
      );
    }
    if (perm == LocationPermission.denied) {
      throw const LocationProblem('Location permission is needed.');
    }
    Position pos;
    try {
      pos = await Geolocator.getCurrentPosition(
        locationSettings: const LocationSettings(
          accuracy: LocationAccuracy.high,
          timeLimit: Duration(seconds: 15),
        ),
      );
    } catch (_) {
      final last = await Geolocator.getLastKnownPosition();
      if (last == null) {
        throw const LocationProblem("Couldn't find your location. Try again.");
      }
      pos = last;
    }
    return PickedLocation(
      pos.latitude,
      pos.longitude,
      await addressOf(pos.latitude, pos.longitude),
    );
  }

  /// "Mall Road, Kanpur, Uttar Pradesh" ('' when unknown).
  Future<String> addressOf(double lat, double lng) async {
    try {
      final list = await Geocoding().placemarkFromCoordinates(lat, lng);
      if (list.isEmpty) return '';
      return formatPlace(list.first);
    } catch (_) {
      return '';
    }
  }

  static String formatPlace(Placemark p) {
    final parts = <String>[];
    void add(String? v) {
      final t = (v ?? '').trim();
      if (t.isEmpty || parts.contains(t)) return;
      // skip plus codes like "7JWX+2Q"
      if (RegExp(r'^[A-Z0-9]{4,}\+[A-Z0-9]{2,}$').hasMatch(t)) return;
      parts.add(t);
    }

    add(p.name);
    add(p.street);
    add(p.subLocality);
    add(p.locality);
    add(p.administrativeArea);
    return parts.take(4).join(', ');
  }

  Future<void> openSettings() => Geolocator.openAppSettings();
}
