import 'package:argus_wallet/services/contacts_service.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';

void main() {
  setUp(() {
    SharedPreferences.setMockInitialValues({});
  });

  test('add, load, and remove contacts', () async {
    final svc = ContactsService();
    await svc.load();
    expect(svc.contacts, isEmpty);

    await svc.add('Alice', '9eatpGQdYNjTi5ZZLK7Bo7C3ms6oECPnxbQTRn6sDcBNLMYSCa8');
    expect(svc.contacts.length, 1);
    expect(svc.contacts.first.name, 'Alice');
    expect(svc.contacts.first.address.startsWith('9'), isTrue);

    await svc.add('Bob', '9eatpGQdYNjTi5ZZLK7Bo7C3ms6oECPnxbQTRn6sDcBNLMYSCa8b');
    expect(svc.contacts.length, 2);

    final id = svc.contacts.first.id;
    await svc.remove(id);
    expect(svc.contacts.length, 1);
    expect(svc.contacts.first.name, 'Bob');
  });

  test('update contact preserves id', () async {
    final svc = ContactsService();
    await svc.load();
    await svc.add('Alice', '9aaa');
    final id = svc.contacts.first.id;
    await svc.update(id, name: 'Alicia', address: '9bbb');
    expect(svc.contacts.first.name, 'Alicia');
    expect(svc.contacts.first.address, '9bbb');
    expect(svc.contacts.first.id, id);
  });

  test('load reads persisted contacts across instances', () async {
    final a = ContactsService();
    await a.load();
    await a.add('Alice', '9aaa');

    final b = ContactsService();
    await b.load();
    expect(b.contacts.length, 1);
    expect(b.contacts.first.name, 'Alice');
  });
}
