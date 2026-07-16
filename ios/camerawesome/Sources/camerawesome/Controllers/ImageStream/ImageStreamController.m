//
//  ImageStreamController.m
//  camerawesome
//
//  Created by Dimitri Dessus on 17/12/2020.
//

#import "ImageStreamController.h"

#import <os/lock.h>

@implementation ImageStreamController {
  // _processingImage is a read-modify-write counter touched from the capture
  // queue (increment, copy-failure drop) and the main thread (Dart ack, sink
  // drops); an unsynchronized RMW can lose a decrement and ratchet
  // overflowCrashingGuard into skipping every frame.
  os_unfair_lock _processingImageLock;
}

NSInteger const MaxPendingProcessedImage = 4;

- (instancetype)initWithStreamImages:(bool)streamImages {
  self = [super init];
  _streamImages = streamImages;
  _processingImage = 0;
  _processingImageLock = OS_UNFAIR_LOCK_INIT;
  return self;
}

# pragma mark - Camera Delegates
- (void)captureOutput:(AVCaptureOutput *)output didOutputSampleBuffer:(CMSampleBufferRef)sampleBuffer fromConnection:(AVCaptureConnection *)connection orientation:(UIDeviceOrientation)orientation {
  if (_imageStreamEventSink == nil) {
    return;
  }

  bool shouldFPSGuard = [self fpsGuard];
  bool shouldOverflowCrashingGuard = [self overflowCrashingGuard];

  if (shouldFPSGuard || shouldOverflowCrashingGuard) {
    return;
  }

  os_unfair_lock_lock(&_processingImageLock);
  _processingImage++;
  os_unfair_lock_unlock(&_processingImageLock);

  CVPixelBufferRef pixelBuffer = CMSampleBufferGetImageBuffer(sampleBuffer);
  CVPixelBufferLockBaseAddress(pixelBuffer, kCVPixelBufferLock_ReadOnly);

  // Emit the dict shape matching the buffer actually delivered: the analysis
  // output is 32BGRA historically, or biplanar YUV when the stream requested
  // nv21 (MIN-3084) — then only the tightly-packed luma (Y) plane crosses the
  // bridge, in the exact shape Android's nv21 emit uses, so the Dart side
  // reuses its existing Nv21Image path unchanged.
  const OSType pixelFormat = CVPixelBufferGetPixelFormatType(pixelBuffer);
  NSDictionary *imageBuffer;
  if (pixelFormat == kCVPixelFormatType_420YpCbCr8BiPlanarFullRange ||
      pixelFormat == kCVPixelFormatType_420YpCbCr8BiPlanarVideoRange) {
    imageBuffer = [self lumaImageBufferFrom:pixelBuffer orientation:orientation];
  } else {
    imageBuffer = [self bgraImageBufferFrom:pixelBuffer orientation:orientation];
  }

  CVPixelBufferUnlockBaseAddress(pixelBuffer, kCVPixelBufferLock_ReadOnly);

  if (imageBuffer == nil) {
    [self droppedFrameFromStream];
    return;
  }

  dispatch_async(dispatch_get_main_queue(), ^{
    // The sink is nilled on the main thread when Dart cancels the stream
    // (screen close / scanner dismiss) — a frame dispatched before the cancel
    // would invoke a nil block and crash (MIN-3074). The setter and this block
    // both run on the main thread, so the snapshot + check is race-free.
    FlutterEventSink sink = self->_imageStreamEventSink;
    if (sink == nil) {
      [self droppedFrameFromStream];
      return;
    }
    // Encoding the event envelope re-allocates the frame inside the standard
    // codec; under the same memory pressure as the plane copy that throws
    // NSMallocException too — drop the frame rather than abort (MIN-3075).
    @try {
      sink(imageBuffer);
    } @catch (NSException *exception) {
      [self droppedFrameFromStream];
    }
  });

}

/// The historical whole-buffer emit: every plane copied verbatim (stride
/// padding included), format hardcoded to what the 32BGRA output delivers.
/// Expects the buffer's base addresses to be locked by the caller. Returns nil
/// when the plane copy failed so the caller drops the frame (MIN-3075).
- (nullable NSDictionary *)bgraImageBufferFrom:(CVPixelBufferRef)pixelBuffer orientation:(UIDeviceOrientation)orientation {
  size_t imageWidth = CVPixelBufferGetWidth(pixelBuffer);
  size_t imageHeight = CVPixelBufferGetHeight(pixelBuffer);

  NSMutableArray *planes = [NSMutableArray array];

  const Boolean isPlanar = CVPixelBufferIsPlanar(pixelBuffer);
  size_t planeCount;
  if (isPlanar) {
    planeCount = CVPixelBufferGetPlaneCount(pixelBuffer);
  } else {
    planeCount = 1;
  }

  // Copying the planes allocates frame-sized NSData buffers; near the memory
  // ceiling that throws NSMallocException (prod crashes on 1.7.30/1.7.31). A
  // stream frame is droppable — skip it instead of letting the exception
  // abort the app (MIN-3075).
  @try {
    for (int i = 0; i < planeCount; i++) {
      void *planeAddress;
      size_t bytesPerRow;
      size_t height;
      size_t width;

      if (isPlanar) {
        planeAddress = CVPixelBufferGetBaseAddressOfPlane(pixelBuffer, i);
        bytesPerRow = CVPixelBufferGetBytesPerRowOfPlane(pixelBuffer, i);
        height = CVPixelBufferGetHeightOfPlane(pixelBuffer, i);
        width = CVPixelBufferGetWidthOfPlane(pixelBuffer, i);
      } else {
        planeAddress = CVPixelBufferGetBaseAddress(pixelBuffer);
        bytesPerRow = CVPixelBufferGetBytesPerRow(pixelBuffer);
        height = CVPixelBufferGetHeight(pixelBuffer);
        width = CVPixelBufferGetWidth(pixelBuffer);
      }

      NSNumber *length = @(bytesPerRow * height);
      NSData *bytes = [NSData dataWithBytes:planeAddress length:length.unsignedIntegerValue];

      [planes addObject:@{
        @"bytesPerRow": @(bytesPerRow),
        @"width": @(width),
        @"height": @(height),
        @"bytes": [FlutterStandardTypedData typedDataWithBytes:bytes],
      }];
    }
  } @catch (NSException *exception) {
    return nil;
  }

  return @{
    @"width": [NSNumber numberWithUnsignedLong:imageWidth],
    @"height": [NSNumber numberWithUnsignedLong:imageHeight],
    @"format": @"bgra8888",
    @"planes": planes,
    @"rotation": [self getInputImageOrientation:orientation]
  };
}

/// The luma-only emit for biplanar YUV buffers (MIN-3084): ships plane 0 (Y),
/// tightly packed (stride padding stripped — the Dart consumers assume
/// nv21Image.length == width*height and never apply a row stride), in the
/// Android nv21 dict shape that Nv21Image.from requires: nv21Image + LTRB
/// cropRect + planes + rotation. The single planes entry carries dimensions
/// only (empty bytes) — no iOS consumer reads nv21 plane bytes, and skipping
/// the duplicate copy is the point of this path (the Y payload would otherwise
/// be serialized twice). The CbCr plane never leaves the native side.
/// Expects the buffer's base addresses to be locked by the caller. Returns nil
/// when the copy failed so the caller drops the frame (MIN-3075).
- (nullable NSDictionary *)lumaImageBufferFrom:(CVPixelBufferRef)pixelBuffer orientation:(UIDeviceOrientation)orientation {
  const size_t width = CVPixelBufferGetWidthOfPlane(pixelBuffer, 0);
  const size_t height = CVPixelBufferGetHeightOfPlane(pixelBuffer, 0);
  const size_t bytesPerRow = CVPixelBufferGetBytesPerRowOfPlane(pixelBuffer, 0);
  const uint8_t *baseAddress = CVPixelBufferGetBaseAddressOfPlane(pixelBuffer, 0);
  if (baseAddress == NULL || width == 0 || height == 0 || bytesPerRow < width) {
    return nil;
  }

  // Same allocation-failure stance as the BGRA plane copy (MIN-3075).
  NSData *luma = nil;
  @try {
    if (bytesPerRow == width) {
      luma = [NSData dataWithBytes:baseAddress length:width * height];
    } else {
      NSMutableData *packed = [NSMutableData dataWithLength:width * height];
      if (packed == nil) {
        return nil;
      }
      uint8_t *dst = packed.mutableBytes;
      for (size_t row = 0; row < height; row++) {
        memcpy(dst + row * width, baseAddress + row * bytesPerRow, width);
      }
      luma = packed;
    }
  } @catch (NSException *exception) {
    return nil;
  }
  if (luma == nil) {
    return nil;
  }

  return @{
    @"width": [NSNumber numberWithUnsignedLong:width],
    @"height": [NSNumber numberWithUnsignedLong:height],
    @"format": @"nv21",
    @"nv21Image": [FlutterStandardTypedData typedDataWithBytes:luma],
    @"planes": @[
      @{
        @"bytesPerRow": [NSNumber numberWithUnsignedLong:width],
        @"width": [NSNumber numberWithUnsignedLong:width],
        @"height": [NSNumber numberWithUnsignedLong:height],
        @"bytes": [FlutterStandardTypedData typedDataWithBytes:[NSData data]],
      },
    ],
    @"rotation": [self getInputImageOrientation:orientation],
    @"cropRect": @{
      @"left": @0,
      @"top": @0,
      @"right": [NSNumber numberWithUnsignedLong:width],
      @"bottom": [NSNumber numberWithUnsignedLong:height],
    },
  };
}

- (NSString *)getInputImageOrientation:(UIDeviceOrientation)orientation {
  switch (orientation) {
    case UIDeviceOrientationLandscapeLeft:
      return @"rotation90deg";
    case UIDeviceOrientationLandscapeRight:
      return @"rotation270deg";
    case UIDeviceOrientationPortrait:
      return @"rotation0deg";
    case UIDeviceOrientationPortraitUpsideDown:
      return @"rotation180deg";
    default:
      return @"rotation0deg";
  }
}

#pragma mark - Guards

- (bool)fpsGuard {
  // calculate time interval between latest emitted frame
  NSDate *nowDate = [NSDate date];
  NSTimeInterval secondsBetween = [nowDate timeIntervalSinceDate:_latestEmittedFrame];

  // fps limit check, ignored if == 0
  if (_maxFramesPerSecond > 0) {
    if (secondsBetween <= (1 / _maxFramesPerSecond)) {
      // skip image because out of time
      return YES;
    }
  }

  return NO;
}

- (bool)overflowCrashingGuard {
  os_unfair_lock_lock(&_processingImageLock);
  NSInteger pending = _processingImage;
  os_unfair_lock_unlock(&_processingImageLock);

  // overflow crash prevent condition
  if (pending > MaxPendingProcessedImage) {
    // too many frame are pending processing, skipping...
    // this prevent crashing on older phones like iPhone 6, 7...
    return YES;
  }

  return NO;
}

// A frame that never reaches Dart never gets the receivedImageFromStream ack —
// rebalance the pending counter so dropped frames can't ratchet the stream into
// a permanent overflowCrashingGuard skip.
- (void)droppedFrameFromStream {
  os_unfair_lock_lock(&_processingImageLock);
  if (_processingImage > 0) {
    _processingImage--;
  }
  os_unfair_lock_unlock(&_processingImageLock);
}

// This is used to know the exact time when the image was received on the Flutter part
- (void)receivedImageFromStream {
  // used for the fps limit condition
  _latestEmittedFrame = [NSDate date];
  
  // used for the overflow prevent crashing condition
  os_unfair_lock_lock(&_processingImageLock);
  if (_processingImage >= 0) {
    _processingImage--;
  }
  os_unfair_lock_unlock(&_processingImageLock);
}

#pragma mark - Setters

- (void)setImageStreamEventSink:(FlutterEventSink)imageStreamEventSink {
  _imageStreamEventSink = imageStreamEventSink;
}

- (void)setMaxFramesPerSecond:(float)maxFramesPerSecond {
  _maxFramesPerSecond = maxFramesPerSecond;
}

- (void)setStreamImages:(bool)streamImages {
  _streamImages = streamImages;
}

@end
