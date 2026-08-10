import 'dart:typed_data';

import 'package:camerawesome/src/photofilters/filters/filters.dart';

/// Applies an arbitrary 4×5 row-major colour matrix (Flutter's
/// `ColorFilter.matrix` layout: rows R,G,B,A, 5th column an additive offset
/// in the 0–255 domain) to the decoded pixel buffer.
///
/// This is the capture-side (`Filter.output`) twin of the live preview's
/// `ColorFilter.matrix`, so a custom `AwesomeFilter.custom(matrix: …)` bakes
/// exactly what the viewfinder showed (MIN-3655). The preset photofilters
/// are LUT/sub-filter based and can't express an app-supplied matrix.
class ColorMatrixFilter extends Filter {
  ColorMatrixFilter({required super.name, required List<double> matrix})
      : assert(matrix.length == 20, 'colour matrix must be 4×5 row-major (20 values)'),
        matrix = List.unmodifiable(matrix);

  final List<double> matrix;

  @override
  void apply(Uint8List pixels, int width, int height) {
    // The buffer stride depends on the decoded image: JPEG decodes to 3
    // channels under image 4.x (see ColorFilter.apply's stride-3 note), but
    // stay robust to RGBA sources too.
    final channels = width * height == 0 ? 3 : pixels.length ~/ (width * height);
    if (channels != 3 && channels != 4) return;
    final m = matrix;
    for (int i = 0; i + channels <= pixels.length; i += channels) {
      final r = pixels[i];
      final g = pixels[i + 1];
      final b = pixels[i + 2];
      final a = channels == 4 ? pixels[i + 3] : 255;
      pixels[i] = _clamp(m[0] * r + m[1] * g + m[2] * b + m[3] * a + m[4]);
      pixels[i + 1] = _clamp(m[5] * r + m[6] * g + m[7] * b + m[8] * a + m[9]);
      pixels[i + 2] = _clamp(m[10] * r + m[11] * g + m[12] * b + m[13] * a + m[14]);
      if (channels == 4) {
        pixels[i + 3] = _clamp(m[15] * r + m[16] * g + m[17] * b + m[18] * a + m[19]);
      }
    }
  }

  static int _clamp(double value) => value < 0
      ? 0
      : value > 255
          ? 255
          : value.round();
}
