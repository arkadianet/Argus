import 'package:shared_preferences_platform_interface/shared_preferences_platform_interface.dart';

class FailingPreferences extends InMemorySharedPreferencesStore {
  FailingPreferences(Map<String, Object> values) : super.withData(values);
  @override
  Future<bool> setValue(String valueType, String key, Object value) async =>
      false;
}
