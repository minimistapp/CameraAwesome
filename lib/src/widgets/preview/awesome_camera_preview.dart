import 'dart:async';
import 'dart:io';

import 'package:camerawesome/camerawesome_plugin.dart';
import 'package:camerawesome/pigeon.dart';
import 'package:camerawesome/src/widgets/preview/awesome_preview_fit.dart';
import 'package:flutter/cupertino.dart';
import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:flutter/rendering.dart' show PlatformViewHitTestBehavior;

enum CameraPreviewFit {
  fitWidth,
  fitHeight,
  contain,
  cover,
}

/// This is a fullscreen camera preview
/// some part of the preview are cropped so we have a full sized camera preview
class AwesomeCameraPreview extends StatefulWidget {
  final CameraPreviewFit previewFit;
  final Widget? loadingWidget;
  final CameraState state;
  final OnPreviewTap? onPreviewTap;
  final OnPreviewScale? onPreviewScale;
  final CameraLayoutBuilder interfaceBuilder;
  final CameraLayoutBuilder? previewDecoratorBuilder;
  final EdgeInsets padding;
  final Alignment alignment;
  final PictureInPictureConfigBuilder? pictureInPictureConfigBuilder;

  const AwesomeCameraPreview({
    super.key,
    this.loadingWidget,
    required this.state,
    this.onPreviewTap,
    this.onPreviewScale,
    this.previewFit = CameraPreviewFit.cover,
    required this.interfaceBuilder,
    this.previewDecoratorBuilder,
    required this.padding,
    required this.alignment,
    this.pictureInPictureConfigBuilder,
  });

  @override
  State<StatefulWidget> createState() {
    return AwesomeCameraPreviewState();
  }
}

class AwesomeCameraPreviewState extends State<AwesomeCameraPreview> {
  PreviewSize? _previewSize;

  final List<Texture> _textures = [];

  PreviewSize? get pixelPreviewSize => _previewSize;

  StreamSubscription? _sensorConfigSubscription;
  StreamSubscription? _aspectRatioSubscription;
  CameraAspectRatios? _aspectRatio;
  double? _aspectRatioValue;
  AnalysisPreview? _preview;

  // Stable key for the native preview PlatformView (iOS UiKitView / Android
  // AndroidView) so Flutter *reparents* it (no native teardown) instead of
  // recreating it when ancestors rebuild — notably PreviewFitWidget's
  // `InteractiveViewer(key: UniqueKey())`, which otherwise remounts the platform
  // view on every preview rebuild, flashing the native preview black and
  // churning native surfaces (MIN-2406).
  final GlobalKey _nativePreviewKey = GlobalKey(debugLabel: 'camerawesome_native_preview');

  // TODO: fetch this value from the native side
  final int kMaximumSupportedFloatingPreview = 3;

  @override
  void initState() {
    super.initState();
    Future.wait([
      widget.state.previewSize(0),
      _loadTextures(),
    ]).then((data) {
      if (mounted) {
        setState(() {
          _previewSize = data[0];
        });
      }
    });

    // refactor this
    _sensorConfigSubscription =
        widget.state.sensorConfig$.listen((sensorConfig) {
      _aspectRatioSubscription?.cancel();
      _aspectRatioSubscription =
          sensorConfig.aspectRatio$.listen((event) async {
        final previewSize = await widget.state.previewSize(0);
        if ((_previewSize != previewSize || _aspectRatio != event) && mounted) {
          setState(() {
            _aspectRatio = event;
            switch (event) {
              case CameraAspectRatios.ratio_16_9:
                _aspectRatioValue = 16 / 9;
                break;
              case CameraAspectRatios.ratio_4_3:
                _aspectRatioValue = 4 / 3;
                break;
              case CameraAspectRatios.ratio_1_1:
                _aspectRatioValue = 1;
                break;
            }
            _previewSize = previewSize;
          });
        }
      });
    });
  }

  Future _loadTextures() async {
    // ignore: invalid_use_of_protected_member
    final sensors = widget.state.cameraContext.sensorConfig.sensors.length;

    // Set it to true to debug the floating preview on a device that doesn't
    // support multicam
    // ignore: dead_code
    if (false) {
      for (int i = 0; i < 2; i++) {
        final textureId = await widget.state.previewTextureId(0);
        if (textureId != null) {
          _textures.add(
            Texture(textureId: textureId),
          );
        }
      }
    } else {
      for (int i = 0; i < sensors; i++) {
        final textureId = await widget.state.previewTextureId(i);
        if (textureId != null) {
          _textures.add(
            Texture(textureId: textureId),
          );
        }
      }
    }
  }

  @override
  void dispose() {
    _sensorConfigSubscription?.cancel();
    _aspectRatioSubscription?.cancel();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    if (_textures.isEmpty || _previewSize == null || _aspectRatio == null) {
      return widget.loadingWidget ??
          Center(
            child: Platform.isIOS
                ? const CupertinoActivityIndicator()
                : const CircularProgressIndicator(),
          );
    }

    // Don't rotate the camera preview when the device rotates — keep it stable
    // like the native iOS Camera app (see _buildMainPreview).
    final effectivePreviewSize = _previewSize!;

    return Container(
      color: Colors.black,
      child: LayoutBuilder(
        builder: (context, constraints) {
          return Stack(
            children: [
              Positioned.fill(
                child: AnimatedPreviewFit(
                  alignment: widget.alignment,
                  previewFit: widget.previewFit,
                  previewSize: effectivePreviewSize,
                  previewPadding: widget.padding,
                  constraints: constraints,
                  sensor: widget.state.sensorConfig.sensors.first,
                  onPreviewCalculated: (preview) {
                    WidgetsBinding.instance.addPostFrameCallback((timeStamp) {
                      if (mounted) {
                        setState(() {
                          _preview = preview;
                        });
                      }
                    });
                  },
                  child: AwesomeCameraGestureDetector(
                    onPreviewTapBuilder:
                        widget.onPreviewTap != null && _previewSize != null
                            ? OnPreviewTapBuilder(
                                pixelPreviewSizeGetter: () => _previewSize!,
                                flutterPreviewSizeGetter: () =>
                                    _previewSize!, //croppedPreviewSize,
                                onPreviewTap: widget.onPreviewTap!,
                              )
                            : null,
                    onPreviewScale: widget.onPreviewScale,
                    initialZoom: widget.state.sensorConfig.zoom,
                    child: StreamBuilder<AwesomeFilter>(
                      //FIX performances
                      stream: widget.state.filter$,
                      builder: (context, snapshot) {
                        final preview = _buildMainPreview();
                        // ColorFiltered can't apply to an iOS PlatformView, but
                        // the main camera doesn't use filters (filter$ defaults
                        // to None), so this only ever wraps the Texture path.
                        return snapshot.hasData &&
                                snapshot.data != AwesomeFilter.None
                            ? ColorFiltered(
                                colorFilter: snapshot.data!.preview,
                                child: preview,
                              )
                            : preview;
                      },
                    ),
                  ),
                ),
              ),
              if (widget.previewDecoratorBuilder != null && _preview != null)
                Positioned.fill(
                  child: widget.previewDecoratorBuilder!(
                    widget.state,
                    _preview!,
                  ),
                ),
              if (_preview != null)
                Positioned.fill(
                  child: widget.interfaceBuilder(
                    widget.state,
                    _preview!,
                  ),
                ),
              // TODO: be draggable
              // TODO: add shadow & border
              ..._buildPreviewTextures(),
            ],
          );
        },
      ),
    );
  }

  /// The main (first-sensor) preview surface.
  ///
  /// iOS (MIN-2406): a native `AVCaptureVideoPreviewLayer` hosted in a
  /// PlatformView — GPU-composited and full-sensor sharp, decoupled from the
  /// small `AVCaptureVideoDataOutput` that feeds MLKit.
  ///
  /// Android: a native CameraX `PreviewView` hosted in an `AndroidView` — also
  /// OS-composited (its own SurfaceView in PERFORMANCE mode) and decoupled from
  /// the `ImageAnalysis` use case that feeds MLKit, so the preview no longer
  /// rides Flutter's compositor/frame-pacing like the Texture path did.
  ///
  /// On both, the Flutter Texture is still registered (used for the filter
  /// thumbnail, floating/multicam previews and as a readiness gate) but no
  /// longer drives the on-screen preview.
  Widget _buildMainPreview() {
    // The native preview is wired only for the single-camera path. Multi-camera
    // sessions (e.g. simultaneous front+back PiP) still render through Flutter
    // textures, so fall back to the Texture there — the platform view would have
    // no native surface to show. Single-sensor is the common case (and the only
    // one this app uses).
    final isSingleSensor = widget.state.sensorConfig.sensors.length <= 1;
    if (isSingleSensor && (Platform.isIOS || Platform.isAndroid)) {
      // Stable key — keeps this platform view alive across ancestor rebuilds
      // (see _nativePreviewKey) so the preview doesn't flash black.
      //
      // hitTestBehavior.transparent keeps the platform view OUT of the gesture
      // arena: on iOS its forwarding recognizer otherwise contends with the
      // ancestor tap recognizer and taps land only intermittently (MIN-2406).
      // The ancestor AwesomeCameraGestureDetector instead stays in the hit-path
      // on its own via `behavior: HitTestBehavior.opaque`, so tap-to-focus no
      // longer depends on this view being hit-testable. The native view is
      // non-interactive (iOS userInteractionEnabled = NO / Android non-clickable)
      // regardless.
      return Platform.isIOS
          ? UiKitView(
              key: _nativePreviewKey,
              viewType: 'camerawesome/preview',
              hitTestBehavior: PlatformViewHitTestBehavior.transparent,
            )
          : AndroidView(
              key: _nativePreviewKey,
              viewType: 'camerawesome/preview',
              hitTestBehavior: PlatformViewHitTestBehavior.transparent,
            );
    }
    // The preview is kept fixed (not rotated with the device), like the native
    // iOS Camera app — so no RotatedBox here.
    return _textures.first;
  }

  List<Widget> _buildPreviewTextures() {
    final previewFrames = <Widget>[];
    // if there is only one texture
    if (_textures.length <= 1) {
      return previewFrames;
    }
    // ignore: invalid_use_of_protected_member
    final sensors = widget.state.cameraContext.sensorConfig.sensors;

    for (int i = 1; i < _textures.length; i++) {
      // TODO: add a way to retrive how camera can be added ("budget" on iOS ?)
      if (i >= kMaximumSupportedFloatingPreview) {
        break;
      }

      final texture = _textures[i];
      final sensor = sensors[kDebugMode ? 0 : i];
      final frame = AwesomeCameraFloatingPreview(
        index: i,
        sensor: sensor,
        texture: texture,
        aspectRatio: 1 / _aspectRatioValue!,
        pictureInPictureConfig:
            widget.pictureInPictureConfigBuilder?.call(i, sensor) ??
                PictureInPictureConfig(
                  startingPosition: Offset(
                    i * 20,
                    MediaQuery.of(context).padding.top + 60 + (i * 20),
                  ),
                  sensor: sensor,
                ),
      );
      previewFrames.add(frame);
    }

    return previewFrames;
  }
}
