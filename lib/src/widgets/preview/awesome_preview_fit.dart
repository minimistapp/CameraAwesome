import 'dart:math';

import 'package:camerawesome/camerawesome_plugin.dart';
import 'package:camerawesome/pigeon.dart';
import 'package:flutter/material.dart';

final previewWidgetKey = GlobalKey();

typedef OnPreviewCalculated = void Function(AnalysisPreview preview);

/// The centred region of a preview [frame] that a [ratio] capture keeps — the
/// same crop the still gets natively (iOS CameraPictureController
/// -cropRectForWidth:): 16:9 trims the frame's short side, 1:1 its long side,
/// and 4:3 — the sensor's own shape — nothing. A frame already in [ratio]'s
/// shape (Android binds 16:9 natively) comes back whole.
Size captureCropSize(Size frame, CameraAspectRatios? ratio) {
  if (ratio == null || frame.isEmpty) {
    return frame;
  }
  final target = switch (ratio) {
    CameraAspectRatios.ratio_16_9 => 16 / 9,
    CameraAspectRatios.ratio_4_3 => 4 / 3,
    CameraAspectRatios.ratio_1_1 => 1.0,
  };
  final long = max(frame.width, frame.height);
  final short = min(frame.width, frame.height);
  final cropLong = min(long, short * target);
  final cropShort = min(short, long / target);
  return frame.width >= frame.height ? Size(cropLong, cropShort) : Size(cropShort, cropLong);
}

class AnimatedPreviewFit extends StatefulWidget {
  final Alignment alignment;
  final CameraPreviewFit previewFit;
  final PreviewSize previewSize;
  final BoxConstraints constraints;
  final EdgeInsets? previewPadding;
  final Widget child;
  final OnPreviewCalculated? onPreviewCalculated;
  final Sensor sensor;

  /// The capture ratio. [CameraPreviewFit.contain] fits the region this ratio
  /// keeps rather than the whole frame, so a 16:9 crop of a 4:3 frame fills
  /// the space the way the native Camera app's 16:9 viewfinder does, and a
  /// ratio change zooms the live preview instead of reconfiguring the camera.
  final CameraAspectRatios? captureAspectRatio;

  const AnimatedPreviewFit({
    super.key,
    this.alignment = Alignment.center,
    required this.previewFit,
    required this.previewSize,
    required this.constraints,
    required this.sensor,
    required this.child,
    this.onPreviewCalculated,
    this.previewPadding,
    this.captureAspectRatio,
  });

  @override
  State<AnimatedPreviewFit> createState() => _AnimatedPreviewFitState();
}

class _AnimatedPreviewFitState extends State<AnimatedPreviewFit> {
  /// Matches the aspect-ratio mask's animation in the app, so the zoom and the
  /// mask move together.
  static const _ratioChangeDuration = Duration(milliseconds: 300);

  Size? maxSize;

  PreviewSizeCalculator? sizeCalculator;

  /// Only a capture-ratio change animates the zoom; a new frame size or new
  /// constraints (rotation, first layout) snap to the new fit as before.
  Duration _zoomDuration = Duration.zero;

  @override
  void initState() {
    super.initState();
    sizeCalculator = _calculatorFor(widget);
    sizeCalculator!.compute();
    maxSize = sizeCalculator!.maxSize;
    _handPreviewCalculated();
  }

  PreviewSizeCalculator _calculatorFor(AnimatedPreviewFit fit) => PreviewSizeCalculator(
        previewFit: fit.previewFit,
        previewSize: fit.previewSize,
        constraints: fit.constraints,
        captureAspectRatio: fit.captureAspectRatio,
      );

  @override
  void didUpdateWidget(covariant AnimatedPreviewFit oldWidget) {
    super.didUpdateWidget(oldWidget);
    // Pigeon's PreviewSize has no value equality, and the preview re-queries a
    // fresh instance on every ratio change — compare the sizes, or every ratio
    // change would read as a geometry change and snap.
    final geometryChanged = widget.previewFit != oldWidget.previewFit ||
        widget.previewSize.toSize() != oldWidget.previewSize.toSize() ||
        widget.constraints != oldWidget.constraints;
    final ratioChanged = widget.captureAspectRatio != oldWidget.captureAspectRatio;
    if (geometryChanged || ratioChanged) {
      sizeCalculator = _calculatorFor(widget);
      sizeCalculator!.compute();
      maxSize = sizeCalculator!.maxSize;
      _zoomDuration = geometryChanged ? Duration.zero : _ratioChangeDuration;
      _handPreviewCalculated();
    }
  }

  void _handPreviewCalculated() {
    if (widget.onPreviewCalculated != null) {
      // Alignment shift of the preview container inside the available constraints
      final alignX = (widget.alignment.x + 1) / 2; // [-1,1] -> [0,1]
      final alignY = (widget.alignment.y + 1) / 2; // [-1,1] -> [0,1]
      final containerDx = (widget.constraints.maxWidth - sizeCalculator!.maxSize.width) * alignX;
      final containerDy = (widget.constraints.maxHeight - sizeCalculator!.maxSize.height) * alignY;
      final alignedOffset = sizeCalculator!.offset + Offset(containerDx, containerDy);
      widget.onPreviewCalculated!(
        AnalysisPreview(
          nativePreviewSize: widget.previewSize.toSize(),
          previewSize: sizeCalculator!.maxSize,
          offset: alignedOffset,
          scale: sizeCalculator!.zoom,
          sensor: widget.sensor,
        ),
      );
    }
  }

  @override
  Widget build(BuildContext context) {
    // TweenAnimationBuilder animates from wherever the zoom currently is to the
    // new end, so a ratio tapped mid-animation retargets smoothly. Overlays get
    // the end state once (onPreviewCalculated), not a value per frame — only
    // the preview itself moves, so the camera chrome isn't rebuilt every frame.
    return TweenAnimationBuilder<double>(
      builder: (context, zoom, child) {
        return PreviewFitWidget(
          alignment: widget.alignment,
          constraints: widget.constraints,
          previewFit: widget.previewFit,
          previewSize: widget.previewSize,
          scale: zoom,
          maxSize: maxSize!,
          previewPadding: widget.previewPadding,
          child: child!,
        );
      },
      tween: Tween<double>(end: sizeCalculator!.zoom),
      duration: _zoomDuration,
      curve: Curves.easeInOut,
      child: widget.child,
    );
  }
}

class PreviewFitWidget extends StatelessWidget {
  final Alignment alignment;
  final BoxConstraints constraints;
  final CameraPreviewFit previewFit;
  final PreviewSize previewSize;
  final Widget child;
  final double scale;
  final Size maxSize;
  final EdgeInsets? previewPadding;

  const PreviewFitWidget({
    super.key,
    required this.alignment,
    required this.constraints,
    required this.previewFit,
    required this.previewSize,
    required this.child,
    required this.scale,
    required this.maxSize,
    this.previewPadding,
  });

  @override
  Widget build(BuildContext context) {
    final contentWidth = previewSize.width * scale;
    final contentHeight = previewSize.height * scale;

    // The scaled frame, clipped to the available space: when the capture crop
    // zooms it past the edges (16:9 from a 4:3 frame) the overflow is cropped
    // evenly, like the still. This tree is the same widget types every build —
    // it used to be an InteractiveViewer keyed with a fresh UniqueKey(), which
    // re-parented the native preview platform view on every rebuild, and an
    // animated zoom rebuilds every frame.
    return Align(
      alignment: alignment,
      child: SizedBox(
        width: min(contentWidth, constraints.maxWidth),
        height: min(contentHeight, constraints.maxHeight),
        child: Padding(
          padding: previewPadding ?? EdgeInsets.zero,
          child: ClipRect(
            child: OverflowBox(
              alignment: alignment,
              minWidth: contentWidth,
              maxWidth: contentWidth,
              minHeight: contentHeight,
              maxHeight: contentHeight,
              child: FittedBox(
                fit: BoxFit.fill,
                child: SizedBox(
                  width: previewSize.width,
                  height: previewSize.height,
                  child: child,
                ),
              ),
            ),
          ),
        ),
      ),
    );
  }

  double get previewRatio => previewSize.width / previewSize.height;
}

class PreviewSizeCalculator {
  final CameraPreviewFit previewFit;
  final PreviewSize previewSize;
  final BoxConstraints constraints;

  /// See [AnimatedPreviewFit.captureAspectRatio]; only [CameraPreviewFit.contain]
  /// reads it.
  final CameraAspectRatios? captureAspectRatio;

  Size? _maxSize;
  double? _zoom;
  Offset? _offset;

  PreviewSizeCalculator({
    required this.previewFit,
    required this.previewSize,
    required this.constraints,
    this.captureAspectRatio,
  });

  void compute() {
    _zoom ??= _computeZoom();
    _maxSize ??= _computeMaxSize();
  }

  double get zoom {
    if (_zoom == null) {
      throw Exception("Call compute() before");
    }
    return _zoom!;
  }

  Size get maxSize {
    if (_maxSize == null) {
      throw Exception("Call compute() before");
    }
    return _maxSize!;
  }

  Offset get offset {
    if (_offset == null) {
      throw Exception("Call compute() before");
    }
    return _offset!;
  }

  Size _computeMaxSize() {
    var nativePreviewSize = previewSize.toSize();
    Size maxSize;
    final nativeWidthProjection = constraints.maxWidth * 1 / zoom;
    final wDiff = nativePreviewSize.width - nativeWidthProjection;

    final nativeHeightProjection = constraints.maxHeight * 1 / zoom;
    final hDiff = nativePreviewSize.height - nativeHeightProjection;

    maxSize = Size(constraints.maxWidth, constraints.maxHeight);
    _offset = Offset(0, constraints.maxHeight - maxSize.height);
    switch (previewFit) {
      case CameraPreviewFit.fitWidth:
        maxSize = Size(constraints.maxWidth, nativePreviewSize.height * zoom);
        _offset = Offset(0, constraints.maxHeight - maxSize.height);
        break;
      case CameraPreviewFit.fitHeight:
        maxSize = Size(nativePreviewSize.width * zoom, constraints.maxHeight);
        _offset = Offset(constraints.maxWidth - maxSize.width, 0);
        break;
      case CameraPreviewFit.cover:
        maxSize = Size(constraints.maxWidth, constraints.maxHeight);

        if (constraints.maxWidth / constraints.maxHeight > previewSize.width / previewSize.height) {
          _offset = Offset((hDiff * zoom) * 2, 0);
        } else {
          _offset = Offset(0, (wDiff * zoom));
        }
        break;
      case CameraPreviewFit.contain:
        maxSize = Size(constraints.maxWidth, constraints.maxHeight);
        _offset = Offset(
          constraints.maxWidth - maxSize.width,
          constraints.maxHeight - maxSize.height,
        );
        break;
    }

    return maxSize;
  }

  PreviewSize getMaxPreviewSize() {
    return PreviewSize(
      width: maxSize.width,
      height: maxSize.height,
    );
  }

  double _computeZoom() {
    late double ratio;
    var nativePreviewSize = previewSize.toSize();

    switch (previewFit) {
      case CameraPreviewFit.fitWidth:
        ratio = constraints.maxWidth / nativePreviewSize.width; // 800 / 960
        break;
      case CameraPreviewFit.fitHeight:
        ratio = constraints.maxHeight / nativePreviewSize.height; // 1220 / 1280
        break;
      case CameraPreviewFit.cover:
        if (constraints.maxWidth / constraints.maxHeight > nativePreviewSize.width / nativePreviewSize.height) {
          ratio = constraints.maxWidth / nativePreviewSize.width;
        } else {
          ratio = constraints.maxHeight / nativePreviewSize.height;
        }
        break;
      case CameraPreviewFit.contain:
        // Contain what the capture keeps, not the whole frame: for 16:9 from a
        // 4:3 frame this zooms the frame so the 16:9 band fills the space; 4:3
        // and 1:1 keep the full-frame fit (the app masks 1:1's cropped bands).
        final kept = captureCropSize(nativePreviewSize, captureAspectRatio);
        final ratioW = constraints.maxWidth / kept.width;
        final ratioH = constraints.maxHeight / kept.height;
        final minRatio = min(ratioW, ratioH);
        ratio = minRatio;
        break;
    }
    return ratio;
  }

  @override
  bool operator ==(Object other) =>
      identical(this, other) ||
      other is PreviewSizeCalculator &&
          runtimeType == other.runtimeType &&
          previewFit == other.previewFit &&
          constraints == other.constraints &&
          previewSize == other.previewSize &&
          captureAspectRatio == other.captureAspectRatio;

  @override
  int get hashCode => previewSize.hashCode ^ previewSize.hashCode;
}
