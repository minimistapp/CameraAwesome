//
//  SensorsController.m
//  camerawesome
//
//  Created by Dimitri Dessus on 28/03/2023.
//

#import "SensorsController.h"
#import "Pigeon.h"

@implementation SensorsController

+ (NSArray *)getSensors:(AVCaptureDevicePosition)position {
  NSMutableArray *sensors = [NSMutableArray new];
  
  NSArray *sensorsType = @[AVCaptureDeviceTypeBuiltInWideAngleCamera, AVCaptureDeviceTypeBuiltInTelephotoCamera, AVCaptureDeviceTypeBuiltInUltraWideCamera, AVCaptureDeviceTypeBuiltInTrueDepthCamera];
  
  AVCaptureDeviceDiscoverySession *discoverySession = [AVCaptureDeviceDiscoverySession
                                                       discoverySessionWithDeviceTypes:sensorsType
                                                       mediaType:AVMediaTypeVideo
                                                       position:AVCaptureDevicePositionUnspecified];
  
  for (AVCaptureDevice *device in discoverySession.devices) {
    PigeonSensorType type;
    double zoomFactor = 1.0;
    if (device.deviceType == AVCaptureDeviceTypeBuiltInTelephotoCamera) {
      type = PigeonSensorTypeTelephoto;
      zoomFactor = 2.0;
    } else if (device.deviceType == AVCaptureDeviceTypeBuiltInUltraWideCamera) {
      type = PigeonSensorTypeUltraWideAngle;
      zoomFactor = 0.5;
    } else if (device.deviceType == AVCaptureDeviceTypeBuiltInTrueDepthCamera) {
      type = PigeonSensorTypeTrueDepth;
    } else if (device.deviceType == AVCaptureDeviceTypeBuiltInWideAngleCamera) {
      type = PigeonSensorTypeWideAngle;
    } else {
      type = PigeonSensorTypeUnknown;
    }
    
    PigeonSensorTypeDevice *sensorType = [PigeonSensorTypeDevice makeWithSensorType:type name:device.localizedName iso:device.ISO flashAvailable:device.flashAvailable uid:device.uniqueID zoomFactor:@(zoomFactor)];
    
    if (device.position == position) {
      [sensors addObject:sensorType];
    }
  }
  
  return sensors;
}

@end
