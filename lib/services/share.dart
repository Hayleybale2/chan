import 'package:chan/services/apple.dart';
import 'package:chan/services/launch_url_externally.dart';
import 'package:chan/services/util.dart';
import 'package:chan/widgets/adaptive.dart';
import 'package:chan/widgets/util.dart';
import 'package:flutter/cupertino.dart';
import 'package:flutter/services.dart';
import 'package:share_plus/share_plus.dart';

Future<void> shareOne({
	required BuildContext context,
	required String text,
	required String type,
	String? subject,
	required Rect? sharePositionOrigin,
	Map<String, VoidCallback> additionalOptions = const {}
}) async {
	sharePositionOrigin ??= const Rect.fromLTWH(0, 0, 1, 1);
	lightHapticFeedback();
	if (type == 'file') {
		await Share.shareXFiles(
			[XFile(text)],
			subject: subject,
			sharePositionOrigin: sharePositionOrigin
		);
	}
	else {
		final rootContext = context;
		final uri = Uri.tryParse(text);
		await showAdaptiveModalPopup(
			context: rootContext,
			builder: (context) => AdaptiveActionSheet(
				actions: [
					AdaptiveActionSheetAction(
						child: const Text('Copy to clipboard'),
						onPressed: () async {
							Navigator.of(context, rootNavigator: true).pop();
							Clipboard.setData(ClipboardData(
								text: text
							));
							showToast(
								context: context,
								message: 'Copied "$text" to clipboard',
								icon: CupertinoIcons.doc_on_clipboard
							);
						}
					),
					for (final option in additionalOptions.entries) AdaptiveActionSheetAction(
						onPressed: () {
							Navigator.of(context, rootNavigator: true).pop();
							option.value();
						},
						child: Text(option.key)
					),
					if (uri?.host.isNotEmpty == true) ...[
						if (!isOnMac && (uri!.scheme == 'http' || uri.scheme == 'https')) AdaptiveActionSheetAction(
							child: const Text('Open in internal browser'),
							onPressed: () {
								Navigator.of(context, rootNavigator: true).pop();
								openBrowser(rootContext, Uri.parse(text), fromShareOne: true);
							}
						),
						AdaptiveActionSheetAction(
							child: const Text('Open in external browser'),
							onPressed: () async {
								Navigator.of(context, rootNavigator: true).pop();
								await launchUrlExternally(Uri.parse(text));
							}
						)
					],
					AdaptiveActionSheetAction(
						child: const Text('Share...'),
						onPressed: () {
							Navigator.of(context, rootNavigator: true).pop();
							Share.share(
								text,
								subject: subject,
								sharePositionOrigin: sharePositionOrigin
							);
						}
					)
				],
				cancelButton: AdaptiveActionSheetAction(
					child: const Text('Cancel'),
					onPressed: () => Navigator.of(context, rootNavigator: true).pop()
				)
			)
		);
	}
}