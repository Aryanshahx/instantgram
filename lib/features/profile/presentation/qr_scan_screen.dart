import 'package:flutter/material.dart';
import 'package:image_picker/image_picker.dart';
import 'package:mobile_scanner/mobile_scanner.dart';

import '../../../core/theme/app_colors.dart';
import '../../../core/utils/profile_link.dart';
import 'open_username.dart';

/// Scan someone's InstantGram QR code -> opens their profile.
class QrScanScreen extends StatefulWidget {
  const QrScanScreen({super.key});

  @override
  State<QrScanScreen> createState() => _QrScanScreenState();
}

class _QrScanScreenState extends State<QrScanScreen> {
  final MobileScannerController _ctrl = MobileScannerController(
    formats: const [BarcodeFormat.qrCode],
  );
  bool _busy = false;
  String _lastBad = '';

  @override
  void dispose() {
    _ctrl.dispose();
    super.dispose();
  }

  Future<void> _handle(String? raw) async {
    if (_busy || raw == null || raw.isEmpty) return;
    final name = usernameFromLink(raw);
    if (name == null) {
      if (raw != _lastBad) {
        _lastBad = raw;
        ScaffoldMessenger.of(context)
          ..hideCurrentSnackBar()
          ..showSnackBar(
            const SnackBar(content: Text('This is not an InstantGram code')),
          );
      }
      return;
    }
    setState(() => _busy = true);
    await _ctrl.stop();
    if (!mounted) return;
    final ok = await openUsername(context, name, replace: true);
    if (!ok && mounted) {
      setState(() => _busy = false);
      await _ctrl.start();
    }
  }

  Future<void> _fromGallery() async {
    final x = await ImagePicker().pickImage(source: ImageSource.gallery);
    if (x == null || !mounted) return;
    try {
      final res = await _ctrl.analyzeImage(x.path);
      final raw = res?.barcodes.isEmpty ?? true
          ? null
          : res!.barcodes.first.rawValue;
      if (raw == null) {
        if (mounted) {
          ScaffoldMessenger.of(context).showSnackBar(
            const SnackBar(content: Text('No QR code found in that photo')),
          );
        }
        return;
      }
      await _handle(raw);
    } catch (_) {
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          const SnackBar(content: Text('Could not read that photo')),
        );
      }
    }
  }

  @override
  Widget build(BuildContext context) {
    final size = MediaQuery.of(context).size;
    final box = (size.width * 0.68).clamp(200.0, 320.0);
    return Scaffold(
      backgroundColor: Colors.black,
      appBar: AppBar(
        backgroundColor: Colors.transparent,
        title: const Text('Scan QR code'),
        actions: [
          IconButton(
            tooltip: 'Flash',
            icon: const Icon(Icons.flashlight_on_outlined),
            onPressed: () => _ctrl.toggleTorch(),
          ),
        ],
      ),
      extendBodyBehindAppBar: true,
      body: Stack(
        fit: StackFit.expand,
        children: [
          MobileScanner(
            controller: _ctrl,
            onDetect: (c) =>
                _handle(c.barcodes.isEmpty ? null : c.barcodes.first.rawValue),
            errorBuilder: (context, error) => Center(
              child: Padding(
                padding: const EdgeInsets.all(32),
                child: Text(
                  error.errorCode == MobileScannerErrorCode.permissionDenied
                      ? 'Allow camera access in Settings to scan codes.'
                      : 'Camera not available.',
                  textAlign: TextAlign.center,
                  style: const TextStyle(color: AppColors.textSecondary),
                ),
              ),
            ),
          ),
          // frame
          Center(
            child: Container(
              width: box,
              height: box,
              decoration: BoxDecoration(
                borderRadius: BorderRadius.circular(28),
                border: Border.all(color: AppColors.lime, width: 3),
              ),
            ),
          ),
          if (_busy) const Center(child: CircularProgressIndicator()),
          Positioned(
            left: 24,
            right: 24,
            bottom: 40 + MediaQuery.of(context).padding.bottom,
            child: Column(
              children: [
                const Text(
                  'Point the camera at an InstantGram QR code',
                  textAlign: TextAlign.center,
                  style: TextStyle(fontWeight: FontWeight.w600),
                ),
                const SizedBox(height: 14),
                OutlinedButton.icon(
                  key: const ValueKey('scan-gallery'),
                  onPressed: _busy ? null : _fromGallery,
                  icon: const Icon(Icons.photo_library_outlined),
                  label: const Text('Scan from photo'),
                ),
              ],
            ),
          ),
        ],
      ),
    );
  }
}
