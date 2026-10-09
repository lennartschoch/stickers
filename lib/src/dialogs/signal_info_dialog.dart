import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:stickers/generated/intl/app_localizations.dart';
import 'package:stickers/src/data/signal.dart';

/// Shown after a pack was exported for Signal, because Signal takes nothing from another app - the
/// pictures have to be uploaded with Signal Desktop first, and these are the steps that do it.
///
/// The same steps are written into the exported zip as [signalReadmeName] by [signalZipReadme],
/// since the upload happens on a computer and not on the screen this dialog is read on.
class SignalInfoDialog extends StatelessWidget {
  const SignalInfoDialog({super.key});

  @override
  Widget build(BuildContext context) {
    final l10n = AppLocalizations.of(context)!;
    return AlertDialog(
      title: Text(l10n.exportForSignal),
      content: SingleChildScrollView(child: Text(l10n.signalDesktopSteps)),
      actions: [
        TextButton(
          onPressed: () async {
            // The steps are of no use on this screen, they belong next to the files.
            await Clipboard.setData(ClipboardData(text: l10n.signalDesktopSteps));
            if (context.mounted) Navigator.of(context).pop();
          },
          child: Text(l10n.copySteps),
        ),
        ElevatedButton(onPressed: () => Navigator.of(context).pop(), child: Text(l10n.gotIt)),
      ],
    );
  }
}
