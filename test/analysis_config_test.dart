import 'package:camerawesome/camerawesome_plugin.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  test(
      'CupertinoAnalysisOptions.jpeg asks iOS for natively encoded JPEG frames (MIN-7796)',
      () {
    const options = CupertinoAnalysisOptions.jpeg(width: 1280);
    expect(options.outputFormat, InputAnalysisImageFormat.jpeg);
    // The name is what crosses the pigeon bridge; the iOS plugin keys the native encoder off "jpeg".
    expect(options.outputFormat.name, 'jpeg');
    expect(options.width, 1280);
    expect(const CupertinoAnalysisOptions.jpeg().width, 0,
        reason: '0 keeps the native 1024 default');
  });
}
