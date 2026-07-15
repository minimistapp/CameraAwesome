//
//  ImageStreamController.h
//  camerawesome
//
//  Created by Dimitri Dessus on 17/12/2020.
//

#import <Flutter/Flutter.h>
#import <Foundation/Foundation.h>
#import <AVFoundation/AVFoundation.h>
#import "InputImageRotation.h"

NS_ASSUME_NONNULL_BEGIN

@interface ImageStreamController : NSObject

@property(readonly, nonatomic) bool streamImages;
@property(readonly, nonatomic) float maxFramesPerSecond;
/// Thermal ceiling on the emitted analysis rate (MIN-3056). 0 = no ceiling.
/// Combined with [maxFramesPerSecond] by taking the lower of the two; when
/// [maxFramesPerSecond] is 0/unset the ceiling applies alone. Set by
/// SingleCameraPreview's thermal governor.
@property(nonatomic, assign) float thermalMaxFramesPerSecond;
@property(readonly, nonatomic) NSDate *latestEmittedFrame;
@property(nonatomic) FlutterEventSink imageStreamEventSink;

@property(readonly, nonatomic) NSInteger processingImage;

- (instancetype)initWithStreamImages:(bool)streamImages;
- (void)captureOutput:(AVCaptureOutput *)output didOutputSampleBuffer:(CMSampleBufferRef)sampleBuffer fromConnection:(AVCaptureConnection *)connection orientation:(UIDeviceOrientation)orientation;
- (void)setImageStreamEventSink:(FlutterEventSink)imageStreamEventSink;
- (void)setStreamImages:(bool)streamImages;
- (void)receivedImageFromStream;
- (void)setMaxFramesPerSecond:(float)maxFramesPerSecond;

@end

NS_ASSUME_NONNULL_END
