import 'dart:io';

import 'package:bibliojules_mobile/src/core/api_exception.dart';
import 'package:bibliojules_mobile/src/local/file_picker.dart';
import 'package:bibliojules_mobile/src/local/transfer.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  const channel = MethodChannel(kFilesChannel);

  late Directory scratch;

  setUp(() async {
    scratch = await Directory.systemTemp.createTemp('bibliojules_picker');
  });

  tearDown(() {
    if (scratch.existsSync()) scratch.deleteSync(recursive: true);
  });

  test(
    'picking a CSV returns the copied file and passes the MIME hint',
    () async {
      final picker = DeviceFilePicker(
        channel: channel,
        scratchDirectory: () async => scratch,
      );
      TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
          .setMockMethodCallHandler(channel, (call) async {
            expect(call.method, 'pick');
            final args = call.arguments as Map<Object?, Object?>;
            expect(args['type'], 'text/*');
            final target = args['target'] as String;
            await File(target)
                .writeAsString('Title,Author\nDune,Frank Herbert\n');
            return target;
          });
      addTearDown(
        () => TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
            .setMockMethodCallHandler(channel, null),
      );

      final file = await picker.pick(name: 'import.csv', mimeType: 'text/*');
      expect(file, isNotNull);
      expect(await file!.readAsString(), contains('Dune'));
    },
  );

  test('cancelling returns null', () async {
    final picker = DeviceFilePicker(
      channel: channel,
      scratchDirectory: () async => scratch,
    );
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(channel, (call) async => null);
    addTearDown(
      () => TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
          .setMockMethodCallHandler(channel, null),
    );

    expect(await picker.pick(name: 'cover', mimeType: 'image/*'), isNull);
  });

  test('a picker failure becomes an ApiException', () async {
    final picker = DeviceFilePicker(
      channel: channel,
      scratchDirectory: () async => scratch,
    );
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(channel, (call) async {
          throw PlatformException(
            code: 'busy',
            message: 'Another file operation is still open.',
          );
        });
    addTearDown(
      () => TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
          .setMockMethodCallHandler(channel, null),
    );

    await expectLater(
      picker.pick(name: 'cover'),
      throwsA(
        isA<ApiException>().having(
          (error) => error.message,
          'message',
          'Another file operation is still open.',
        ),
      ),
    );
  });
}
