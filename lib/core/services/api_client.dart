import 'dart:convert';

import 'package:firebase_auth/firebase_auth.dart';
import 'package:http/http.dart' as http;

import '../config/app_config.dart';

class ApiException implements Exception {
  const ApiException(this.message, {this.statusCode = 0});
  final String message;

  /// HTTP status from the server (0 = no answer / not from the server).
  final int statusCode;

  @override
  String toString() => message;
}

/// Talks to the InstantGram backend on Vercel.
/// Every request carries the Firebase ID token so the server knows who you are.
class ApiClient {
  ApiClient._();
  static final ApiClient instance = ApiClient._();

  Future<Map<String, dynamic>> post(
    String path,
    Map<String, dynamic> body,
  ) async {
    if (!AppConfig.hasApi) {
      throw const ApiException(
        'Upload server is not set up yet (API_BASE_URL missing).',
      );
    }
    final user = FirebaseAuth.instance.currentUser;
    if (user == null) throw const ApiException('Please log in again.');
    final token = await user.getIdToken();

    final http.Response res;
    try {
      res = await http
          .post(
            Uri.parse('${AppConfig.apiBaseUrl}$path'),
            headers: {
              'Authorization': 'Bearer $token',
              'Content-Type': 'application/json',
            },
            body: jsonEncode(body),
          )
          .timeout(const Duration(seconds: 30));
    } catch (_) {
      throw const ApiException('Could not reach the server. Check internet.');
    }

    Map<String, dynamic> data;
    try {
      data = jsonDecode(res.body) as Map<String, dynamic>;
    } catch (_) {
      data = {};
    }
    if (res.statusCode < 200 || res.statusCode >= 300) {
      throw ApiException(
        (data['error'] as String?) ?? 'Server error (${res.statusCode})',
        statusCode: res.statusCode,
      );
    }
    return data;
  }
}
