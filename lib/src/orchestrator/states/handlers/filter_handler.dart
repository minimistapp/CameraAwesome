import 'dart:io';
import 'dart:isolate';
import 'dart:typed_data';

import 'package:camerawesome/src/orchestrator/file/content/file_content.dart';
import 'package:image/image.dart' as img;
import 'package:camerawesome/camerawesome_plugin.dart';

class FilterHandler {
  Isolate? photoFilterIsolate;

  /// Whether [filter] has to be baked into the captured file by [apply].
  ///
  /// A preview-only filter (`bakeCaptures == false`, MIN-3655) is left to the
  /// caller to apply elsewhere: the bake is a full-resolution
  /// decode/apply/re-encode that runs between the shutter and
  /// `MediaCapture.success` and stalls the capture. [AwesomeFilter.None]
  /// never bakes. Platform-independent — [apply] only bakes on iOS, where
  /// nothing native does it (Android bakes in `CameraAwesomeX`).
  static bool shouldBake(AwesomeFilter filter) =>
      filter.bakeCaptures && filter.id != AwesomeFilter.None.id;

  Future<void> apply({
    required CaptureRequest captureRequest,
    required AwesomeFilter filter,
  }) async {
    if (Platform.isIOS && shouldBake(filter)) {
      photoFilterIsolate?.kill(priority: Isolate.immediate);

      ReceivePort port = ReceivePort();
      photoFilterIsolate = await Isolate.spawn<PhotoFilterModel>(
        applyFilter,
        PhotoFilterModel(captureRequest, filter.output),
        onExit: port.sendPort,
      );
      await port.first;

      photoFilterIsolate?.kill(priority: Isolate.immediate);
    }
  }
}

Future<CaptureRequest> applyFilter(PhotoFilterModel model) async {
  final files = model.captureRequest.when(
    single: (single) => [single.file],
    multiple: (multiple) => multiple.fileBySensor.values.toList(),
  );
  FileContent fileContent = FileContent();
  for (final f in files) {
    // f is expected to not be null since the picture should have already been taken
    final img.Image? image = img.decodeJpg((await fileContent.read(f!))!);
    if (image == null) {
      throw MediaCapture.failure(
        exception: Exception("could not decode image ${f.path}"),
        captureRequest: model.captureRequest,
      );
    }

    final pixels = image.getBytes();
    model.filter.apply(pixels, image.width, image.height);
    final img.Image out = img.Image.fromBytes(
      width: image.width,
      height: image.height,
      bytes: pixels.buffer,
    );
    // fromBytes builds a bare image — carry the source EXIF (orientation,
    // capture metadata) across the rebuild or the bake strips it.
    out.exif = image.exif;

    final List<int>? encodedImage = img.encodeNamedImage(f.path, out);
    if (encodedImage == null) {
      throw MediaCapture.failure(
        exception: Exception("could not encode image ${f.path}"),
        captureRequest: model.captureRequest,
      );
    }
    await fileContent.write(f, Uint8List.fromList(encodedImage));
  }
  return model.captureRequest;
}
