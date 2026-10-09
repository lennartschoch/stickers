import 'package:flutter/material.dart';
import 'package:stickers/generated/intl/app_localizations.dart';
import 'package:stickers/src/data/load_store.dart';
import 'package:stickers/src/data/signal.dart';
import 'package:stickers/src/data/sticker_pack.dart';
import 'package:stickers/src/globals.dart';

/// Remembers the install link Signal gave a pack back after it was uploaded.
///
/// Signal doesn't tell any app which packs it installed, so the link is pasted here once - after
/// that the pack opens in Signal from its own page, and the link survives backups of this app.
class SignalLinkDialog extends StatefulWidget {
  const SignalLinkDialog(this.pack, {super.key});

  final StickerPack pack;

  @override
  State<SignalLinkDialog> createState() => _SignalLinkDialogState();
}

class _SignalLinkDialogState extends State<SignalLinkDialog> {
  final _controller = TextEditingController();
  final _formKey = GlobalKey<FormState>();

  @override
  void initState() {
    super.initState();
    _controller.text = widget.pack.signalLink ?? "";
  }

  @override
  void dispose() {
    _controller.dispose();
    super.dispose();
  }

  String? _validate(String? value) {
    if (value == null || value.trim().isEmpty) return null; // Empty clears the link, that's fine.
    return parseSignalPackRef(value) == null ? AppLocalizations.of(context)!.signalLinkInvalid : null;
  }

  /// Writes the link to the pack in its canonical form, or clears it again if the field is empty.
  void _save() {
    if (!(_formKey.currentState?.validate() ?? false)) return;
    widget.pack.signalLink = parseSignalPackRef(_controller.text)?.installLink;
    savePacks(packs);
    Navigator.of(context).pop();
  }

  @override
  Widget build(BuildContext context) {
    final l10n = AppLocalizations.of(context)!;
    return AlertDialog(
      title: Text(l10n.signalInstallLink),
      content: Form(
        key: _formKey,
        autovalidateMode: AutovalidateMode.onUserInteraction,
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            Text(l10n.signalInstallLinkHint),
            const SizedBox(height: 12),
            TextFormField(
              controller: _controller,
              validator: _validate,
              keyboardType: TextInputType.url,
              textInputAction: TextInputAction.done,
              minLines: 2,
              maxLines: 3,
              decoration: InputDecoration(
                // The dialog is titled with what this is, the example says the rest.
                helperText: "https://signal.art/addstickers/#pack_id=...&pack_key=...",
                helperMaxLines: 2,
              ),
            ),
          ],
        ),
      ),
      actions: [
        TextButton(onPressed: () => Navigator.of(context).pop(), child: Text(l10n.cancel)),
        ElevatedButton(onPressed: _save, child: Text(l10n.done)),
      ],
    );
  }
}
