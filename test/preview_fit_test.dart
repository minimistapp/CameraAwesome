import 'package:camerawesome/camerawesome_plugin.dart';
import 'package:camerawesome/pigeon.dart';
import 'package:camerawesome/src/widgets/preview/awesome_preview_fit.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

/// A portrait phone's 4:3 preview frame (iOS runs every ratio on it).
final _portraitFrame = PreviewSize(width: 1440, height: 1920);

/// A portrait phone's preview area.
const _phone = BoxConstraints(maxWidth: 390, maxHeight: 844);

double _containZoom(CameraAspectRatios? ratio, {PreviewSize? frame, BoxConstraints constraints = _phone}) {
  final calculator = PreviewSizeCalculator(
    previewFit: CameraPreviewFit.contain,
    previewSize: frame ?? _portraitFrame,
    constraints: constraints,
    captureAspectRatio: ratio,
  )..compute();
  return calculator.zoom;
}

void main() {
  group('captureCropSize', () {
    test('4:3 keeps the whole 4:3 frame', () {
      expect(captureCropSize(const Size(1920, 1440), CameraAspectRatios.ratio_4_3), const Size(1920, 1440));
    });

    test('16:9 trims the short side, keeping the long edge (landscape and portrait)', () {
      expect(captureCropSize(const Size(1920, 1440), CameraAspectRatios.ratio_16_9), const Size(1920, 1080));
      expect(captureCropSize(const Size(1440, 1920), CameraAspectRatios.ratio_16_9), const Size(1080, 1920));
    });

    test('1:1 trims the long side to the full short side', () {
      expect(captureCropSize(const Size(1440, 1920), CameraAspectRatios.ratio_1_1), const Size(1440, 1440));
    });

    test('a frame already in the ratio comes back whole (Android binds 16:9 natively)', () {
      expect(captureCropSize(const Size(1080, 1920), CameraAspectRatios.ratio_16_9), const Size(1080, 1920));
    });

    test('no ratio keeps the frame', () {
      expect(captureCropSize(const Size(1440, 1920), null), const Size(1440, 1920));
    });
  });

  group('contain fit', () {
    test('16:9 zooms the 4:3 frame by 4/3 so the band fills the width', () {
      final fourThree = _containZoom(CameraAspectRatios.ratio_4_3);
      final sixteenNine = _containZoom(CameraAspectRatios.ratio_16_9);
      expect(fourThree, closeTo(390 / 1440, 1e-9));
      expect(sixteenNine / fourThree, closeTo(4 / 3, 1e-9));
      // The visible 16:9 band is exactly as wide as the screen.
      expect(1080 * sixteenNine, closeTo(390, 1e-9));
    });

    test('1:1 keeps the full-frame fit (the app masks the trimmed bands)', () {
      expect(_containZoom(CameraAspectRatios.ratio_1_1), _containZoom(CameraAspectRatios.ratio_4_3));
    });

    test('no ratio is the old whole-frame fit', () {
      expect(_containZoom(null), _containZoom(CameraAspectRatios.ratio_4_3));
    });

    test('a landscape tablet zooms 16:9 until the band fills the width', () {
      const ipad = BoxConstraints(maxWidth: 1180, maxHeight: 820);
      final frame = PreviewSize(width: 1920, height: 1440);
      expect(_containZoom(CameraAspectRatios.ratio_4_3, frame: frame, constraints: ipad), closeTo(820 / 1440, 1e-9));
      expect(_containZoom(CameraAspectRatios.ratio_16_9, frame: frame, constraints: ipad), closeTo(1180 / 1920, 1e-9));
    });
  });

  group('AnimatedPreviewFit', () {
    const childKey = Key('preview');

    Widget fit(CameraAspectRatios ratio, {PreviewSize? frame}) {
      return Directionality(
        textDirection: TextDirection.ltr,
        child: Center(
          child: SizedBox(
            width: 390,
            height: 844,
            child: AnimatedPreviewFit(
              previewFit: CameraPreviewFit.contain,
              // A fresh instance each build, as the preview re-queries it.
              previewSize: frame ?? PreviewSize(width: 1440, height: 1920),
              constraints: _phone,
              sensor: Sensor.position(SensorPosition.back),
              captureAspectRatio: ratio,
              child: const _MountCounter(key: childKey),
            ),
          ),
        ),
      );
    }

    double renderedWidth(WidgetTester tester) => tester.getSize(find.byType(FittedBox)).width;

    testWidgets('a ratio change animates the zoom and keeps the preview mounted', (tester) async {
      _MountCounter.mounts = 0;
      await tester.pumpWidget(fit(CameraAspectRatios.ratio_4_3));
      expect(renderedWidth(tester), closeTo(390, 0.01));

      await tester.pumpWidget(fit(CameraAspectRatios.ratio_16_9));
      await tester.pump(const Duration(milliseconds: 150));
      final midway = renderedWidth(tester);
      expect(midway, greaterThan(390));
      expect(midway, lessThan(520));

      await tester.pumpAndSettle();
      expect(renderedWidth(tester), closeTo(520, 0.01));
      // The visible box stays clipped to the available width.
      expect(tester.getSize(find.byType(ClipRect)).width, closeTo(390, 0.01));
      // Re-parenting the native preview remounts it; the zoom must not.
      expect(_MountCounter.mounts, 1);
    });

    testWidgets('an overflowing frame stays centred under a non-centre alignment', (tester) async {
      await tester.pumpWidget(
        Directionality(
          textDirection: TextDirection.ltr,
          child: Align(
            alignment: Alignment.topLeft,
            child: SizedBox(
              width: 390,
              height: 844,
              child: AnimatedPreviewFit(
                alignment: Alignment.topLeft,
                previewFit: CameraPreviewFit.contain,
                previewSize: PreviewSize(width: 1440, height: 1920),
                constraints: _phone,
                sensor: Sensor.position(SensorPosition.back),
                captureAspectRatio: CameraAspectRatios.ratio_16_9,
                child: const SizedBox.expand(),
              ),
            ),
          ),
        ),
      );
      final viewport = tester.getRect(find.byType(ClipRect));
      final frame = tester.getRect(find.byType(FittedBox));
      // The 520-wide frame overflows the 390-wide viewport evenly: 65 each side,
      // so the visible band is the centred crop the still gets.
      expect(frame.center.dx, closeTo(viewport.center.dx, 0.01));
      expect(viewport.left - frame.left, closeTo(65, 0.01));
    });

    testWidgets('a new frame size snaps instead of animating', (tester) async {
      await tester.pumpWidget(fit(CameraAspectRatios.ratio_4_3));
      await tester.pumpWidget(fit(CameraAspectRatios.ratio_4_3, frame: PreviewSize(width: 1080, height: 1920)));
      await tester.pump();
      expect(renderedWidth(tester), closeTo(390, 0.01));
      expect(tester.hasRunningAnimations, isFalse);
    });

    testWidgets('reports the end-state fit once per change', (tester) async {
      final reported = <AnalysisPreview>[];
      Widget reporting(CameraAspectRatios ratio) => Directionality(
            textDirection: TextDirection.ltr,
            child: AnimatedPreviewFit(
              previewFit: CameraPreviewFit.contain,
              previewSize: PreviewSize(width: 1440, height: 1920),
              constraints: _phone,
              sensor: Sensor.position(SensorPosition.back),
              captureAspectRatio: ratio,
              onPreviewCalculated: reported.add,
              child: const SizedBox(),
            ),
          );

      await tester.pumpWidget(reporting(CameraAspectRatios.ratio_4_3));
      await tester.pumpWidget(reporting(CameraAspectRatios.ratio_16_9));
      await tester.pumpAndSettle();
      expect(reported, hasLength(2));
      expect(reported.last.scale, closeTo(390 / 1080, 1e-9));
    });
  });
}

class _MountCounter extends StatefulWidget {
  const _MountCounter({super.key});

  static int mounts = 0;

  @override
  State<_MountCounter> createState() => _MountCounterState();
}

class _MountCounterState extends State<_MountCounter> {
  @override
  void initState() {
    super.initState();
    _MountCounter.mounts++;
  }

  @override
  Widget build(BuildContext context) => const SizedBox.expand();
}
