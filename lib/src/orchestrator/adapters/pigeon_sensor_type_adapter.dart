import 'package:camerawesome/pigeon.dart';
import 'package:camerawesome/src/orchestrator/models/sensor_type.dart';

extension SensorTypeExt on SensorType {
  PigeonSensorType toPigeon() {
    switch (this) {
      case SensorType.wideAngle:
        return PigeonSensorType.wideAngle;
      case SensorType.ultraWideAngle:
        return PigeonSensorType.ultraWideAngle;
      case SensorType.telephoto:
        return PigeonSensorType.telephoto;
      case SensorType.trueDepth:
        return PigeonSensorType.trueDepth;
      case SensorType.unknown:
      default:
        return PigeonSensorType.unknown;
    }
  }
}

extension PigeonSensorTypeExt on PigeonSensorType {
  SensorType toSensorType() {
    switch (this) {
      case PigeonSensorType.wideAngle:
        return SensorType.wideAngle;
      case PigeonSensorType.ultraWideAngle:
        return SensorType.ultraWideAngle;
      case PigeonSensorType.telephoto:
        return SensorType.telephoto;
      case PigeonSensorType.trueDepth:
        return SensorType.trueDepth;
      case PigeonSensorType.unknown:
      default:
        return SensorType.unknown;
    }
  }
}
