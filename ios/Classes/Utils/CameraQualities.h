#import <AVFoundation/AVFoundation.h>
#import <CoreGraphics/CoreGraphics.h>
#import <Foundation/Foundation.h>
#import "Pigeon.h"

@interface CameraQualities : NSObject

+ (AVCaptureSessionPreset)selectVideoCapturePreset:(CGSize)size
                                            session:(AVCaptureSession *)session
                                             device:(AVCaptureDevice *)device;

+ (NSString *)selectVideoCapturePreset:(AVCaptureSession *)session
                                device:(AVCaptureDevice *)device;

+ (CGSize)getSizeForPreset:(NSString *)preset;

+ (AVCaptureSessionPreset)computeBestPresetWithSession:(AVCaptureSession *)session
                                                 device:(AVCaptureDevice *)device;

+ (NSString *)selectPresetForSize:(CGSize)size
                          session:(AVCaptureSession *)session;

+ (NSArray<CAPreviewSize *> *)captureFormatsForDevice:(AVCaptureDevice *)device;

@end 