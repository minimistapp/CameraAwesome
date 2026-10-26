import 'package:camerawesome/camerawesome_plugin.dart';
import 'package:flutter_test/flutter_test.dart';

const _corners = [0.1, 0.1, 0.3, 0.1, 0.3, 0.3, 0.1, 0.3];

void main() {
  group('NativeBarcode.listFromEvent', () {
    test('a plain QR string carries no geometry for either stream', () {
      expect(NativeBarcode.listFromEvent('https://mnm.st/qr/lst_a', 'barcodes'), isNull);
      expect(NativeBarcode.listFromEvent('https://mnm.st/qr/lst_a', 'qrCodes'), isNull);
    });

    test('splits an event into retail barcodes and QR codes by key (MIN-6670)', () {
      final event = {
        'barcodes': [
          {'value': '5012345678900', 'format': 'ean13', 'corners': _corners},
        ],
        'qrCodes': [
          {'value': 'https://mnm.st/qr/lst_a', 'format': 'qr', 'corners': _corners},
          {'value': 'https://mnm.st/qr/lst_b', 'format': 'qr', 'corners': _corners},
        ],
      };
      expect(NativeBarcode.listFromEvent(event, 'barcodes')!.map((c) => c.value), ['5012345678900']);
      expect(NativeBarcode.listFromEvent(event, 'qrCodes')!.map((c) => c.value), [
        'https://mnm.st/qr/lst_a',
        'https://mnm.st/qr/lst_b',
      ]);
    });

    test('a QR-only event is not a (spurious, empty) barcode event', () {
      final event = {
        'qrCodes': [
          {'value': 'https://mnm.st/qr/lst_a', 'format': 'qr', 'corners': _corners},
        ],
      };
      expect(NativeBarcode.listFromEvent(event, 'barcodes'), isNull);
      expect(NativeBarcode.listFromEvent(event, 'qrCodes'), hasLength(1));
    });

    test('an empty list (the codes left view) is passed on, and malformed entries are skipped', () {
      expect(NativeBarcode.listFromEvent({'qrCodes': <Object>[]}, 'qrCodes'), isEmpty);
      final event = {
        'qrCodes': [
          {'value': 'https://mnm.st/qr/lst_a', 'format': 'qr', 'corners': _corners.sublist(0, 6)},
          {'value': 'https://mnm.st/qr/lst_b', 'format': 'qr', 'corners': _corners},
        ],
      };
      expect(NativeBarcode.listFromEvent(event, 'qrCodes')!.map((c) => c.value), ['https://mnm.st/qr/lst_b']);
    });
  });
}
