//
//  ThermalController.h
//  camerawesome
//
//  Created for MIN-3056 (iOS thermal governor).
//

#import <Foundation/Foundation.h>
#import <AVFoundation/AVFoundation.h>

NS_ASSUME_NONNULL_BEGIN

/// Effective thermal level of the device, combining the OS-wide
/// NSProcessInfo.thermalState with the bound capture device's
/// AVCaptureSystemPressureState (which reacts faster and knows about
/// camera-specific pressure, e.g. "shutdown" when the camera hardware is about
/// to be turned off). The effective level is the max of the two.
typedef NS_ENUM(NSInteger, CameraThermalLevel) {
  CameraThermalLevelNominal = 0,
  CameraThermalLevelFair = 1,
  CameraThermalLevelSerious = 2,
  CameraThermalLevelCritical = 3,
  CameraThermalLevelShutdown = 4,
};

/// Lowercase wire string for a level:
/// "nominal" | "fair" | "serious" | "critical" | "shutdown".
NSString *CameraThermalLevelString(CameraThermalLevel level);

/// Watches the two thermal inputs and reports the *effective* level (their
/// max) whenever it changes. The onThermalLevelChanged callback may be invoked
/// inline on an arbitrary thread (NSNotificationCenter / AVFoundation KVO
/// threads) — the consumer is responsible for hopping onto its own queue.
@interface ThermalController : NSObject

/// Invoked only when the effective level actually changed. May fire on an
/// arbitrary thread; see class comment.
@property(nonatomic, copy, nullable) void (^onThermalLevelChanged)(CameraThermalLevel level);
@property(nonatomic, assign, readonly) CameraThermalLevel currentLevel;

/// Subscribe to NSProcessInfoThermalStateDidChangeNotification and take an
/// initial reading. Idempotent.
- (void)start;
/// KVO the device's systemPressureState. Any previously bound device is
/// unbound first. Passing nil is equivalent to unbindCaptureDevice.
- (void)bindToCaptureDevice:(nullable AVCaptureDevice *)device;
- (void)unbindCaptureDevice;
/// Remove the notification observer and unbind the device. Safe to call from
/// dealloc (never starts anything).
- (void)stop;

@end

NS_ASSUME_NONNULL_END
