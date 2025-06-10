import 'package:chan/services/settings.dart';
import 'package:flutter/services.dart';
import 'package:flutter_inappwebview/flutter_inappwebview.dart';

const kDarkModeCss = 'html {filter: invert(1) hue-rotate(180deg) contrast(0.8);} '
										 'img, video, picture, canvas, iframe, embed {filter: invert(1) hue-rotate(180deg);}';

Future<void> maybeApplyDarkModeBrowserJS(InAppWebViewController controller) async {
	if (Settings.instance.theme.brightness == Brightness.dark) {
		await controller.evaluateJavascript(source: '''
			(function anon() {
			var style = document.createElement('style');
			style.innerHTML = "$kDarkModeCss";
			document.head.appendChild(style);
			})()
		''');
	}
}
