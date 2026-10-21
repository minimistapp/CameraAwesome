import 'dart:typed_data';

import 'package:camerawesome/camerawesome_plugin.dart';
import 'package:flutter/services.dart';
import 'package:flutter/widgets.dart';
import 'package:flutter_test/flutter_test.dart';

/// MIN-4185: the photo/video switch still — fades in over the preview, holds
/// the geometry through the switch, then lets the preview resize under it and
/// fades out.
void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  const channel = MethodChannel('camerawesome/preview_freeze');
  final freeze = PreviewFreeze.instance;
  late List<String> calls;
  late bool hasFrame;

  setUp(() {
    calls = [];
    hasFrame = true;
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger.setMockMethodCallHandler(channel, (call) async {
      calls.add(call.method);
      if (call.method == 'capture') {
        if (!hasFrame) return null;
        return {'width': 2, 'height': 2, 'pixels': Uint8List.fromList(List.filled(16, 128))};
      }
      return null;
    });
  });

  tearDown(() {
    freeze.reset();
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger.setMockMethodCallHandler(channel, null);
  });

  Future<void> pumpOverlay(WidgetTester tester) => tester.pumpWidget(
        const Directionality(textDirection: TextDirection.ltr, child: SizedBox(width: 100, height: 100, child: PreviewFreezeOverlay())),
      );

  double opacity(WidgetTester tester) => tester.widget<AnimatedOpacity>(find.byType(AnimatedOpacity)).opacity;

  testWidgets('covers with the captured still, holds, then settles and fades', (tester) async {
    await pumpOverlay(tester);
    expect(opacity(tester), 0);

    await tester.runAsync(() async {
      final covered = freeze.cover();
      // The frame's decode completes off the fake clock.
      await Future<void>.delayed(const Duration(milliseconds: 50));
      expect(freeze.phase, PreviewFreezePhase.covering);
      expect(freeze.still, isNotNull);
      await covered;
    });
    expect(calls, ['capture']);
    expect(freeze.phase, PreviewFreezePhase.holding);
    expect(freeze.holdsGeometry, isTrue);
    await tester.pump();
    expect(opacity(tester), 1);
    expect(find.byType(RawImage), findsOneWidget);

    final revealed = freeze.reveal();
    await tester.pump();
    expect(calls, ['capture', 'settled']);
    expect(freeze.phase, PreviewFreezePhase.settling);
    expect(freeze.isSettling, isTrue);
    expect(freeze.holdsGeometry, isFalse);

    await tester.pump(PreviewFreeze.revealDelay);
    expect(freeze.phase, PreviewFreezePhase.revealing);
    expect(opacity(tester), 0);

    await tester.pump(PreviewFreeze.revealDuration);
    await revealed;
    expect(freeze.phase, PreviewFreezePhase.idle);
    expect(freeze.still, isNull);
  });

  testWidgets('no frame: a plain black cover instead', (tester) async {
    hasFrame = false;
    await pumpOverlay(tester);
    final covered = freeze.cover();
    await tester.pump();
    await tester.pump(PreviewFreeze.coverDuration);
    await covered;
    expect(freeze.phase, PreviewFreezePhase.holding);
    expect(freeze.still, isNull);
    expect(find.byType(ColoredBox), findsOneWidget);
    freeze.reset();
  });

  testWidgets('a switch tapped mid-reveal brings the same still back', (tester) async {
    await pumpOverlay(tester);
    await tester.runAsync(() async => freeze.cover());
    final still = freeze.still;
    final revealed = freeze.reveal();
    await tester.pump();
    await tester.pump(PreviewFreeze.revealDelay);
    expect(freeze.phase, PreviewFreezePhase.revealing);

    final covered = freeze.cover();
    await tester.pump();
    expect(freeze.phase, PreviewFreezePhase.covering);
    expect(identical(freeze.still, still), isTrue);
    expect(calls.where((call) => call == 'capture'), hasLength(1));
    await tester.pump(PreviewFreeze.coverDuration);
    await covered;
    await tester.pump(PreviewFreeze.revealDuration);
    await revealed;
    // The first reveal was superseded: still up, waiting for its own.
    expect(freeze.phase, PreviewFreezePhase.holding);
    freeze.reset();
  });

  testWidgets('a switch that never settles is revealed by the backstop', (tester) async {
    hasFrame = false;
    await pumpOverlay(tester);
    final covered = freeze.cover();
    await tester.pump();
    await tester.pump(PreviewFreeze.coverDuration);
    await covered;
    expect(freeze.phase, PreviewFreezePhase.holding);
    // Armed when the cover started.
    await tester.pump(const Duration(seconds: 3) - PreviewFreeze.coverDuration);
    expect(freeze.phase, PreviewFreezePhase.settling);
    await tester.pump(PreviewFreeze.revealDelay + PreviewFreeze.revealDuration);
    expect(freeze.phase, PreviewFreezePhase.idle);
  });
}
