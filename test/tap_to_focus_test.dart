import 'package:camerawesome/camerawesome_plugin.dart';
import 'package:camerawesome/pigeon.dart';
import 'package:camerawesome/src/widgets/preview/awesome_camera_gesture_detector.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

/// MIN-6738: tap vs long-press (AE/AF lock) on the preview, and the Android
/// lock flag crossing the platform channel.
void main() {
  group('AwesomeCameraGestureDetector', () {
    final frame = PreviewSize(width: 1440, height: 1920);

    Future<List<String>> pumpDetector(WidgetTester tester, {bool withLongPress = true}) async {
      final calls = <String>[];
      await tester.pumpWidget(
        Directionality(
          textDirection: TextDirection.ltr,
          child: AwesomeCameraGestureDetector(
            onPreviewScale: null,
            onPreviewTapBuilder: OnPreviewTapBuilder(
              pixelPreviewSizeGetter: () => frame,
              flutterPreviewSizeGetter: () => frame,
              onPreviewTap: OnPreviewTap(
                onTapPainter: null,
                onTap: (position, _, __) => calls.add('tap ${position.dx.round()},${position.dy.round()}'),
                onLongPress: withLongPress
                    ? (position, _, __) => calls.add('long ${position.dx.round()},${position.dy.round()}')
                    : null,
              ),
            ),
            child: const SizedBox.expand(),
          ),
        ),
      );
      return calls;
    }

    testWidgets('a tap focuses, and only a tap', (tester) async {
      final calls = await pumpDetector(tester);
      await tester.tapAt(const Offset(100, 200));
      await tester.pumpAndSettle();
      expect(calls, ['tap 100,200']);
    });

    testWidgets('a press-and-hold locks instead of tapping', (tester) async {
      final calls = await pumpDetector(tester);
      await tester.longPressAt(const Offset(120, 220));
      await tester.pumpAndSettle();
      expect(calls, ['long 120,220']);
    });

    testWidgets('without onLongPress a hold is still just a tap', (tester) async {
      final calls = await pumpDetector(tester, withLongPress: false);
      await tester.longPressAt(const Offset(120, 220));
      await tester.pumpAndSettle();
      expect(calls, ['tap 120,220']);
    });
  });

  group('AndroidFocusSettings', () {
    test('carries the lock flag across the channel', () {
      final decoded = AndroidFocusSettings.decode(
        AndroidFocusSettings(autoCancelDurationInMillis: 0, lockFocusAndExposure: true).encode(),
      );
      expect(decoded.autoCancelDurationInMillis, 0);
      expect(decoded.lockFocusAndExposure, isTrue);
    });

    test('decodes the old one-field shape as no lock', () {
      final decoded = AndroidFocusSettings.decode(<Object?>[2500]);
      expect(decoded.autoCancelDurationInMillis, 2500);
      expect(decoded.lockFocusAndExposure, isNull);
    });
  });
}
