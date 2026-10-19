import 'package:flutter/material.dart';
import 'package:mobile_scanner/mobile_scanner.dart';

import '../core/book_fields.dart';
import '../theme.dart';
import '../widgets/l10n_scope.dart';

/// Camera barcode scanning, the phone's answer to the desktop's USB reader.
///
/// Pops with the normalised ISBN so the caller can look it up.
class ScanScreen extends StatefulWidget {
  const ScanScreen({super.key});

  @override
  State<ScanScreen> createState() => _ScanScreenState();
}

class _ScanScreenState extends State<ScanScreen> {
  final MobileScannerController _controller = MobileScannerController(
    detectionSpeed: DetectionSpeed.noDuplicates,
    formats: const [
      BarcodeFormat.ean13,
      BarcodeFormat.ean8,
      BarcodeFormat.upcA,
      BarcodeFormat.upcE,
      BarcodeFormat.code128,
    ],
  );
  bool _handled = false;
  String? _error;

  @override
  void dispose() {
    _controller.dispose();
    super.dispose();
  }

  void _onDetect(BarcodeCapture capture) {
    if (_handled) return;
    for (final barcode in capture.barcodes) {
      final raw = barcode.rawValue;
      if (raw == null || raw.isEmpty) continue;
      final isbn = normalizeIsbn(raw);
      if (isbn.length < 8) continue;
      _handled = true;
      Navigator.of(context).pop(isbn);
      return;
    }
  }

  @override
  Widget build(BuildContext context) {
    final l10n = context.localized;
    return Scaffold(
      appBar: AppBar(
        title: Text(l10n.tr('Scan a barcode')),
        actions: [
          IconButton(
            tooltip: l10n.tr('Flashlight'),
            icon: const Icon(Icons.flashlight_on_outlined),
            onPressed: () async {
              try {
                await _controller.toggleTorch();
              } catch (_) {
                // Devices without a torch simply ignore this.
              }
            },
          ),
          IconButton(
            tooltip: l10n.tr('Switch camera'),
            icon: const Icon(Icons.cameraswitch_outlined),
            onPressed: () async {
              try {
                await _controller.switchCamera();
              } catch (_) {}
            },
          ),
        ],
      ),
      body: _error != null
          ? Center(
              child: Padding(
                padding: const EdgeInsets.all(24),
                child: Column(
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    const Icon(Icons.no_photography_outlined, color: kAmber, size: 40),
                    const SizedBox(height: 12),
                    Text(_error!, textAlign: TextAlign.center),
                    const SizedBox(height: 8),
                    Text(
                      l10n.tr(
                        'You can always type the ISBN by hand on the book form.',
                      ),
                      textAlign: TextAlign.center,
                      style: const TextStyle(color: kSlate500, fontSize: 12),
                    ),
                  ],
                ),
              ),
            )
          : Stack(
              fit: StackFit.expand,
              children: [
                MobileScanner(
                  controller: _controller,
                  onDetect: _onDetect,
                  errorBuilder: (context, error) {
                    WidgetsBinding.instance.addPostFrameCallback((_) {
                      if (mounted) setState(() => _error = error.errorDetails?.message);
                    });
                    return const SizedBox.shrink();
                  },
                  overlayBuilder: (context, constraints) => IgnorePointer(
                    child: Center(
                      child: Container(
                        width: constraints.maxWidth * 0.78,
                        height: constraints.maxHeight * 0.36,
                        decoration: BoxDecoration(
                          border: Border.all(color: kBrand, width: 2),
                          borderRadius: BorderRadius.circular(14),
                        ),
                      ),
                    ),
                  ),
                ),
                Positioned(
                  left: 0,
                  right: 0,
                  bottom: 32,
                  child: Center(
                    child: Container(
                      padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 8),
                      decoration: BoxDecoration(
                        color: kSlate950.withValues(alpha: 0.75),
                        borderRadius: BorderRadius.circular(999),
                      ),
                      child: Text(l10n.tr('Point the camera at the barcode on the back cover')),
                    ),
                  ),
                ),
              ],
            ),
    );
  }
}
