import 'dart:typed_data';

import 'package:camerawesome/src/orchestrator/models/filters/awesome_filter.dart';
import 'package:camerawesome/src/photofilters/filters/color_matrix_filter.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  group('ColorMatrixFilter', () {
    test('identity matrix leaves RGB pixels untouched', () {
      final filter = ColorMatrixFilter(name: 'Identity', matrix: AwesomeFilter.identityMatrix);
      final pixels = Uint8List.fromList([10, 20, 30, 200, 100, 50]);
      filter.apply(pixels, 2, 1);
      expect(pixels, [10, 20, 30, 200, 100, 50]);
    });

    test('applies linear rows + 0-255 offset column with clamping (RGB stride)', () {
      // Half the red channel, +100 offset on green, blue untouched.
      final filter = ColorMatrixFilter(name: 'Test', matrix: const [
        0.5, 0, 0, 0, 0, //
        0, 1, 0, 0, 100, //
        0, 0, 1, 0, 0, //
        0, 0, 0, 1, 0, //
      ]);
      final pixels = Uint8List.fromList([200, 200, 30]);
      filter.apply(pixels, 1, 1);
      expect(pixels, [100, 255, 30]);
    });

    test('handles RGBA stride and transforms the alpha row', () {
      final filter = ColorMatrixFilter(name: 'Test', matrix: const [
        1, 0, 0, 0, 0, //
        0, 1, 0, 0, 0, //
        0, 0, 1, 0, 0, //
        0, 0, 0, 0.5, 0, //
      ]);
      final pixels = Uint8List.fromList([10, 20, 30, 200]);
      filter.apply(pixels, 1, 1);
      expect(pixels, [10, 20, 30, 100]);
    });
  });

  group('AwesomeFilter.custom / isIdentity', () {
    test('None is identity; a real custom matrix is not', () {
      expect(AwesomeFilter.None.isIdentity, isTrue);
      final custom = AwesomeFilter.custom(name: 'Station profile', matrix: const [
        1.2, 0, 0, 0, 0, //
        0, 1, 0, 0, 0, //
        0, 0, 0.9, 0, 0, //
        0, 0, 0, 1, 0, //
      ]);
      expect(custom.isIdentity, isFalse);
      expect(AwesomeFilter.custom(name: 'Noop', matrix: AwesomeFilter.identityMatrix).isIdentity, isTrue);
    });

    test('custom output is a ColorMatrixFilter carrying the same matrix as preview', () {
      const matrix = [
        1.1, 0.0, 0.0, 0.0, 5.0, //
        0.0, 1.0, 0.0, 0.0, 0.0, //
        0.0, 0.0, 0.95, 0.0, 0.0, //
        0.0, 0.0, 0.0, 1.0, 0.0, //
      ];
      final custom = AwesomeFilter.custom(name: 'Station profile', matrix: matrix);
      expect(custom.output, isA<ColorMatrixFilter>());
      expect((custom.output as ColorMatrixFilter).matrix, matrix);
      expect(custom.matrix, matrix);
    });
  });
}
