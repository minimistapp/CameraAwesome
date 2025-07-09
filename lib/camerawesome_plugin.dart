import 'dart:async';
import 'dart:io';
import 'dart:typed_data';

import 'package:camerawesome/camerawesome_plugin.dart';
import 'package:camerawesome/src/logger.dart';
import 'package:camerawesome/src/orchestrator/pigeon/pigeon_generated.dart' as pigeon;
import 'package:camerawesome/src/orchestrator/adapters/pigeon_sensor_adapter.dart';
import 'package:camerawesome/src/orchestrator/models/camera_physical_button.dart';
import 'package:camerawesome/src/orchestrator/models/sensor_data_internal.dart';
import 'package:camerawesome/src/orchestrator/models/video_options.dart';
import 'package:collection/collection.dart';
import 'package:flutter/services.dart';

export 'src/camera_characteristics/camera_characteristics.dart';
export 'src/orchestrator/analysis/analysis_controller.dart';
export 'src/orchestrator/models/models.dart';
export 'src/orchestrator/models/sensor_type.dart';
export 'src/orchestrator/models/sensors.dart';
export 'src/orchestrator/states/states.dart';
export 'src/widgets/camera_awesome_builder.dart';
export 'src/orchestrator/analysis/analysis_to_image.dart';
export 'src/orchestrator/models/analysis/analysis_canvas.dart';

// filters
export 'src/orchestrator/models/filters/awesome_filters.dart';

// built in widgets
export 'src/widgets/widgets.dart';

// ignore: public_member_api_docs
enum CameraRunningState { starting, started, stopping, stopped }

/// Don't use this class directly. Instead, use [CameraAwesomeBuilder].
class CamerawesomePlugin {
  static const EventChannel _orientationChannel = EventChannel('camerawesome/orientation');

  static const EventChannel _permissionsChannel = EventChannel('camerawesome/permissions');

  static const EventChannel _imagesChannel = EventChannel('camerawesome/images');

  static const EventChannel _physicalButtonChannel = EventChannel('camerawesome/physical_button');

  static Stream<CameraOrientations>? _orientationStream;

  static Stream<CameraPhysicalButton>? _physicalButtonStream;

  static Stream<bool>? _permissionsStream;

  static Stream<Map<String, dynamic>>? _imagesStream;

  static CameraRunningState currentState = CameraRunningState.stopped;

  /// Set it to true to print dart logs from camerawesome
  static bool printLogs = false;

  static pigeon.CameraInterface _cameraInstance = pigeon.CameraInterface();

  static Future<List<pigeon.CamerAwesomePermission>> checkPermissions(List<pigeon.CamerAwesomePermission> permissions) async {
    final res = await _cameraInstance.checkPermissions(permissions.map((e) => e.name).toList());
    return res.whereType<String>().map((e) => pigeon.CamerAwesomePermission.values.firstWhere((p) => p.name == e)).toList();
  }

  static Future<List<pigeon.CamerAwesomePermission>> requestPermissions(bool saveGpsLocation) {
    try {
      if (Platform.isAndroid) {
        return _cameraInstance.requestPermissions(saveGpsLocation).then((givenPermissions) {
          return givenPermissions
              .whereType<String>()
              .map((e) => pigeon.CamerAwesomePermission.values.firstWhere((element) => element.name == e))
              .toList();
        });
      } else {
        return checkPermissions([
          pigeon.CamerAwesomePermission.camera,
          pigeon.CamerAwesomePermission.record_audio,
        ]);
      }
    } on PlatformException catch (e) {
      printLog('failed to request permissions: $e');
      return Future.value([]);
    }
  }

  static Future<bool> start() async {
    if (currentState == CameraRunningState.started || currentState == CameraRunningState.starting) {
      return true;
    }
    currentState = CameraRunningState.starting;
    bool res = await _cameraInstance.start();
    if (res) currentState = CameraRunningState.started;
    return res;
  }

  static Future<bool> stop() async {
    if (currentState == CameraRunningState.stopped || currentState == CameraRunningState.stopping) {
      return true;
    }
    _orientationStream = null;
    currentState = CameraRunningState.stopping;
    bool res;
    try {
      res = await _cameraInstance.stop();
    } catch (e) {
      return false;
    }
    currentState = CameraRunningState.stopped;
    return res;
  }

  static Stream<CameraOrientations>? getNativeOrientation() {
    _orientationStream ??= _orientationChannel
        .receiveBroadcastStream('orientationChannel')
        .transform(StreamTransformer<dynamic, CameraOrientations>.fromHandlers(handleData: (data, sink) {
      CameraOrientations? newOrientation;
      switch (data) {
        case 'LANDSCAPE_LEFT':
          newOrientation = CameraOrientations.landscape_left;
          break;
        case 'LANDSCAPE_RIGHT':
          newOrientation = CameraOrientations.landscape_right;
          break;
        case 'PORTRAIT_UP':
          newOrientation = CameraOrientations.portrait_up;
          break;
        case 'PORTRAIT_DOWN':
          newOrientation = CameraOrientations.portrait_down;
          break;
        default:
      }
      sink.add(newOrientation!);
    }));
    return _orientationStream;
  }

  static Stream<CameraPhysicalButton>? listenPhysicalButton() {
    _physicalButtonStream ??= _physicalButtonChannel
        .receiveBroadcastStream('physicalButtonChannel')
        .transform(StreamTransformer<dynamic, CameraPhysicalButton>.fromHandlers(handleData: (data, sink) {
      CameraPhysicalButton? physicalButton;
      switch (data) {
        case 'VOLUME_UP':
          physicalButton = CameraPhysicalButton.volume_up;
          break;
        case 'VOLUME_DOWN':
          physicalButton = CameraPhysicalButton.volume_down;
          break;
        default:
      }
      sink.add(physicalButton!);
    }));
    return _physicalButtonStream;
  }

  static Stream<bool>? listenPermissionResult() {
    _permissionsStream ??= _permissionsChannel
        .receiveBroadcastStream('permissionsChannel')
        .transform(StreamTransformer<dynamic, bool>.fromHandlers(handleData: (data, sink) {
      sink.add(data);
    }));
    return _permissionsStream;
  }

  static Future<void> setupAnalysis({
    int width = 0,
    double? maxFramesPerSecond,
    required pigeon.AnalysisImageFormat format,
    required bool autoStart,
  }) async {
    return _cameraInstance.setupImageAnalysisStream(
      format.name,
      width,
      maxFramesPerSecond,
      autoStart,
    );
  }

  static Stream<Map<String, dynamic>>? listenCameraImages() {
    _imagesStream ??= _imagesChannel.receiveBroadcastStream('imagesChannel').transform(
      StreamTransformer<dynamic, Map<String, dynamic>>.fromHandlers(
        handleData: (data, sink) {
          sink.add(Map<String, dynamic>.from(data));
        },
      ),
    );
    return _imagesStream;
  }

  static Future receivedImageFromStream() {
    return _cameraInstance.receivedImageFromStream();
  }

  static Future<bool?> init(
    SensorConfig sensorConfig,
    bool enableImageStream,
    bool enablePhysicalButton, {
    CaptureMode captureMode = CaptureMode.photo,
    required pigeon.ExifPreferences exifPreferences,
    required pigeon.VideoOptions? videoOptions,
    required bool mirrorFrontCamera,
  }) async {
    return _cameraInstance
        .setupCamera(
          sensorConfig.sensors.map((e) => e.toPigeon()).toList(),
          sensorConfig.aspectRatio.name.toUpperCase(),
          sensorConfig.zoom,
          mirrorFrontCamera,
          enablePhysicalButton,
          sensorConfig.flashMode.name,
          captureMode.name,
          enableImageStream,
          exifPreferences,
          videoOptions,
        )
        .then((value) => true);
  }

  static Future<List<Size>> getSizes() async {
    final availableSizes = await _cameraInstance.availableSizes();
    return availableSizes.whereType<pigeon.PreviewSize>().map((e) => Size(e.width, e.height)).toList();
  }

  static Future<int> getPreviewTexture(final int cameraPosition) {
    return _cameraInstance.getPreviewTextureId(cameraPosition);
  }

  static Future<void> setPreviewSize(int width, int height) {
    return _cameraInstance.setPreviewSize(pigeon.PreviewSize(width: width.toDouble(), height: height.toDouble()));
  }

  static Future<void> refresh() {
    return _cameraInstance.refresh();
  }

  /// android has a limits on preview size and fallback to 1920x1080 if preview is too big
  /// So to prevent having different ratio we get the real preview Size directly from nativ side
  static Future<pigeon.PreviewSize> getEffectivPreviewSize(int index) async {
    final ps = await _cameraInstance.getEffectivPreviewSize(index);
    if (ps != null) {
      return pigeon.PreviewSize(width: ps.width, height: ps.height);
    } else {
      return pigeon.PreviewSize(width: 0, height: 0);
    }
  }

  /// you can set a different size for preview and for photo
  /// for iOS, when taking a photo, best quality is automatically used
  static Future<void> setPhotoSize(int width, int height) {
    return _cameraInstance.setPhotoSize(
      pigeon.PreviewSize(
        width: width.toDouble(),
        height: height.toDouble(),
      ),
    );
  }

  static Future<bool> takePhoto(CaptureRequest captureRequest) async {
    final request = captureRequest.when(
      single: (single) => {
        single.sensor.toPigeon(): single.file?.path,
      },
      multiple: (multiple) => multiple.fileBySensor.map((key, value) {
        return MapEntry(key.toPigeon(), value?.path);
      }),
    );

    return _cameraInstance.takePhoto(
      request.keys.toList(),
      request.values.toList(),
    );
  }

  static Future<void> recordVideo(CaptureRequest request) {
    final pathBySensor = request.when(
      single: (single) => {
        single.sensor.toPigeon(): single.file?.path,
      },
      multiple: (multiple) => multiple.fileBySensor.map((key, value) {
        return MapEntry(key.toPigeon(), value?.path);
      }),
    );
    return _cameraInstance.recordVideo(
      pathBySensor.keys.toList(),
      pathBySensor.values.toList(),
    );
  }

  static Future<void> pauseVideoRecording() {
    return _cameraInstance.pauseVideoRecording();
  }

  static Future<void> resumeVideoRecording() {
    return _cameraInstance.resumeVideoRecording();
  }

  static Future<bool> stopRecordingVideo() {
    return _cameraInstance.stopRecordingVideo();
  }

  /// Switch flash mode from Android / iOS
  static Future<void> setFlashMode(String flashMode) {
    return _cameraInstance.setFlashMode(flashMode);
  }

  static Future<void> handleAutoFocus() {
    return _cameraInstance.handleAutoFocus();
  }

  /// Start auto focus on a specific [position] with a given [previewSize].
  ///
  /// On Android, you can set [androidFocusSettings].
  /// It contains a parameter [AndroidFocusSettings.autoCancelDurationInMillis].
  /// It is the time in milliseconds after which the auto focus will be canceled.
  /// Passive focus will resume after that duration.
  ///
  /// If that duration is equals to or less than 0, auto focus is never
  /// cancelled and passive focus will not resume. After this, if you want to
  /// focus on an other point, you'll have to call again [focusOnPoint].
  static Future<void> focusOnPoint({
    required Size previewSize,
    required Offset position,
  }) {
    return _cameraInstance.focusOnPoint(
      pigeon.PreviewSize(width: previewSize.width, height: previewSize.height),
      position.dx,
      position.dy,
      null,
    );
  }

  /// calls zoom from Android / iOS --
  static Future<void> setZoom(double zoom) {
    return _cameraInstance.setZoom(zoom);
  }

  /// switch camera sensor between [Sensors.back] and [Sensors.front]
  /// on iOS, you can specify the deviceId if you have multiple cameras
  /// call [getSensors] to get the list of available cameras
  static Future<void> setSensor(SensorConfig sensorConfig) {
    return _cameraInstance.setSensor(
      sensorConfig.sensors.map((e) => e.toPigeon()).toList(),
    );
  }

  /// change capture mode between [CaptureMode.photo] and [CaptureMode.video]
  static Future<void> setCaptureMode(String captureMode) {
    return _cameraInstance.setCaptureMode(captureMode);
  }

  /// enable audio mode recording or not
  static Future<bool> setRecordingAudioMode(bool enableAudio) {
    return _cameraInstance.setRecordingAudioMode(enableAudio);
  }

  /// set exif preferences when a photo is saved
  ///
  /// The GPS value can be null on Android if:
  /// - Location is disabled on the phone
  /// - ExifPreferences.saveGPSLocation is false
  /// - Permission ACCESS_FINE_LOCATION has not been granted
  static Future<bool> setExifPreferences(pigeon.ExifPreferences savedExifData) {
    return _cameraInstance.setExifPreferences(savedExifData);
  }

  /// set brightness manually with range [0,1]
  static Future<void> setCorrection(double brightness) {
    if (brightness < 0 || brightness > 1) {
      throw "Value must be between [0,1]";
    }
    return _cameraInstance.setCorrection(brightness);
  }

  /// returns the max zoom available on device
  static Future<double> getMaxZoom() {
    return _cameraInstance.getMaxZoom();
  }

  /// returns the min zoom available on device
  static Future<double> getMinZoom() {
    return _cameraInstance.getMinZoom();
  }

  static Future<bool> isMultiCamSupported() {
    return _cameraInstance.isMultiCamSupported();
  }

  /// Change aspect ratio when a photo is taken
  static Future<void> setAspectRatio(String aspectRatio) {
    return _cameraInstance.setAspectRatio(aspectRatio);
  }

  /// Returns the list of available sensors on device.
  ///
  /// The list contains the back and front sensors
  /// with their name, type, uid, iso and flash availability
  ///
  /// Only available on iOS for now
  static Future<SensorDeviceData> getSensors() async {
    // Can't use getter with pigeon, so we have to map the data manually...
    final frontSensors = await _cameraInstance.getFrontSensors();
    final backSensors = await _cameraInstance.getBackSensors();

    final frontSensorsData = frontSensors
        .map(
          (data) => SensorTypeDeviceInternal.fromPigeon(data!).toPublic(),
        )
        .toList();
    final backSensorsData = backSensors
        .map(
          (data) => SensorTypeDeviceInternal.fromPigeon(data!).toPublic(),
        )
        .toList();

    return SensorDeviceData(
      ultraWideAngle: backSensorsData.whereType<SensorTypeDevice>().firstWhereOrNull(
            (element) => element.sensorType == SensorType.ultraWideAngle,
          ),
      telephoto: backSensorsData.whereType<SensorTypeDevice>().firstWhereOrNull(
            (element) => element.sensorType == SensorType.telephoto,
          ),
      wideAngle: backSensorsData.whereType<SensorTypeDevice>().firstWhereOrNull(
            (element) => element.sensorType == SensorType.wideAngle,
          ),
      trueDepth: frontSensorsData.whereType<SensorTypeDevice>().firstWhereOrNull(
            (element) => element.sensorType == SensorType.trueDepth,
          ),
    );
  }

  // ---------------------------------------------------
  // UTILITY METHODS
  // ---------------------------------------------------
  static Future<List<pigeon.CamerAwesomePermission>?> checkAndRequestPermissions({
    required bool saveGpsLocation,
  }) async {
    return requestPermissions(saveGpsLocation);
  }

  static Future<void> startAnalysis() {
    return _cameraInstance.startAnalysis();
  }

  static Future<void> stopAnalysis() {
    return _cameraInstance.stopAnalysis();
  }

  static Future<void> setFilter(AwesomeFilter newFilter) async {
    return _cameraInstance.setFilter(Float64List.fromList(newFilter.matrix).buffer.asUint8List());
  }

  static Future<void> setMirrorFrontCamera(bool mirrorFrontCamera) {
    return _cameraInstance.setMirrorFrontCamera(mirrorFrontCamera);
  }

  static Future<bool> isVideoRecordingAndImageAnalysisSupported(SensorPosition sensor) {
    return _cameraInstance.isVideoRecordingAndImageAnalysisSupported(
      sensor == SensorPosition.back ? pigeon.PigeonSensorPosition.back : pigeon.PigeonSensorPosition.front,
    );
  }

  /// Only for tests
  static void setMock(pigeon.CameraInterface mock) {
    _cameraInstance = mock;
  }
}

extension ExifPreferencesExt on pigeon.ExifPreferences {
  pigeon.ExifPreferences toPigeon() {
    return this;
  }
}

extension VideoOptionsExt on pigeon.VideoOptions {
  pigeon.VideoOptions toPigeon() {
    return this;
  }
}
