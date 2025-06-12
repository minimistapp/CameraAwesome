import 'package:camerawesome/src/orchestrator/models/sensor_type.dart';

class SensorDeviceData {
  /// A built-in wide-angle camera.
  ///
  /// The wide angle sensor is the default sensor for iOS
  SensorTypeDevice? wideAngle;

  /// A built-in camera with a shorter focal length than that of the wide-angle camera.
  SensorTypeDevice? ultraWideAngle;

  /// A built-in camera device with a longer focal length than the wide-angle camera.
  SensorTypeDevice? telephoto;

  /// A device that consists of two cameras, one Infrared and one YUV.
  ///
  /// iOS only
  SensorTypeDevice? trueDepth;

  SensorDeviceData({
    this.wideAngle,
    this.ultraWideAngle,
    this.telephoto,
    this.trueDepth,
  });

  int get availableBackSensors => [
        wideAngle,
        ultraWideAngle,
        telephoto,
      ].where((element) => element != null).length;

  int get availableFrontSensors => [
        trueDepth,
      ].where((element) => element != null).length;
}

class SensorTypeDevice {
  final SensorType sensorType;

  /// A localized device name for display in the user interface.
  final String name;

  /// The current exposure ISO value.
  final double iso;

  /// A Boolean value that indicates whether the flash is currently available for use.
  final bool flashAvailable;

  /// An identifier that uniquely identifies the device.
  final String uid;

  /// The zoom factor relative to the wide-angle camera.
  final double? zoomFactor;

  const SensorTypeDevice({
    required this.sensorType,
    required this.name,
    required this.iso,
    required this.flashAvailable,
    required this.uid,
    this.zoomFactor,
  });
}
