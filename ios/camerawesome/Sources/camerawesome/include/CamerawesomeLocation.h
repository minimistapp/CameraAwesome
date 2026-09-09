//
//  CamerawesomeLocation.h
//  camerawesome
//
//  Build-time switch for the GPS-in-EXIF feature.
//

#ifndef CamerawesomeLocation_h
#define CamerawesomeLocation_h

// Writing GPS into a capture's EXIF is compiled OUT by default.
//
// App Store Connect scans the linked binary for the CoreLocation
// authorization APIs, not for whether they can actually be reached. Any
// reference to them makes an upload fail validation with ITMS-90683 unless
// Info.plist also carries NSLocationWhenInUseUsageDescription (and
// NSLocationAlwaysAndWhenInUseUsageDescription). A host app that never sets
// ExifPreferences.saveGPSLocation would otherwise have to ship two purpose
// strings promising a use of location it does not have.
//
// With the feature off, LocationController still exists and keeps its API:
// requestLocationAuthorizationOnGranted:declined: simply reports "declined"
// without touching CoreLocation, which every call site already handles by
// leaving saveGPSLocation false.
//
// To build it back in, define CAMERAWESOME_ENABLE_LOCATION=1 in the host
// app's GCC_PREPROCESSOR_DEFINITIONS and add the purpose strings.
#ifndef CAMERAWESOME_ENABLE_LOCATION
#define CAMERAWESOME_ENABLE_LOCATION 0
#endif

#endif /* CamerawesomeLocation_h */
