import 'dart:async';

import 'package:camerawesome/pigeon.dart';
import 'package:flutter/gestures.dart';
import 'package:flutter/material.dart';

import 'package:camerawesome/src/widgets/preview/awesome_focus_indicator.dart';

Widget _awesomeFocusBuilder(Offset tapPosition) {
  return AwesomeFocusIndicator(position: tapPosition);
}

class OnPreviewTapBuilder {
  // Use getters instead of storing the direct value to retrieve the data onTap
  final PreviewSize Function() pixelPreviewSizeGetter;
  final PreviewSize Function() flutterPreviewSizeGetter;
  final OnPreviewTap onPreviewTap;

  const OnPreviewTapBuilder({
    required this.pixelPreviewSizeGetter,
    required this.flutterPreviewSizeGetter,
    required this.onPreviewTap,
  });
}

class OnPreviewTap {
  final Function(Offset position, PreviewSize flutterPreviewSize,
      PreviewSize pixelPreviewSize) onTap;

  /// Called when the preview is pressed and held, with the same arguments as
  /// [onTap]. The system cameras use this for the AE/AF lock. Null: a long
  /// press does nothing.
  final Function(Offset position, PreviewSize flutterPreviewSize,
      PreviewSize pixelPreviewSize)? onLongPress;
  final Widget Function(Offset tapPosition)? onTapPainter;
  final Duration? tapPainterDuration;

  const OnPreviewTap({
    required this.onTap,
    this.onLongPress,
    this.onTapPainter = _awesomeFocusBuilder,
    this.tapPainterDuration = const Duration(milliseconds: 2000),
  });
}

class OnPreviewScale {
  final Function(double scale) onScale;

  const OnPreviewScale({
    required this.onScale,
  });
}

class AwesomeCameraGestureDetector extends StatefulWidget {
  final Widget child;
  final OnPreviewTapBuilder? onPreviewTapBuilder;
  final OnPreviewScale? onPreviewScale;
  final double initialZoom;

  const AwesomeCameraGestureDetector({
    super.key,
    required this.child,
    required this.onPreviewScale,
    this.onPreviewTapBuilder,
    this.initialZoom = 0,
  });

  @override
  State<StatefulWidget> createState() {
    return _AwesomeCameraGestureDetector();
  }
}

class _AwesomeCameraGestureDetector
    extends State<AwesomeCameraGestureDetector> {
  double _zoomScale = 0;
  final double _accuracy = 0.01;
  double? _lastScale;

  Offset? _tapPosition;
  // Increments on every tap so the focus painter is rebuilt from scratch each
  // time — otherwise re-tapping the same spot reuses the existing animation
  // element and the indicator never replays.
  int _tapCount = 0;
  Timer? _timer;

  @override
  void initState() {
    _zoomScale = widget.initialZoom;
    super.initState();
  }

  @override
  Widget build(BuildContext context) {
    return RawGestureDetector(
      // Stay in the hit-test path on our own area rather than deferring to the
      // child. The iOS preview is a non-hittable PlatformView
      // (hitTestBehavior: transparent, MIN-2406); with the default
      // deferToChild this detector would fall out of the hit path and
      // tap-to-focus would never fire. Opaque also keeps the platform view out
      // of the gesture arena, so taps resolve reliably (as they did with the
      // old Texture) instead of intermittently. No effect on the Android /
      // Texture path, where the child was already hittable.
      behavior: HitTestBehavior.opaque,
      gestures: <Type, GestureRecognizerFactory>{
        if (widget.onPreviewScale != null)
          ScaleGestureRecognizer:
              GestureRecognizerFactoryWithHandlers<ScaleGestureRecognizer>(
            () => ScaleGestureRecognizer()
              ..onStart = (_) {
                _lastScale = null;
              }
              ..onUpdate = (ScaleUpdateDetails details) {
                _lastScale ??= details.scale;
                if (details.scale < (_lastScale! + 0.01) &&
                    details.scale > (_lastScale! - 0.01)) {
                  return;
                } else if (_lastScale! < details.scale) {
                  _zoomScale += _accuracy;
                } else {
                  _zoomScale -= _accuracy;
                }

                _zoomScale = _zoomScale.clamp(0, 1);
                widget.onPreviewScale!.onScale(_zoomScale);
                _lastScale = details.scale;
              },
            (instance) {},
          ),
        if (widget.onPreviewTapBuilder != null)
          TapGestureRecognizer:
              GestureRecognizerFactoryWithHandlers<TapGestureRecognizer>(
            () => TapGestureRecognizer()
              ..onTapUp = (details) {
                _showTapPainter(details.localPosition);
                widget.onPreviewTapBuilder!.onPreviewTap.onTap(
                  details.localPosition,
                  widget.onPreviewTapBuilder!.flutterPreviewSizeGetter(),
                  widget.onPreviewTapBuilder!.pixelPreviewSizeGetter(),
                );
              },
            (instance) {},
          ),
        if (widget.onPreviewTapBuilder?.onPreviewTap.onLongPress != null)
          LongPressGestureRecognizer:
              GestureRecognizerFactoryWithHandlers<LongPressGestureRecognizer>(
            () => LongPressGestureRecognizer()
              ..onLongPressStart = (details) {
                final builder = widget.onPreviewTapBuilder;
                final onLongPress = builder?.onPreviewTap.onLongPress;
                if (builder == null || onLongPress == null) return;
                _showTapPainter(details.localPosition);
                onLongPress(
                  details.localPosition,
                  builder.flutterPreviewSizeGetter(),
                  builder.pixelPreviewSizeGetter(),
                );
              },
            (instance) {},
          ),
      },
      child: Stack(children: [
        Positioned.fill(child: widget.child),
        if (_tapPosition != null &&
            widget.onPreviewTapBuilder?.onPreviewTap.onTapPainter != null)
          KeyedSubtree(
            // A fresh key per tap forces the painter (and its one-shot
            // animation) to rebuild even when the tap lands on the same spot.
            key: ValueKey(_tapCount),
            child:
                widget.onPreviewTapBuilder!.onPreviewTap.onTapPainter!(_tapPosition!),
          ),
      ]),
    );
  }

  void _showTapPainter(Offset position) {
    final duration = widget.onPreviewTapBuilder!.onPreviewTap.tapPainterDuration;
    if (duration != null) {
      _timer?.cancel();
      _timer = Timer(duration, () {
        setState(() {
          _tapPosition = null;
        });
      });
    }
    setState(() {
      _tapPosition = position;
      _tapCount++;
    });
  }

  @override
  dispose() {
    _timer?.cancel();
    super.dispose();
  }
}
