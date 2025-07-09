import 'package:camerawesome/camerawesome_plugin.dart';
import 'package:camerawesome/src/orchestrator/file/builder/capture_request_builder.dart';
import 'package:camerawesome/src/orchestrator/pigeon/pigeon_generated.dart' as pigeon;

typedef CaptureRequestBuilder = Future<CaptureRequest> Function(List<Sensor> sensors);

class SaveConfig {
  final CaptureRequestBuilder? photoPathBuilder;
  final CaptureRequestBuilder? videoPathBuilder;
  final List<CaptureMode> captureModes;
  final CaptureMode initialCaptureMode;
  final pigeon.VideoOptions? videoOptions;
  final bool mirrorFrontCamera;

  /// Choose if you want to persist user location in image metadata or not
  final pigeon.ExifPreferences? exifPreferences;

  SaveConfig._({
    this.photoPathBuilder,
    this.videoPathBuilder,
    required this.captureModes,
    required this.initialCaptureMode,
    this.videoOptions,
    this.exifPreferences,
    required this.mirrorFrontCamera,
  });

  /// You only want to take photos
  SaveConfig.photo({
    CaptureRequestBuilder? pathBuilder,
    pigeon.ExifPreferences? exifPreferences,
    bool mirrorFrontCamera = false,
  }) : this._(
          photoPathBuilder:
              pathBuilder ?? (sensors) => AwesomeCaptureRequestBuilder().build(captureMode: CaptureMode.photo, sensors: sensors),
          captureModes: [CaptureMode.photo],
          initialCaptureMode: CaptureMode.photo,
          exifPreferences: exifPreferences,
          mirrorFrontCamera: mirrorFrontCamera,
        );

  /// You only want to take videos
  SaveConfig.video({
    CaptureRequestBuilder? pathBuilder,
    pigeon.VideoOptions? videoOptions,
    bool mirrorFrontCamera = false,
  }) : this._(
          videoPathBuilder:
              pathBuilder ?? (sensors) => AwesomeCaptureRequestBuilder().build(captureMode: CaptureMode.video, sensors: sensors),
          captureModes: [CaptureMode.video],
          initialCaptureMode: CaptureMode.video,
          videoOptions: videoOptions,
          mirrorFrontCamera: mirrorFrontCamera,
        );

  /// You want to be able to take both photos and videos
  SaveConfig.photoAndVideo({
    CaptureRequestBuilder? photoPathBuilder,
    CaptureRequestBuilder? videoPathBuilder,
    CaptureMode initialCaptureMode = CaptureMode.photo,
    pigeon.VideoOptions? videoOptions,
    pigeon.ExifPreferences? exifPreferences,
    bool mirrorFrontCamera = false,
  }) : this._(
          photoPathBuilder:
              photoPathBuilder ?? (sensors) => AwesomeCaptureRequestBuilder().build(captureMode: CaptureMode.photo, sensors: sensors),
          videoPathBuilder:
              videoPathBuilder ?? (sensors) => AwesomeCaptureRequestBuilder().build(captureMode: CaptureMode.video, sensors: sensors),
          captureModes: [CaptureMode.photo, CaptureMode.video],
          initialCaptureMode: initialCaptureMode,
          videoOptions: videoOptions,
          exifPreferences: exifPreferences,
          mirrorFrontCamera: mirrorFrontCamera,
        );
}
