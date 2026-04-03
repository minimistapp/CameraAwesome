//
//  SensorsController.h
//  camerawesome
//
//  Created by Dimitri Dessus on 28/03/2023.
//

#import <Foundation/Foundation.h>
#import <AVFoundation/AVFoundation.h>

NS_ASSUME_NONNULL_BEGIN

@interface SensorsController : NSObject

+ (NSArray *)getSensors:(AVCaptureDevicePosition)position;
+ (NSArray *)getExternalSensors;

@end

NS_ASSUME_NONNULL_END
