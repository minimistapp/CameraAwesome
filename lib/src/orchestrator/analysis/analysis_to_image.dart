import 'package:camerawesome/camerawesome_plugin.dart';
import 'package:flutter/material.dart';

class AnalysisPreview {
  final Size nativePreviewSize;
  final Size previewSize;
  final Offset offset;
  final double scale;
  final Sensor? sensor;

  AnalysisPreview({
    required this.nativePreviewSize,
    required this.previewSize,
    required this.offset,
    required this.scale,
    required this.sensor,
  });

  factory AnalysisPreview.hidden() => AnalysisPreview(
        nativePreviewSize: Size.zero,
        previewSize: Size.zero,
        offset: Offset.zero,
        scale: 1,
        sensor: null,
      );

  Offset convertPoint(Offset point) {
    return Offset(point.dx * scale, point.dy * scale).translate(offset.dx, offset.dy);
  }

  /// this method is used to convert a point from an image to the preview
  /// according to the current preview size and the image size
  /// also in case of Android, it will flip the point if required
  Offset convertFromImage(
    Offset point,
    AnalysisImage img, {
    bool? flipXY,
  }) {
    final shouldFlipXY = flipXY ?? img.flipXY();

    // Crop differences in image space (center crop)
    final imageDiffX = img.size.width - img.croppedSize.width;
    final imageDiffY = img.size.height - img.croppedSize.height;

    // Map incoming image-space point into the cropped sub-rectangle, applying rotation flip if needed
    final imageX = (shouldFlipXY ? point.dy : point.dx).toDouble() - imageDiffX / 2;
    final imageY = (shouldFlipXY ? point.dx : point.dy).toDouble() - imageDiffY / 2;

    // Normalize inside cropped image, then scale to preview native size
    final normX = imageX / img.croppedSize.width;
    final normY = imageY / img.croppedSize.height;

    final inNativePreviewX = normX * nativePreviewSize.width;
    final inNativePreviewY = normY * nativePreviewSize.height;

    // Apply AnimatedPreviewFit scale and offset to get screen-space coordinates
    return Offset(inNativePreviewX, inNativePreviewY) * scale + offset;
  }

  Rect get rect => Rect.fromCenter(
        center: previewSize.center(Offset.zero),
        width: previewSize.width,
        height: previewSize.height,
      );

  bool get isBackCamera => sensor?.position == SensorPosition.back;
}
