import 'package:log_trail/storage.dart';
import 'package:test/test.dart';

void main() {
  test('toString names what is known: code, operation, message, statement', () {
    expect(const LogStoreException('disk full').toString(), 'LogStoreException: disk full');
    expect(
      const LogStoreException(
        'no such table: log',
        code: 1,
        operation: 'preparing statement',
        statement: 'SELECT 1',
      ).toString(),
      'LogStoreException(1): while preparing statement, no such table: log\n  Statement: SELECT 1',
    );
  });

  test('is an Exception, so a handler for store failures catches it without knowing the backend', () {
    expect(const LogStoreException('x'), isA<Exception>());
  });
}
