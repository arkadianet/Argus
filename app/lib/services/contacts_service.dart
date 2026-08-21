import 'dart:convert';

import 'package:flutter/foundation.dart';
import 'package:shared_preferences/shared_preferences.dart';

class WalletContact {
  final String id;
  final String name;
  final String address;

  WalletContact({required this.id, required this.name, required this.address});

  Map<String, dynamic> toJson() => {'id': id, 'name': name, 'address': address};

  factory WalletContact.fromJson(Map<String, dynamic> json) => WalletContact(
        id: json['id'] as String? ?? '',
        name: json['name'] as String? ?? '',
        address: json['address'] as String? ?? '',
      );
}

class ContactsService extends ChangeNotifier {
  static const _key = 'argus_contacts';
  List<WalletContact> _contacts = [];

  List<WalletContact> get contacts => List.unmodifiable(_contacts);

  Future<void> load() async {
    final prefs = await SharedPreferences.getInstance();
    final raw = prefs.getString(_key);
    if (raw != null) {
      try {
        final list = jsonDecode(raw) as List;
        _contacts = list
            .whereType<Map<String, dynamic>>()
            .map(WalletContact.fromJson)
            .toList();
      } catch (_) {
        _contacts = [];
      }
    }
    notifyListeners();
  }

  Future<void> add(String name, String address) async {
    final id = DateTime.now().microsecondsSinceEpoch.toRadixString(36);
    _contacts.add(WalletContact(id: id, name: name, address: address));
    await _save();
  }

  Future<void> update(String id, {String? name, String? address}) async {
    final idx = _contacts.indexWhere((c) => c.id == id);
    if (idx < 0) return;
    final old = _contacts[idx];
    _contacts[idx] = WalletContact(
      id: old.id,
      name: name ?? old.name,
      address: address ?? old.address,
    );
    await _save();
  }

  Future<void> remove(String id) async {
    _contacts.removeWhere((c) => c.id == id);
    await _save();
  }

  Future<void> _save() async {
    final prefs = await SharedPreferences.getInstance();
    await prefs.setString(
      _key,
      jsonEncode(_contacts.map((c) => c.toJson()).toList()),
    );
    notifyListeners();
  }
}

final contactsService = ContactsService();
