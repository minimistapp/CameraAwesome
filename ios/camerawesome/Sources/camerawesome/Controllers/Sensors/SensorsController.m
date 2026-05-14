//
//  SensorsController.m
//  camerawesome
//
//  Created by Dimitri Dessus on 28/03/2023.
//

#import "SensorsController.h"
#import "Pigeon.h"
#import <math.h>

@implementation SensorsController

+ (NSArray *)getSensors:(AVCaptureDevicePosition)position {
  NSMutableArray *sensors = [NSMutableArray new];

  NSArray *sensorsType = @[AVCaptureDeviceTypeBuiltInWideAngleCamera, AVCaptureDeviceTypeBuiltInTelephotoCamera, AVCaptureDeviceTypeBuiltInUltraWideCamera, AVCaptureDeviceTypeBuiltInTrueDepthCamera];

  AVCaptureDeviceDiscoverySession *discoverySession = [AVCaptureDeviceDiscoverySession
                                                       discoverySessionWithDeviceTypes:sensorsType
                                                       mediaType:AVMediaTypeVideo
                                                       position:AVCaptureDevicePositionUnspecified];

  // First pass: locate the wide-angle lens at the requested position so we can
  // express the others' native zoom factors relative to it.
  AVCaptureDevice *wideReference = nil;
  for (AVCaptureDevice *device in discoverySession.devices) {
    if (device.position == position && device.deviceType == AVCaptureDeviceTypeBuiltInWideAngleCamera) {
      wideReference = device;
      break;
    }
  }
  const float wideHalfFov = wideReference ? wideReference.activeFormat.videoFieldOfView * 0.5f : 0.0f;
  const float wideTanHalfFov = wideHalfFov > 0.0f ? tanf(wideHalfFov * (float)M_PI / 180.0f) : 0.0f;

  for (AVCaptureDevice *device in discoverySession.devices) {
    if (device.position != position) continue;

    PigeonSensorType type;
    if (device.deviceType == AVCaptureDeviceTypeBuiltInTelephotoCamera) {
      type = PigeonSensorTypeTelephoto;
    } else if (device.deviceType == AVCaptureDeviceTypeBuiltInUltraWideCamera) {
      type = PigeonSensorTypeUltraWideAngle;
    } else if (device.deviceType == AVCaptureDeviceTypeBuiltInTrueDepthCamera) {
      type = PigeonSensorTypeTrueDepth;
    } else if (device.deviceType == AVCaptureDeviceTypeBuiltInWideAngleCamera) {
      type = PigeonSensorTypeWideAngle;
    } else {
      type = PigeonSensorTypeUnknown;
    }

    NSNumber *nativeZoomFactor = nil;
    if (device == wideReference) {
      nativeZoomFactor = @(1.0);
    } else if (wideTanHalfFov > 0.0f) {
      const float sensorHalfFov = device.activeFormat.videoFieldOfView * 0.5f;
      const float sensorTanHalfFov = tanf(sensorHalfFov * (float)M_PI / 180.0f);
      if (sensorTanHalfFov > 0.0f) {
        // tan-based ratio is accurate across wide FOV deltas; the simple FOV
        // ratio diverges noticeably for ultra-wide.
        nativeZoomFactor = @(wideTanHalfFov / sensorTanHalfFov);
      }
    }

    PigeonSensorTypeDevice *sensorType = [PigeonSensorTypeDevice
                                          makeWithSensorType:type
                                          name:device.localizedName
                                          iso:[NSNumber numberWithFloat:device.ISO]
                                          flashAvailable:[NSNumber numberWithBool:device.flashAvailable]
                                          uid:device.uniqueID
                                          nativeZoomFactor:nativeZoomFactor];

    [sensors addObject:sensorType];
  }

  return sensors;
}

@end
