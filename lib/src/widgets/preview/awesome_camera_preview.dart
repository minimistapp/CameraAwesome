import 'dart:async';
import 'dart:io';

import 'package:camerawesome/camerawesome_plugin.dart';
import 'package:camerawesome/pigeon.dart';
import 'package:camerawesome/src/widgets/preview/awesome_preview_fit.dart';
import 'package:flutter/cupertino.dart';
import 'package:flutter/foundation.dart';
import 'package:flutter/gestures.dart' show OneSequenceGestureRecognizer;
import 'package:flutter/material.dart';
import 'package:flutter/rendering.dart' show PlatformViewHitTestBehavior;
import 'package:flutter/services.dart' show AndroidViewController, PlatformViewsService, StandardMessageCodec;

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

class AwesomeCameraPreviewState extends State<AwesomeCameraPreview> with WidgetsBindingObserver {
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
    // Re-query the preview size on window metric changes (notably rotation) so
    // the box tracks the orientation the native preview now follows. (MIN-2437)
    WidgetsBinding.instance.addObserver(this);
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

    // On first open the effective preview size can lag the initial query — the
    // native camera is still binding and (Android) the PreviewView attaches
    // only after the platform view mounts — so the box would stay mis-sized
    // until the user rotates. Re-query a few times after open so it settles on
    // its own. (MIN-2437)
    _settlePreviewSizeAfterOpen();

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
  void didChangeMetrics() {
    super.didChangeMetrics();
    // The native preview follows the interface orientation (MIN-2437); on
    // rotation the effective preview size swaps between portrait/landscape, so
    // re-query and resize the box to keep the preview full-screen and upright.
    _refreshPreviewSize();
  }

  /// Re-query the native preview size and resize the box if it changed. Guards
  /// against a zero size (camera not yet bound / torn down) so a stale-but-valid
  /// size is never clobbered.
  Future<void> _refreshPreviewSize() async {
    if (!mounted) return;
    final previewSize = await widget.state.previewSize(0);
    if (mounted && previewSize != _previewSize && previewSize.width > 0 && previewSize.height > 0) {
      setState(() => _previewSize = previewSize);
    }
  }

  /// Re-query the preview size a few times after open so it settles once the
  /// camera has bound, without waiting for a manual rotation. (MIN-2437)
  void _settlePreviewSizeAfterOpen() {
    for (final delayMs in const [200, 600, 1200, 2000]) {
      Future.delayed(Duration(milliseconds: delayMs), _refreshPreviewSize);
    }
  }

  @override
  void dispose() {
    WidgetsBinding.instance.removeObserver(this);
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

    // The native preview follows the interface orientation; _previewSize is
    // re-queried on rotation (didChangeMetrics) so the box matches it. (MIN-2437)
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
    // Analysis-only sessions bind no Preview use case, so there's no native
    // preview surface (Android creates no PreviewView for ANALYSIS_ONLY — see
    // CameraAwesomeX.setupCamera). Fall back to the Texture there, mirroring the
    // Kotlin `mode != ANALYSIS_ONLY` guard, so the PlatformView is never empty.
    final isAnalysisOnly = widget.state.captureMode == CaptureMode.analysis_only;
    if (isSingleSensor && !isAnalysisOnly && (Platform.isIOS || Platform.isAndroid)) {
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
          : _buildAndroidNativePreview();
    }
    // The preview is kept fixed (not rotated with the device), like the native
    // iOS Camera app — so no RotatedBox here.
    return _textures.first;
  }

  /// Android native preview, mounted with **hybrid composition** rather than the
  /// plain `AndroidView` widget.
  ///
  /// `AndroidView` selects Flutter's legacy VirtualDisplay mode, which renders
  /// the platform view into an offscreen `VirtualDisplay` and copies the result
  /// back into the Flutter scene each frame. On a Lenovo TB-X606F that showed up
  /// in `dumpsys SurfaceFlinger` as a second, app-owned display
  /// (`virtual:st.mnm.minimist,...,flutter-vd#0`) at 1800x2400 — ~1.9x the
  /// 1200x1920 panel — whose layers were the only `composition=CLIENT` (GPU)
  /// layers on the device, while every primary-display layer sat on a hardware
  /// overlay. SurfaceFlinger was compositing twice per frame, and the GPU pass
  /// was the preview's (MIN-3577).
  ///
  /// `initSurfaceAndroidView` asks for a texture layer and falls back to true
  /// hybrid composition when the platform view can't render into a supplied
  /// Surface — which is the case here, because the CameraX `PreviewView` runs in
  /// `ImplementationMode.PERFORMANCE` and is therefore backed by a SurfaceView.
  /// The fallback is the outcome we want: the SurfaceView joins the real view
  /// hierarchy and gets its own overlay plane, with no VirtualDisplay at all.
  Widget _buildAndroidNativePreview() {
    return PlatformViewLink(
      // Stable key, for the same reparenting reason as the iOS path above.
      key: _nativePreviewKey,
      viewType: 'camerawesome/preview',
      surfaceFactory: (context, controller) {
        return AndroidViewSurface(
          controller: controller as AndroidViewController,
          // Empty: the native view is non-interactive and the ancestor
          // AwesomeCameraGestureDetector owns tap-to-focus / pinch-to-zoom.
          gestureRecognizers: const <Factory<OneSequenceGestureRecognizer>>{},
          hitTestBehavior: PlatformViewHitTestBehavior.transparent,
        );
      },
      onCreatePlatformView: (params) {
        return PlatformViewsService.initSurfaceAndroidView(
          id: params.id,
          viewType: params.viewType,
          layoutDirection: TextDirection.ltr,
          creationParamsCodec: const StandardMessageCodec(),
          onFocus: () => params.onFocusChanged(true),
        )
          ..addOnPlatformViewCreatedListener(params.onPlatformViewCreated)
          ..create();
      },
    );
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
