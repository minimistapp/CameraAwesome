//
//  SensorUtils.m
//  camerawesome
//
//  Created by Dimitri Dessus on 30/03/2023.
//

#import "SensorUtils.h"
#import "../../Pigeon.h"

@implementation SensorUtils

+ (CAPigeonSensorType)sensorTypeFromDeviceType:(AVCaptureDeviceType)type {
  if (type == AVCaptureDeviceTypeBuiltInTelephotoCamera) {
    return CAPigeonSensorTypeTelephoto;
  } else if (type == AVCaptureDeviceTypeBuiltInUltraWideCamera) {
    return CAPigeonSensorTypeUltraWideAngle;
  } else if (type == AVCaptureDeviceTypeBuiltInTrueDepthCamera) {
    return CAPigeonSensorTypeTrueDepth;
  } else if (type == AVCaptureDeviceTypeBuiltInWideAngleCamera) {
    return CAPigeonSensorTypeWideAngle;
  } else {
    return CAPigeonSensorTypeUnknown;
  }
}

+ (AVCaptureDeviceType)deviceTypeFromSensorType:(CAPigeonSensorType)sensorType {
  if (sensorType == CAPigeonSensorTypeTelephoto) {
    return AVCaptureDeviceTypeBuiltInTelephotoCamera;
  } else if (sensorType == CAPigeonSensorTypeUltraWideAngle) {
    return AVCaptureDeviceTypeBuiltInUltraWideCamera;
  } else if (sensorType == CAPigeonSensorTypeTrueDepth) {
    return AVCaptureDeviceTypeBuiltInTrueDepthCamera;
  } else if (sensorType == CAPigeonSensorTypeWideAngle) {
    return AVCaptureDeviceTypeBuiltInWideAngleCamera;
  } else {
    return AVCaptureDeviceTypeBuiltInWideAngleCamera;
  }
}

@end
