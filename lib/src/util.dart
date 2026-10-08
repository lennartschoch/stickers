import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:image_editor/image_editor.dart';
import 'package:path_provider/path_provider.dart';
import 'package:stickers/generated/intl/app_localizations.dart';
import 'package:stickers/src/data/load_store.dart';
import 'package:stickers/src/data/signal.dart';
import 'package:stickers/src/data/sticker_pack.dart';
import 'package:stickers/src/dialogs/error_dialog.dart';
import 'package:stickers/src/dialogs/signal_info_dialog.dart';
import 'package:stickers/src/globals.dart';
import 'package:whatsapp_stickers_plus/exceptions.dart';

bool isValidURL(String input) {
  final url = Uri.tryParse(input);
  if (url == null) return false;
  if (url.scheme != "http" && url.scheme != "https") return false;
  if (url.host.isEmpty) return false;
  return url.isAbsolute;
}

String? titleValidator(String? value, BuildContext context) {
  if (value == null || value.isEmpty) {
    return AppLocalizations.of(context)!.pleaseEnterTitle;
  }
  return null;
}

String? authorValidator(String? value, BuildContext context) {
  if (value == null || value.isEmpty) {
    return AppLocalizations.of(context)!.pleaseEnterAuthor;
  }
  return null;
}

Future<void> sendToWhatsappWithErrorHandling(StickerPack pack, BuildContext context) async {
  try {
    await pack.sendToWhatsapp();
  } on WhatsappStickersAlreadyAddedException catch (_) {
  } on WhatsappStickersException catch (e) {
    showDialog(
      context: navigatorKey.currentContext!,
      builder: (_) => ErrorDialog(
        title: AppLocalizations.of(context)!.couldnTAddStickerPack,
        message: e.cause ?? e.runtimeType.toString(),
      ),
    );
  } on PlatformException catch (e) {
    if (e.message == "WhatsApp is not installed on target device!") {
      showDialog(
          context: navigatorKey.currentContext!,
          builder: (_) => ErrorDialog(
              title: AppLocalizations.of(context)!.couldnTAddStickerPack,
              message: AppLocalizations.of(context)!.whatsappNotInstalled));
    } else {
      showDialog(
          context: navigatorKey.currentContext!,
          builder: (_) =>
              ErrorDialog(title: AppLocalizations.of(context)!.couldnTAddStickerPack, message: e.message ?? ""));
    }
  } on Exception catch (e) {
    showDialog(
        context: navigatorKey.currentContext!,
        builder: (_) => ErrorDialog(title: AppLocalizations.of(context)!.couldnTAddStickerPack, message: e.toString()));
  }
}

String signalIssueMessage(SignalIssue issue, BuildContext context) {
  switch (issue) {
    case SignalIssue.empty:
      return AppLocalizations.of(context)!.signalIssueEmpty;
    case SignalIssue.tooMany:
      return AppLocalizations.of(context)!.signalIssueTooMany;
    case SignalIssue.animated:
      return AppLocalizations.of(context)!.signalIssueAnimated;
    case SignalIssue.oversized:
      return AppLocalizations.of(context)!.signalIssueOversized;
  }
}

/// Exports [pack] in Signal's format, shares the file and explains what to do with it.
/// Signal offers no "add to Signal" intent, so unlike [sendToWhatsappWithErrorHandling] this only
/// hands the user a file they still have to upload themselves.
Future<void> exportForSignalWithErrorHandling(StickerPack pack) async {
  try {
    await exportPackAsSignal(pack);
    _showOverNavigator((context) => const SignalInfoDialog());
  } on SignalExportException catch (e) {
    _showOverNavigator((context) => ErrorDialog(
          title: AppLocalizations.of(context)!.error,
          message: e.issues.map((issue) => signalIssueMessage(issue, context)).join("\n"),
        ));
  } on Exception catch (e) {
    _showOverNavigator(
      (context) => ErrorDialog(title: AppLocalizations.of(context)!.error, message: e.toString()),
    );
  }
}

/// Shows [builder] over whatever page is on screen right now, the export we just waited for may
/// well have outlived the widget that started it.
void _showOverNavigator(Widget Function(BuildContext context) builder) {
  final navigatorContext = navigatorKey.currentContext;
  if (navigatorContext?.mounted != true) return;
  showDialog(context: navigatorContext!, builder: builder);
}

int colCount(double width) {
  if (width < 500) {
    return 3;
  } else if (width < 800) {
    return 6;
  } else {
    return 9;
  }
}

