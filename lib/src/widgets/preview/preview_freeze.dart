import 'dart:async';
import 'dart:ui' as ui;

import 'package:camerawesome/camerawesome_plugin.dart';
import 'package:flutter/widgets.dart';

/// Where a [PreviewFreeze] is in a switch.
enum PreviewFreezePhase {
  idle,

  /// The still is fading in over the live preview.
  covering,

  /// The still covers the preview; the session behind it is switching, and the
  /// preview keeps its geometry.
  holding,

  /// The preview has the new stream and re-lays out for it under the still.
  settling,

  /// The still fades, revealing the live preview.
  revealing,
}

/// A photo/video switch done the way the system camera does it (MIN-4185):
/// a blurred still of the last frame fades in over the preview, holds while
/// the session reconfigures, grows or shrinks with the preview to the new
/// format, and crossfades back to the live preview.
///
/// The still is drawn by [PreviewFreezeOverlay] inside the preview's box, so
/// it follows the box's resize exactly. One camera preview at a time, so one
/// instance.
class PreviewFreeze extends ChangeNotifier {
  PreviewFreeze._();

  static final PreviewFreeze instance = PreviewFreeze._();

  static const Duration coverDuration = Duration(milliseconds: 140);

  /// How far into the preview's resize the still starts to fade.
  static const Duration revealDelay = Duration(milliseconds: 120);
  static const Duration revealDuration = Duration(milliseconds: 260);

  /// Never leave a still up if a switch never settles.
  static const Duration _backstopDelay = Duration(seconds: 3);

  PreviewFreezePhase _phase = PreviewFreezePhase.idle;
  ui.Image? _still;
  int _generation = 0;
  Timer? _backstop;

  PreviewFreezePhase get phase => _phase;

  /// The blurred frame, or null — a plain black cover — when none came.
  ui.Image? get still => _still;

  /// While true the preview keeps its geometry: the session is mid-switch.
  bool get holdsGeometry => _phase == PreviewFreezePhase.covering || _phase == PreviewFreezePhase.holding;

  /// True while the preview animates to its new geometry.
  bool get isSettling => _phase == PreviewFreezePhase.settling || _phase == PreviewFreezePhase.revealing;

  /// Puts the still over the preview; completes once it fully covers it, the
  /// moment to start the switch. A still already up (a switch tapped mid-way
  /// through another) is brought back rather than re-captured.
  Future<void> cover() async {
    final generation = ++_generation;
    _armBackstop();
    if (_phase == PreviewFreezePhase.idle) {
      ui.Image? still;
      try {
        still = await CamerawesomePlugin.capturePreviewStill();
      } catch (_) {
        still = null;
      }
      if (generation != _generation) {
        still?.dispose();
        return;
      }
      _still = still;
    }
    _setPhase(PreviewFreezePhase.covering);
    await Future<void>.delayed(coverDuration);
    if (generation != _generation) return;
    _setPhase(PreviewFreezePhase.holding);
  }

  /// Reveals the new session once the preview shows it: the preview re-lays
  /// out under the still, which then fades.
  Future<void> reveal() async {
    final generation = _generation;
    if (_phase == PreviewFreezePhase.idle) return;
    try {
      await CamerawesomePlugin.previewSettled();
    } catch (_) {
      // Reveal anyway.
    }
    if (generation != _generation) return;
    await _reveal(generation);
  }

  /// Drops the still at once (the preview is going away).
  void reset() {
    _generation++;
    _clear();
  }

  Future<void> _reveal(int generation) async {
    _backstop?.cancel();
    _setPhase(PreviewFreezePhase.settling);
    await Future<void>.delayed(revealDelay);
    if (generation != _generation) return;
    _setPhase(PreviewFreezePhase.revealing);
    await Future<void>.delayed(revealDuration);
    if (generation != _generation) return;
    _clear();
  }

  void _armBackstop() {
    _backstop?.cancel();
    _backstop = Timer(_backstopDelay, () {
      if (holdsGeometry) unawaited(_reveal(_generation));
    });
  }

  void _clear() {
    _backstop?.cancel();
    _still?.dispose();
    _still = null;
    _setPhase(PreviewFreezePhase.idle);
  }

  void _setPhase(PreviewFreezePhase phase) {
    if (_phase == phase) return;
    _phase = phase;
    notifyListeners();
  }
}

/// The [PreviewFreeze] still, covering whatever box it is laid out in.
class PreviewFreezeOverlay extends StatelessWidget {
  const PreviewFreezeOverlay({super.key});

  @override
  Widget build(BuildContext context) {
    final freeze = PreviewFreeze.instance;
    return IgnorePointer(
      child: ListenableBuilder(
        listenable: freeze,
        builder: (context, _) {
          final phase = freeze.phase;
          final shown = phase == PreviewFreezePhase.covering ||
              phase == PreviewFreezePhase.holding ||
              phase == PreviewFreezePhase.settling;
          final still = freeze.still;
          return AnimatedOpacity(
            opacity: shown ? 1 : 0,
            duration: shown ? PreviewFreeze.coverDuration : PreviewFreeze.revealDuration,
            curve: shown ? Curves.easeOut : Curves.easeInOut,
            child: phase == PreviewFreezePhase.idle
                ? const SizedBox.expand()
                : still == null
                    ? const ColoredBox(color: Color(0xFF000000))
                    : RawImage(image: still, fit: BoxFit.cover, filterQuality: FilterQuality.medium),
          );
        },
      ),
    );
  }
}
