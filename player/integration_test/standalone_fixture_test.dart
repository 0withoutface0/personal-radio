import 'package:flutter_test/flutter_test.dart';
import 'package:integration_test/integration_test.dart';
import 'package:personal_radio/api.dart';
import 'package:personal_radio/local_engine.dart';

void main() {
  IntegrationTestWidgetsFlutterBinding.ensureInitialized();

  testWidgets('packaged engine uses private, authenticated loopback', (
    tester,
  ) async {
    final engine = LocalEngine();
    expect(await engine.available(), isTrue);
    addTearDown(engine.stop);
    final endpoint = await engine.start();
    final api = RadioApi(endpoint.origin, endpoint.token, 'standalone-fixture');
    final unauthorized = RadioApi(
      endpoint.origin,
      'wrong',
      'standalone-fixture',
    );
    addTearDown(api.close);
    addTearDown(unauthorized.close);
    final accounts = await api.call('/api/accounts');
    expect(accounts['embedded'], isTrue);
    await expectLater(
      unauthorized.call('/api/accounts'),
      throwsA(isA<ApiFailure>().having((error) => error.status, 'status', 401)),
    );
    expect((await api.call('/api/local/history'))['archive']['version'], 1);
    await engine.stop();
    final restarted = await engine.start();
    expect(restarted.token, isNot(endpoint.token));
  });
}
