import 'package:flutter/material.dart';
import 'package:stickers/generated/intl/app_localizations.dart';

/// Shown after a pack was exported for Signal, because unlike WhatsApp, Signal has no way to take
/// a sticker pack from another app directly - the user has to upload the file to get a link.
class SignalInfoDialog extends StatelessWidget {
  const SignalInfoDialog({super.key});

  @override
  Widget build(BuildContext context) {
    return AlertDialog(
      title: Text(AppLocalizations.of(context)!.exportForSignal),
      content: Text(AppLocalizations.of(context)!.signalExportHint),
      actions: [
        ElevatedButton(
          onPressed: () => Navigator.of(context).pop(),
          child: Text(AppLocalizations.of(context)!.gotIt),
        )
      ],
    );
  }
}
