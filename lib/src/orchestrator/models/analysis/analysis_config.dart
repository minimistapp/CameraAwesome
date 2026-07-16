import 'package:camerawesome/camerawesome_plugin.dart';

class AnalysisConfig {
  /// This is used to improve performance on low performance devices.
  /// It will skip frames if the camera is producing more than the specified.
  ///
  /// For exemple, if the camera is producing 30fps and you set this to 10, it will skip 20 frames.
  ///
  /// Default is null (disabled).
  final double? maxFramesPerSecond;

  /// When set to true, image analysis starts automatically. Otherwise, you will
  /// have to start it manually using [AnalysisController.start()]
  final bool autoStart;

  /// Android specific options for image analysis.
  final AndroidAnalysisOptions androidOptions;

  /// iOS specific options for image analysis.
  final CupertinoAnalysisOptions cupertinoOptions;

  AnalysisConfig({
    this.maxFramesPerSecond,
    this.autoStart = true,
    this.androidOptions = const AndroidAnalysisOptions.nv21(width: 500),
    this.cupertinoOptions = const CupertinoAnalysisOptions.bgra8888(),
  });
}

class AndroidAnalysisOptions {
  /// Image analysis format.
  /// Recommended format for image analysis on Android is nv21.
  final InputAnalysisImageFormat outputFormat;

  /// `Target width of you image analysis. CamerAwesome will try to find the
  /// closest resolution to this [width].
  /// The smaller the image, the faster the analysis will be. 500 is often enough
  /// to detect barcodes or faces for example.
  final int width;

  const AndroidAnalysisOptions._({
    this.outputFormat = InputAnalysisImageFormat.nv21,
    this.width = 500,
  });

  const AndroidAnalysisOptions.nv21({
    required int width,
  }) : this._(
          width: width,
          outputFormat: InputAnalysisImageFormat.nv21,
        );

  const AndroidAnalysisOptions.yuv420({
    required int width,
  }) : this._(
          width: width,
          outputFormat: InputAnalysisImageFormat.yuv_420,
        );

  const AndroidAnalysisOptions.bgra8888({
    required int width,
  }) : this._(
          width: width,
          outputFormat: InputAnalysisImageFormat.bgra8888,
        );

  const AndroidAnalysisOptions.jpeg({
    required int width,
  }) : this._(width: width, outputFormat: InputAnalysisImageFormat.jpeg);
}

class CupertinoAnalysisOptions {
  /// Image analysis format.
  /// Recommended format for image analysis on iOS is bgra8888.
  final InputAnalysisImageFormat outputFormat;

  const CupertinoAnalysisOptions._({
    required this.outputFormat,
  });

  const CupertinoAnalysisOptions.bgra8888()
      : this._(outputFormat: InputAnalysisImageFormat.bgra8888);

  /// Luma-only analysis frames (MIN-3084): the native side switches the data
  /// output to biplanar YUV (420f full-range, falling back to 420v video-range
  /// whose luma is 16–235 rather than 0–255) and ships just the Y plane, in
  /// the same nv21-shaped payload Android emits — ~4x less bridge transfer
  /// than bgra8888 and no color conversion for grayscale consumers.
  ///
  /// Caveats:
  /// - [Nv21Image.bytes] holds ONLY the Y plane (`width * height` bytes),
  ///   not Android's full `1.5 * width * height` NV21 buffer, and the planes
  ///   list carries dimensions only (empty bytes).
  /// - Never feed this stream to MLKit on iOS — it expects bgra8888 there.
  /// - Frames are not guaranteed to be [Nv21Image]: while video recording is
  ///   running they temporarily arrive as bgra8888 (the recording pipeline
  ///   requires it), and on a device where neither 420f nor 420v is available
  ///   every frame stays bgra8888. Consumers must handle both [AnalysisImage]
  ///   variants per frame — dispatch with `when(nv21: ..., bgra8888: ...)`,
  ///   never cast.
  const CupertinoAnalysisOptions.nv21()
      : this._(outputFormat: InputAnalysisImageFormat.nv21);
}
