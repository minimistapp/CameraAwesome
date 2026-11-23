import 'package:camerawesome/camerawesome_plugin.dart';
import 'package:camerawesome/pigeon.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';

/// MIN-7683: the native side keeps one camera, so a camera screen that opens
/// while the previous one is closing sets up first. The closing screen's stop
/// must then leave the new camera alone.
void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  final calls = <String>[];

  setUp(() {
    calls.clear();
    CamerawesomePlugin.currentState = CameraRunningState.stopped;
    final messenger = TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger;
    for (final method in ['setupCamera', 'start', 'stop']) {
      messenger.setMockMessageHandler('dev.flutter.pigeon.CameraInterface.$method', (_) async {
        calls.add(method);
        return const StandardMessageCodec().encodeMessage(<Object?>[true]);
      });
    }
  });

  Future<int> setUpCamera() {
    final setup = CamerawesomePlugin.init(
      SensorConfig.single(),
      false,
      false,
      exifPreferences: ExifPreferences(saveGPSLocation: false),
      videoOptions: null,
      mirrorFrontCamera: false,
    );
    final generation = CamerawesomePlugin.setupGeneration;
    return setup.then((_) => generation);
  }

  test('a superseded screen does not stop the camera that replaced it', () async {
    final scanner = await setUpCamera();
    await CamerawesomePlugin.start();
    final live = await setUpCamera();
    await CamerawesomePlugin.start();

    expect(await CamerawesomePlugin.stop(generation: scanner), isTrue);
    expect(calls, ['setupCamera', 'start', 'setupCamera', 'start']);
    expect(CamerawesomePlugin.currentState, CameraRunningState.started);

    await CamerawesomePlugin.stop(generation: live);
    expect(calls.last, 'stop');
    expect(CamerawesomePlugin.currentState, CameraRunningState.stopped);
  });

  test('a new setup starts its camera even though the old one was running', () async {
    await setUpCamera();
    await CamerawesomePlugin.start();
    await setUpCamera();
    await CamerawesomePlugin.start();
    expect(calls.where((c) => c == 'start'), hasLength(2));
  });

  test('the current screen still stops its own camera', () async {
    final generation = await setUpCamera();
    await CamerawesomePlugin.start();
    await CamerawesomePlugin.stop(generation: generation);
    expect(calls, ['setupCamera', 'start', 'stop']);
  });
}
