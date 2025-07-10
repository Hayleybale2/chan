import 'package:async/async.dart';
import 'package:chan/models/board.dart';
import 'package:chan/models/flag.dart';
import 'package:chan/models/thread.dart';
import 'package:chan/sites/imageboard_site.dart';
import 'package:chan/sites/lainchan_org.dart';
import 'package:chan/sites/util.dart';
import 'package:chan/util.dart';
import 'package:dio/dio.dart';
import 'package:flutter/foundation.dart';
import 'package:html/dom.dart' as dom;
import 'package:html/parser.dart';
import 'package:mutex/mutex.dart';

const _kExtraBypassLock = 'bypass_lock';

/// Block any processing while form is being submitted, so that the new cookies
/// can be injected by a later interceptor
class FormBypassBlockingInterceptor extends Interceptor {
	final SiteLainchan2 site;

	FormBypassBlockingInterceptor(this.site);

	@override
	void onRequest(RequestOptions options, RequestInterceptorHandler handler) {
		if (options.extra[_kExtraBypassLock] == true) {
			handler.next(options);
		}
		else {
			site.formLock.protect(() async {
				handler.next(options);
			});
		}
	}
}

class FormBypassInterceptor extends Interceptor {
	final SiteLainchan2 site;

	FormBypassInterceptor(this.site);

	@override
	void onResponse(Response response, ResponseInterceptorHandler handler) async {
		try {
			if (response.realUri.host == site.baseUrl) {
				final formBypass = site.formBypass[response.realUri.path];
				if (formBypass != null) {
					final document = parse(response.data);
					String? action = document.querySelector('form')?.attributes['action'];
					if (action != null) {
						if (action.startsWith('/')) {
							action = 'https://${site.baseUrl}$action';
						}
						final action_ = action;
						final response2 = await site.formLock.protect(() async {
							final postResponse = await site.client.post(action_, data: FormData.fromMap(formBypass), options: Options(
								validateStatus: (x) => x != null && (x >= 200 || x < 400),
								followRedirects: true,
								extra: {
									_kExtraBypassLock: true
								}
							), cancelToken: response.requestOptions.cancelToken);
							if (postResponse.realUri.path != response.realUri.path) {
								return await site.client.fetch(response.requestOptions.copyWith(
									extra: {
										...response.requestOptions.extra,
										_kExtraBypassLock: true
									}
								));
							}
						});
						if (response2 != null) {
							// Success
							handler.next(response2);
							return;
						}
					}
				}
			}
			handler.next(response);
		}
		catch (e, st) {
			Future.error(e, st); // Crashlytics
			handler.reject(DioError(
				requestOptions: response.requestOptions,
				error: e
			));
		}
	}
}

/// The old SiteLainchan and SiteLainchanOrg can't really be modified due to backwards compatibility
class SiteLainchan2 extends SiteLainchanOrg {
	@override
	final String? imageThumbnailExtension;
	final List<ImageboardBoard>? boards;
	final Map<String, Map<String, String>> formBypass;
	final formLock = Mutex();
	@override
	final String res;
	final List<String> boardsWithHtmlOnlyFlags;
	final List<String>? boardsWithMemeFlags;

	SiteLainchan2({
		required super.baseUrl,
		required super.basePath,
		required super.name,
		required this.formBypass,
		required this.imageThumbnailExtension,
		required super.overrideUserAgent,
		required super.archives,
		required super.imageHeaders,
		required super.videoHeaders,
		required this.boardsWithHtmlOnlyFlags,
		required this.boardsWithMemeFlags,
		required super.turnstileSiteKey,
		super.faviconPath,
		super.boardsPath,
		this.boards,
		super.defaultUsername,
		this.res = 'res'
	}) {
		client.interceptors.insert(1, FormBypassBlockingInterceptor(this));
		client.interceptors.add(FormBypassInterceptor(this));
	}
	
	@override
	Future<List<ImageboardBoard>> getBoards({required RequestPriority priority, CancelToken? cancelToken}) async {
		return boards ?? (await super.getBoards(priority: priority, cancelToken: cancelToken));
	}

	@override
	Future<Thread> makeThread(ThreadIdentifier thread, Response<dynamic> response, {
		required RequestPriority priority,
		CancelToken? cancelToken
	}) async {
		final broken = await super.makeThread(thread, response, priority: priority, cancelToken: cancelToken);
		if (imageThumbnailExtension != '' && !boardsWithHtmlOnlyFlags.contains(thread.board)) {
			return broken;
		}
		final response2 = await client.getThreadUri(Uri.https(baseUrl, '$basePath/${thread.board}/$res/${thread.id}.html'), priority: priority, responseType: ResponseType.plain, cancelToken: cancelToken);
		final document = parse(response2.data);
		final thumbnailUrls = document.querySelectorAll('img.post-image').map((e) => e.attributes['src']).toList();
		for (final attachment in broken.posts_.expand((p) => p.attachments)) {
			final thumbnailUrl = thumbnailUrls.tryFirstWhere((u) => u?.contains(attachment.id) ?? false);
			if (thumbnailUrl != null) {
				attachment.thumbnailUrl =
					thumbnailUrl.startsWith('/') ?
						Uri.https(baseUrl, thumbnailUrl).toString() :
						thumbnailUrl;
			}
		}
		// Copy corrected thumbnail URLs to thread from posts_.first
		for (final a in broken.posts_.first.attachments) {
			broken.attachments.tryFirstWhere((a2) => a.id == a2.id)?.thumbnailUrl = a.thumbnailUrl;
		}
		for (final flag in document.querySelectorAll('.post > p > label > img.flag')) {
			final postId = int.tryParse(flag.parent?.parent?.parent?.id.split('_').last ?? '');
			if (postId == null) {
				continue;
			}
			final post = broken.posts_.tryFirstWhere((p) => p.id == postId);
			if (post == null) {
				continue;
			}
			post.flag = ImageboardFlag(
				name: flag.attributes['alt'] ?? '<unknown>',
				imageUrl: Uri.parse(getWebUrlImpl(thread.board, thread.id)).resolve(flag.attributes['src']!).toString(),
				imageWidth: 17,
				imageHeight: 14
			);
		}
		return broken;
	}

	@override
	Future<List<Thread>> getCatalogImpl(String board, {CatalogVariant? variant, required RequestPriority priority, CancelToken? cancelToken}) async {
		final broken = await super.getCatalogImpl(board, priority: priority, cancelToken: cancelToken);
		if (imageThumbnailExtension != '') {
			return broken;
		}
		final response = await client.getUri(Uri.https(baseUrl, '$basePath/$board/catalog.html'), options: Options(
			extra: {
				kPriority: priority
			},
			responseType: ResponseType.plain
		), cancelToken: cancelToken);
		final document = parse(response.data);
		final thumbnailUrls = document.querySelectorAll('img.thread-image').map((e) => e.attributes['src']).toList();
		for (final attachment in broken.expand((t) => t.attachments)) {
			final thumbnailUrl = thumbnailUrls.tryFirstWhere((u) => u?.contains(attachment.id.toString()) ?? false);
			if (thumbnailUrl != null) {
				attachment.thumbnailUrl =
					thumbnailUrl.startsWith('/') ?
						Uri.https(baseUrl, thumbnailUrl).toString() :
						thumbnailUrl;
			}
		}
		return broken;
	}

	final Map<String, AsyncMemoizer<List<ImageboardBoardFlag>>> _boardFlags = {};
	@override
	Future<List<ImageboardBoardFlag>> getBoardFlags(String board) {
		return _boardFlags.putIfAbsent(board, () => AsyncMemoizer<List<ImageboardBoardFlag>>()).runOnce(() async {
			Map<String, String> flagMap = {};
			if (boardsWithMemeFlags != null && (boardsWithMemeFlags!.isEmpty /* all boards */ || boardsWithMemeFlags!.contains(board))) {
				try {
					final response = await client.getUri(Uri.https(baseUrl, '/$board/'), options: Options(
						responseType: ResponseType.plain
					)).timeout(const Duration(seconds: 5));
					final doc = parse(response.data);
					flagMap = {
						for (final e in doc.querySelector('select[name="user_flag"]')?.querySelectorAll('option') ?? <dom.Element>[])
							(e.attributes['value'] ?? '0'): e.text
					};
				}
				catch (e, st) {
					print('Failed to fetch flags for $name ${formatBoardName(board)}: ${e.toStringDio()}');
					Future.error(e, st); // crashlytics
				}
			}
			return flagMap.entries.map((entry) => ImageboardBoardFlag(
				code: entry.key,
				name: entry.value,
				imageUrl: Uri.https(baseUrl, '/static/flags/${entry.key}.png').toString()
			)).toList();
		});
	}

	@override
	void migrateFromPrevious(SiteLainchan2 oldSite) {
		super.migrateFromPrevious(oldSite);
		_boardFlags.addAll(oldSite._boardFlags);
	}

	@override
	String get siteType => 'lainchan2';
	@override
	String get siteData => baseUrl;

	@override
	bool operator == (Object other) =>
		identical(this, other) ||
		(other is SiteLainchan2) &&
		mapEquals(other.formBypass, formBypass) &&
		(other.imageThumbnailExtension == imageThumbnailExtension) &&
		listEquals(other.boards, boards) &&
		listEquals(other.boardsWithHtmlOnlyFlags, boardsWithHtmlOnlyFlags) &&
		listEquals(other.boardsWithMemeFlags, boardsWithMemeFlags) &&
		(other.res == res) &&
		super==(other);

	@override
	int get hashCode => baseUrl.hashCode;
}