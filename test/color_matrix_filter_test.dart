import 'dart:typed_data';

import 'package:camerawesome/src/orchestrator/models/filters/awesome_filter.dart';
import 'package:camerawesome/src/orchestrator/states/handlers/filter_handler.dart';
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

  group('bakeCaptures (MIN-3655)', () {
    const matrix = [
      1.2, 0.0, 0.0, 0.0, 0.0, //
      0.0, 1.0, 0.0, 0.0, 0.0, //
      0.0, 0.0, 0.9, 0.0, 0.0, //
      0.0, 0.0, 0.0, 1.0, 0.0, //
    ];

    test('custom defaults to baking captures, presets too', () {
      expect(AwesomeFilter.custom(name: 'Station profile', matrix: matrix).bakeCaptures, isTrue);
      expect(AwesomeFilter.None.bakeCaptures, isTrue);
      expect(AwesomeFilter.Sierra.bakeCaptures, isTrue);
    });

    test('custom can opt out for a preview-only filter', () {
      final previewOnly = AwesomeFilter.custom(
        name: 'Station profile',
        matrix: matrix,
        bakeCaptures: false,
      );
      expect(previewOnly.bakeCaptures, isFalse);
      // Opting out changes nothing else: the preview still gets the matrix.
      expect(previewOnly.matrix, matrix);
      expect(previewOnly.isIdentity, isFalse);
      expect(previewOnly.output, isA<ColorMatrixFilter>());
    });

    test('FilterHandler bakes by default and skips preview-only filters', () {
      expect(
        FilterHandler.shouldBake(AwesomeFilter.custom(name: 'Station profile', matrix: matrix)),
        isTrue,
      );
      expect(
        FilterHandler.shouldBake(
          AwesomeFilter.custom(name: 'Station profile', matrix: matrix, bakeCaptures: false),
        ),
        isFalse,
      );
      // None never baked, with or without the flag.
      expect(FilterHandler.shouldBake(AwesomeFilter.None), isFalse);
    });
  });

  group('compatiblePreview (MIN-3655)', () {
    const matrix = [
      1.2, 0.0, 0.0, 0.0, 0.0, //
      0.0, 1.0, 0.0, 0.0, 0.0, //
      0.0, 0.0, 0.9, 0.0, 0.0, //
      0.0, 0.0, 0.0, 1.0, 0.0, //
    ];

    test('defaults off — a filter alone no longer forces a TextureView', () {
      expect(AwesomeFilter.custom(name: 'Station profile', matrix: matrix).compatiblePreview, isFalse);
      expect(AwesomeFilter.None.compatiblePreview, isFalse);
      expect(AwesomeFilter.Sierra.compatiblePreview, isFalse);
    });

    test('is independent of the matrix — identity can request it, a filter can decline', () {
      final animatedIdentity = AwesomeFilter.custom(
        name: 'Original',
        matrix: AwesomeFilter.identityMatrix,
        compatiblePreview: true,
      );
      expect(animatedIdentity.isIdentity, isTrue);
      expect(animatedIdentity.compatiblePreview, isTrue);

      final filtered = AwesomeFilter.custom(
        name: 'Station profile',
        matrix: matrix,
        compatiblePreview: false,
      );
      expect(filtered.isIdentity, isFalse);
      expect(filtered.compatiblePreview, isFalse);
    });

    test('composes with bakeCaptures without disturbing it', () {
      final filter = AwesomeFilter.custom(
        name: 'Station profile',
        matrix: matrix,
        bakeCaptures: false,
        compatiblePreview: true,
      );
      expect(filter.bakeCaptures, isFalse);
      expect(filter.compatiblePreview, isTrue);
      expect(FilterHandler.shouldBake(filter), isFalse);
    });
  });
}
