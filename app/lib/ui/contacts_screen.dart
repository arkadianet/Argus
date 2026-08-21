import 'package:flutter/material.dart';

import '../format.dart';
import '../services/contacts_service.dart';
import '../theme/argus_theme.dart';

class ContactsScreen extends StatefulWidget {
  const ContactsScreen({super.key});

  @override
  State<ContactsScreen> createState() => _ContactsScreenState();
}

class _ContactsScreenState extends State<ContactsScreen> {
  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addPostFrameCallback((_) => contactsService.load());
  }

  void _addOrEdit([WalletContact? existing]) {
    final nameCtrl = TextEditingController(text: existing?.name ?? '');
    final addrCtrl = TextEditingController(text: existing?.address ?? '');
    showDialog(
      context: context,
      builder: (ctx) => AlertDialog(
        title: Text(existing == null ? 'Add contact' : 'Edit contact'),
        content: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            TextField(
              controller: nameCtrl,
              decoration: const InputDecoration(labelText: 'Name'),
              textCapitalization: TextCapitalization.words,
            ),
            const SizedBox(height: 12),
            TextField(
              controller: addrCtrl,
              decoration: const InputDecoration(labelText: 'Address'),
              style: monoStyle(ctx, size: 12),
            ),
          ],
        ),
        actions: [
          TextButton(onPressed: () => Navigator.pop(ctx), child: const Text('Cancel')),
          FilledButton(
            onPressed: () async {
              final name = nameCtrl.text.trim();
              final addr = addrCtrl.text.trim();
              if (name.isEmpty || addr.isEmpty) return;
              if (!looksLikeErgoAddress(addr)) {
                ScaffoldMessenger.of(ctx).showSnackBar(
                  const SnackBar(content: Text('Not a valid Ergo address')),
                );
                return;
              }
              if (existing == null) {
                await contactsService.add(name, addr);
              } else {
                await contactsService.update(existing.id, name: name, address: addr);
              }
              if (ctx.mounted) Navigator.pop(ctx);
            },
            child: Text(existing == null ? 'Add' : 'Save'),
          ),
        ],
      ),
    ).then((_) {
      nameCtrl.dispose();
      addrCtrl.dispose();
    });
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(title: const Text('Contacts')),
      floatingActionButton: FloatingActionButton(
        onPressed: () => _addOrEdit(),
        child: const Icon(Icons.person_add),
      ),
      body: ListenableBuilder(
        listenable: contactsService,
        builder: (context, _) {
          final contacts = contactsService.contacts;
          if (contacts.isEmpty) {
            return Center(
              child: Padding(
                padding: const EdgeInsets.all(28),
                child: Text(
                  'No saved contacts yet.\nTap + to add one.',
                  style: Theme.of(context).textTheme.bodyMedium,
                  textAlign: TextAlign.center,
                ),
              ),
            );
          }
          return ListView.separated(
            padding: const EdgeInsets.fromLTRB(20, 8, 20, 80),
            itemCount: contacts.length,
            separatorBuilder: (_, __) => const Hairline(),
            itemBuilder: (context, i) {
              final c = contacts[i];
              return InkWell(
                onTap: () => _addOrEdit(c),
                onLongPress: () async {
                  final ok = await showDialog<bool>(
                    context: context,
                    builder: (ctx) => AlertDialog(
                      title: const Text('Delete contact?'),
                      content: Text(c.name),
                      actions: [
                        TextButton(onPressed: () => Navigator.pop(ctx, false), child: const Text('Cancel')),
                        FilledButton(onPressed: () => Navigator.pop(ctx, true), child: const Text('Delete')),
                      ],
                    ),
                  );
                  if (ok == true) await contactsService.remove(c.id);
                },
                child: Padding(
                  padding: const EdgeInsets.symmetric(vertical: 14),
                  child: Row(
                    children: [
                      Expanded(
                        child: Column(
                          crossAxisAlignment: CrossAxisAlignment.start,
                          children: [
                            Text(c.name, style: Theme.of(context).textTheme.titleMedium),
                            const SizedBox(height: 4),
                            Text(shorten(c.address, head: 10, tail: 10), style: monoStyle(context, size: 11)),
                          ],
                        ),
                      ),
                      const Icon(Icons.chevron_right, color: Colors.grey),
                    ],
                  ),
                ),
              );
            },
          );
        },
      ),
    );
  }
}
