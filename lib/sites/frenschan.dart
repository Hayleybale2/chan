import 'package:chan/sites/imageboard_site.dart';
import 'package:chan/sites/lainchan2.dart';
import 'package:dio/dio.dart';
import 'package:flutter/foundation.dart';

class SiteFrenschan extends SiteLainchan2 {
	SiteFrenschan({
		required super.baseUrl,
		required super.name,
		required super.overrideUserAgent,
		required super.boardsWithHtmlOnlyFlags,
		required super.boardsWithMemeFlags,
		required super.archives
	}) : super(
		basePath: '',
		faviconPath: '/favicon.ico',
		defaultUsername: 'Fren',
		formBypass: {},
		imageThumbnailExtension: ''
	);

	@override
	String get siteType => 'frenschan';

	@override
	Future<CaptchaRequest> getCaptchaRequest(String board, int? threadId, {CancelToken? cancelToken}) async {
		return SecurimageCaptchaRequest(
			challengeUrl: Uri.https(baseUrl, '/securimage.php')
		);
	}

	@override
	bool operator ==(Object other) =>
		identical(this, other) ||
		(other is SiteFrenschan) &&
		(other.baseUrl == baseUrl) &&
		(other.name == name) &&
		(other.faviconPath == faviconPath) &&
		(other.defaultUsername == defaultUsername) &&
		(other.overrideUserAgent == overrideUserAgent) &&
		listEquals(other.archives, archives) &&
		listEquals(other.boardsWithHtmlOnlyFlags, boardsWithHtmlOnlyFlags) &&
		listEquals(other.boardsWithMemeFlags, boardsWithMemeFlags);

	@override
	int get hashCode => baseUrl.hashCode;

	@override
	String get res => 'res';
}