//
//  ThermalController.m
//  camerawesome
//
//  Created for MIN-3056 (iOS thermal governor).
//

#import "ThermalController.h"

// KVO context for observing the bound capture device's systemPressureState —
// same static-context pattern as FocusStableContext in SingleCameraPreview.m
// so we never intercept (or forward) someone else's observation.
static void * const ThermalPressureContext = (void *)&ThermalPressureContext;

NSString *CameraThermalLevelString(CameraThermalLevel level) {
  switch (level) {
    case CameraThermalLevelFair:
      return @"fair";
    case CameraThermalLevelSerious:
      return @"serious";
    case CameraThermalLevelCritical:
      return @"critical";
    case CameraThermalLevelShutdown:
      return @"shutdown";
    case CameraThermalLevelNominal:
      return @"nominal";
  }
  return @"nominal";
}

@interface ThermalController ()
@property(nonatomic, assign, readwrite) CameraThermalLevel currentLevel;
@end

@implementation ThermalController {
  AVCaptureDevice *_boundDevice;
  BOOL _observingPressure;
  BOOL _started;
}

- (void)start {
  if (_started) {
    return;
  }
  _started = YES;
  // Selector-based observation: NSNotificationCenter does NOT strongly retain
  // the observer, so this cannot create a retain cycle (the MIN-2747
  // motion-controller lesson — its block-based CoreMotion handler did retain
  // its controller and leaked a permanent gyro subscription).
  [[NSNotificationCenter defaultCenter] addObserver:self
                                           selector:@selector(thermalStateDidChange:)
                                               name:NSProcessInfoThermalStateDidChangeNotification
                                             object:nil];
  // Initial reading so consumers start from the real state, not nominal.
  [self recomputeLevel];
}

- (void)stop {
  if (_started) {
    _started = NO;
    [[NSNotificationCenter defaultCenter] removeObserver:self
                                                    name:NSProcessInfoThermalStateDidChangeNotification
                                                  object:nil];
  }
  [self unbindCaptureDevice];
}

- (void)bindToCaptureDevice:(nullable AVCaptureDevice *)device {
  // Unbind-before-rebind so a sensor switch can never leave a KVO
  // registration dangling on the outgoing device.
  [self unbindCaptureDevice];
  if (device == nil) {
    [self recomputeLevel];
    return;
  }
  _boundDevice = device;
  _observingPressure = YES;
  // KVO does not retain the observer; teardown is guarded in
  // unbindCaptureDevice (same @try pattern as the focus-stable observation).
  [device addObserver:self
           forKeyPath:@"systemPressureState"
              options:0
              context:ThermalPressureContext];
  [self recomputeLevel];
}

- (void)unbindCaptureDevice {
  if (_observingPressure) {
    _observingPressure = NO;
    @try {
      [_boundDevice removeObserver:self forKeyPath:@"systemPressureState" context:ThermalPressureContext];
    } @catch (NSException *exception) { /* already removed */ }
  }
  _boundDevice = nil;
}

- (void)dealloc {
  // Defensive teardown only — stop, never start, from dealloc (MIN-2747).
  [self stop];
}

- (void)observeValueForKeyPath:(NSString *)keyPath
                      ofObject:(id)object
                        change:(NSDictionary<NSKeyValueChangeKey, id> *)change
                       context:(void *)context {
  if (context != ThermalPressureContext) {
    [super observeValueForKeyPath:keyPath ofObject:object change:change context:context];
    return;
  }
  // Arrives on an arbitrary AVFoundation thread — recompute inline; the
  // consumer hops onto its own queue inside onThermalLevelChanged.
  [self recomputeLevel];
}

- (void)thermalStateDidChange:(NSNotification *)notification {
  [self recomputeLevel];
}

#pragma mark - Level computation

/// Recompute the effective level from both inputs and fire the callback only
/// on an actual change. Serialized under @synchronized because the two inputs
/// report on unrelated threads.
- (void)recomputeLevel {
  CameraThermalLevel newLevel = [self computeEffectiveLevel];
  BOOL changed = NO;
  @synchronized(self) {
    if (newLevel != _currentLevel) {
      _currentLevel = newLevel;
      changed = YES;
    }
  }
  if (changed) {
    void (^callback)(CameraThermalLevel) = self.onThermalLevelChanged;
    if (callback != nil) {
      callback(newLevel);
    }
  }
}

- (CameraThermalLevel)computeEffectiveLevel {
  NSInteger processLevel = CameraThermalLevelNominal;
  switch (NSProcessInfo.processInfo.thermalState) {
    case NSProcessInfoThermalStateNominal:
      processLevel = CameraThermalLevelNominal;
      break;
    case NSProcessInfoThermalStateFair:
      processLevel = CameraThermalLevelFair;
      break;
    case NSProcessInfoThermalStateSerious:
      processLevel = CameraThermalLevelSerious;
      break;
    case NSProcessInfoThermalStateCritical:
      processLevel = CameraThermalLevelCritical;
      break;
  }

  NSInteger pressureLevel = CameraThermalLevelNominal;
  AVCaptureDevice *device = _boundDevice;
  if (device != nil) {
    AVCaptureSystemPressureLevel level = device.systemPressureState.level;
    if ([level isEqualToString:AVCaptureSystemPressureLevelFair]) {
      pressureLevel = CameraThermalLevelFair;
    } else if ([level isEqualToString:AVCaptureSystemPressureLevelSerious]) {
      pressureLevel = CameraThermalLevelSerious;
    } else if ([level isEqualToString:AVCaptureSystemPressureLevelCritical]) {
      pressureLevel = CameraThermalLevelCritical;
    } else if ([level isEqualToString:AVCaptureSystemPressureLevelShutdown]) {
      pressureLevel = CameraThermalLevelShutdown;
    }
  }

  return (CameraThermalLevel)MAX(processLevel, pressureLevel);
}

@end
