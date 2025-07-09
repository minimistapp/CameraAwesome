import 'dart:ui';

import 'package:camerawesome/src/orchestrator/adapters/pigeon_sensor_type_adapter.dart';
import 'package:camerawesome/src/orchestrator/models/sensor_data.dart';
import 'package:camerawesome/src/orchestrator/models/sensor_type.dart';
import 'package:camerawesome/src/orchestrator/pigeon/pigeon_generated.dart';

/// used to expose Brightness level
class SensorData {
  double value;

  SensorData(this.value);
}

class SensorDeviceDataInternal {
  /// A built-in wide-angle camera.
  ///
  /// The wide angle sensor is the default sensor for iOS
  SensorTypeDeviceInternal? wideAngle;

  /// A built-in camera with a shorter focal length than that of the wide-angle camera.
  SensorTypeDeviceInternal? ultraWideAngle;

  /// A built-in camera device with a longer focal length than the wide-angle camera.
  SensorTypeDeviceInternal? telephoto;

  /// A device that consists of two cameras, one Infrared and one YUV.
  ///
  /// iOS only
  SensorTypeDeviceInternal? trueDepth;

  SensorDeviceDataInternal({
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

class SensorTypeDeviceInternal {
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

  const SensorTypeDeviceInternal({
    required this.sensorType,
    required this.name,
    required this.iso,
    required this.flashAvailable,
    required this.uid,
    this.zoomFactor,
  });

  SensorTypeDeviceInternal.fromPigeon(PigeonSensorTypeDevice pigeon)
      : sensorType = pigeon.sensorType.toSensorType(),
        name = pigeon.name,
        iso = pigeon.iso,
        flashAvailable = pigeon.flashAvailable,
        uid = pigeon.uid,
        zoomFactor = pigeon.zoomFactor;
}

extension SensorDeviceDataMapper on SensorDeviceDataInternal {
  SensorDeviceData toPublic() {
    return SensorDeviceData(
      wideAngle: wideAngle?.toPublic(),
      ultraWideAngle: ultraWideAngle?.toPublic(),
      telephoto: telephoto?.toPublic(),
      trueDepth: trueDepth?.toPublic(),
    );
  }
}

extension SensorTypeDeviceMapper on SensorTypeDeviceInternal {
  SensorTypeDevice toPublic() {
    return SensorTypeDevice(
      sensorType: sensorType,
      name: name,
      iso: iso,
      flashAvailable: flashAvailable,
      uid: uid,
      zoomFactor: zoomFactor,
    );
  }
}
