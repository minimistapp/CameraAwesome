import 'package:camerawesome/camerawesome_plugin.dart';
import 'package:camerawesome/pigeon.dart';

enum CameraAspectRatios {
  ratio_16_9,
  ratio_4_3,
  ratio_1_1; // only for iOS

  CameraAspectRatios get defaultRatio => CameraAspectRatios.ratio_4_3;
}

enum SensorPosition {
  front,
  back,
  unknown,
}

extension SensorPositionExt on SensorPosition {
  PigeonSensorPosition toPigeon() {
    switch (this) {
      case SensorPosition.back:
        return PigeonSensorPosition.back;
      case SensorPosition.front:
        return PigeonSensorPosition.front;
      case SensorPosition.unknown:
      default:
        return PigeonSensorPosition.unknown;
    }
  }
}

extension PigeonSensorPositionExt on PigeonSensorPosition {
  SensorPosition toSensorPosition() {
    switch (this) {
      case PigeonSensorPosition.back:
        return SensorPosition.back;
      case PigeonSensorPosition.front:
        return SensorPosition.front;
      case PigeonSensorPosition.unknown:
      default:
        return SensorPosition.unknown;
    }
  }
}

class Sensor {
  SensorPosition? position;
  SensorType? type;
  String? deviceId;

  Sensor._({
    this.position,
    this.type,
    this.deviceId,
  });

  Sensor.position(SensorPosition position)
      : this._(
          position: position,
        );

  Sensor.type(SensorType type)
      : this._(
          type: type,
        );

  Sensor.id(String deviceId)
      : this._(
          deviceId: deviceId,
        );
}
