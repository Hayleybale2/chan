// ignore_for_file: argument_type_not_assignable

import 'package:chan/models/attachment.dart';

import 'package:chan/models/board.dart';
import 'package:chan/models/flag.dart';
import 'package:chan/services/persistence.dart';
import 'package:chan/models/thread.dart';
import 'package:chan/models/post.dart';
import 'package:chan/sites/helpers/http_304.dart';
import 'package:chan/sites/imageboard_site.dart';
import 'package:chan/sites/lainchan.dart';
import 'package:chan/util.dart';
import 'package:dio/dio.dart';
import 'package:flutter/cupertino.dart';
import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:flutter_inappwebview/flutter_inappwebview.dart';
import 'package:html/parser.dart';
import 'package:html/dom.dart' as dom;

class DvachException implements Exception {
	final int code;
	final String message;
	DvachException(this.code, this.message);
	@override
	String toString() => 'Dvach error ($code): $message';
}

class SiteDvach extends ImageboardSite with Http304CachingThreadMixin {
	@override
	final String baseUrl;
	@override
	final String name;

	SiteDvach({
		required this.baseUrl,
		required this.name,
		required super.overrideUserAgent,
		required super.archives,
		required super.imageHeaders,
		required super.videoHeaders
	});

	@override
	Future<List<ImageboardBoard>> getBoards({required RequestPriority priority, CancelToken? cancelToken}) async {
		final response = await client.getUri(Uri.https(baseUrl, '/index.json'), options: Options(
			responseType: ResponseType.json,
			extra: {
				kPriority: priority
			}
		), cancelToken: cancelToken);
		return (response.data['boards'] as List).map((board) {
			final maxFileSizeBytes = switch (board['max_files_size']) {
				int kb => 1024 * kb,
				_ => null
			};
			return ImageboardBoard(
				name: board['id'],
				title: board['name'],
				isWorksafe: board['category'] != 'Взрослым',
				webmAudioAllowed: true,
				threadCommentLimit: board['bump_limit'],
				maxCommentCharacters: board['max_comment'],
				maxImageSizeBytes: maxFileSizeBytes,
				maxWebmSizeBytes: maxFileSizeBytes,
				pageCount: board['max_pages']
			);
		}).toList();
	}

	List<Attachment> _makeAttachments(String board, int threadId, Map<String, dynamic> data) {
		return ((data['files'] as List<dynamic>?)?.cast<Map<String, dynamic>>() ?? []).map((file) {
			final url = Uri.https(baseUrl, file['path']);
			AttachmentType type = AttachmentType.image;
			if (url.path.endsWith('.webm')) {
				type = AttachmentType.webm;
			}
			else if (url.path.endsWith('.mp4')) {
				type = AttachmentType.mp4;
			}
			else if (url.path.endsWith('.mp3')) {
				type = AttachmentType.mp3;
			}
			return Attachment(
				type: type,
				board: board,
				threadId: threadId,
				id: url.pathSegments.last.split('.').first,
				ext: '.${url.pathSegments.last.split('.').last}',
				filename: file['fullname'],
				url: url.toString(),
				thumbnailUrl: Uri.https(baseUrl, file['thumbnail']).toString(),
				md5: file['md5'],
				width: file['width'],
				height: file['height'],
				sizeInBytes: file['size'] * 1024
			);
		}).toList();
	}

	static final _iconFlagPattern = RegExp(r'<img.*src="(.*\/([^.]+)\.[^."]+)"');

	Post _makePost(String board, int threadId, Map<String, dynamic> data) {
		String? posterId = data['op'] == 1 ? 'OP' : null;
		final name = StringBuffer();
		final nameDoc = parseFragment(data['name'] ?? '');
		for (final node in nameDoc.nodes) {
			if (node is dom.Element && node.localName == 'span' && node.id.startsWith('id_tag_')) {
				posterId = node.text;
			}
			else {
				name.write(node.text);
			}
		}
		return Post(
			board: board,
			threadId: threadId,
			id: data['num'],
			text: data['comment'],
			name: name.toString().trim(),
			posterId: posterId,
			time: DateTime.fromMillisecondsSinceEpoch(data['timestamp'] * 1000),
			spanFormat: PostSpanFormat.lainchan,
			attachments_: _makeAttachments(board, threadId, data),
			flag: switch (_iconFlagPattern.firstMatch(data['icon'] ?? '')) {
				null => null,
				RegExpMatch flagMatch => ImageboardFlag(
					imageHeight: 12,
					imageWidth: 18,
					name: flagMatch.group(2) ?? 'Unknown',
					imageUrl: 'https://$baseUrl${flagMatch.group(1)}'
				)
			}
		);
	}

	@override
	Future<List<Thread>> getCatalogImpl(String board, {CatalogVariant? variant, required RequestPriority priority, CancelToken? cancelToken}) async {
		final response = await client.getUri(Uri.https(baseUrl, '/$board/catalog.json'), options: Options(
			validateStatus: (s) => true,
			extra: {
				kPriority: priority
			},
			responseType: ResponseType.json
		), cancelToken: cancelToken);
		if (response.statusCode == 404) {
			throw BoardNotFoundException(board);
		}
		else if (response.statusCode != 200) {
			throw HTTPStatusException.fromResponse(response);
		}
		final threadsPerPage = response.data['board']['threads_per_page'] as int?;
		return (response.data['threads'] as List<dynamic>).cast<Map<String, dynamic>>().asMap().entries.map((e) {
			final op = _makePost(board, e.value['num'], e.value);
			return Thread(
				posts_: [op],
				id: op.id,
				board: board,
				title: e.value['subject'],
				isSticky: e.value['sticky'] != 0,
				time: op.time,
				attachments: op.attachments_,
				currentPage: threadsPerPage == null ? null : ((e.key ~/ threadsPerPage) + 1),
				replyCount: e.value['posts_count'] - 1,
				imageCount: e.value['files_count'] - op.attachments.length,
				isEndless: e.value['endless'] == 1,
				lastUpdatedTime: switch (e.value['lasthit']) {
					int s => DateTime.fromMillisecondsSinceEpoch(s * 1000),
					_ => null
				}
			);
		}).toList();
	}

	@override
	Future<Thread> makeThread(ThreadIdentifier thread, Response<dynamic> response, {
		required RequestPriority priority,
		CancelToken? cancelToken
	}) async {
		final posts = (response.data['threads'].first['posts'] as List<dynamic>).map((data) => _makePost(thread.board, thread.id, data)).toList();
		return Thread(
			board: thread.board,
			id: thread.id,
			title: response.data['threads'].first['posts'].first['subject'],
			isSticky: response.data['threads'].first['posts'].first['sticky'] != 0,
			time: posts.first.time,
			attachments: posts.first.attachments_,
			posts_: posts,
			replyCount: response.data['posts_count'] - 1,
			imageCount: response.data['files_count'] - posts.first.attachments.length,
			isEndless: response.data['threads'].first['posts'].first['endless'] == 1
		);
	}

	@override
	RequestOptions getThreadRequest(ThreadIdentifier thread, {ThreadVariant? variant})
		=> RequestOptions(
			path: '/${thread.board}/res/${thread.id}.json',
			baseUrl: 'https://$baseUrl',
			responseType: ResponseType.json
		);

	@override
	Future<CaptchaRequest> getCaptchaRequest(String board, int? threadId, {CancelToken? cancelToken}) async {
		if (loginSystem.isLoggedIn(Persistence.currentCookies)) {
			return const NoCaptchaRequest();
		}
		return const DvachEmojiCaptchaRequest(challengeLifetime: Duration(seconds: 300));
	}

	@override
	Future<PostReceipt> submitPost(DraftPost post, CaptchaSolution captchaSolution, CancelToken cancelToken) async {
		final file = post.file;
		final passcodeAuth = (await Persistence.currentCookies.loadForRequest(Uri.https(baseUrl))).tryFirstWhere((c) => c.name == 'passcode_auth')?.value;
		final Map<String, dynamic> fields = {
			'task': 'post',
			'board': post.board,
			'name': post.name ?? '',
			'email': post.options ?? '',
			if (captchaSolution is DvachCaptchaSolution) ...{
				'captcha_type': '2chcaptcha',
				'2chcaptcha_id': captchaSolution.id,
				'2chcaptcha_value': captchaSolution.response
			}
			else if (captchaSolution is DvachEmojiCaptchaSolution) ...{
				'captcha_type': 'emoji_captcha',
				'emoji_captcha_id': captchaSolution.id
			},
			if (passcodeAuth != null) 'usercode': passcodeAuth,
			'comment': post.text,
			if (file != null) 'file[]': await MultipartFile.fromFile(file, filename: post.overrideFilename),
			if (post.threadId != null) 'thread': post.threadId.toString()
		};
		final response = await client.postUri(
			Uri.https(baseUrl, '/user/posting'),
			data: FormData.fromMap(fields),
			options: Options(
				responseType: ResponseType.json,
				validateStatus: (x) => true,
				headers: {
					'Referer': getWebUrlImpl(post.board, post.threadId)
				},
				extra: {
					kPriority: RequestPriority.interactive
				}
			),
			cancelToken: cancelToken
		);
		if (response.data['error'] != null) {
			throw DvachException(response.data['error']['code'], response.data['error']['message']);
		}
		return PostReceipt(
			post: post,
			password: '',
			id: response.data['num'],
			name: post.name ?? '',
			options: post.options ?? '',
			time: DateTime.now(),
			ip: captchaSolution.ip
		);
	}

	@override
	String getWebUrlImpl(String board, [int? threadId, int? postId]) {
		String threadUrl = Uri.https(baseUrl, '/$board/').toString();
		if (threadId != null) {
			threadUrl += 'res/$threadId.html';
			if (postId != null) {
				threadUrl += '#q$postId';
			}
		}
		return threadUrl;
	}

	@override
	Future<BoardThreadOrPostIdentifier?> decodeUrl(String url) async => SiteLainchan.decodeGenericUrl(baseUrl, 'res', url);

	@override
	List<ImageboardSnippet> getBoardSnippets(String board) => const [
		ImageboardSnippet.simple(
			icon: CupertinoIcons.bold,
			name: 'Bold',
			start: '[b]',
			end: '[/b]',
			previewBuilder: SnippetPreviewBuilders.bold
		),
		ImageboardSnippet.simple(
			icon: CupertinoIcons.italic,
			name: 'Italic',
			start: '[i]',
			end: '[/i]',
			previewBuilder: SnippetPreviewBuilders.italic
		),
		greentextSnippet,
		// There is no Cupertino overline icon, use material for both for consistency
		ImageboardSnippet.simple(
			icon: Icons.format_underline,
			name: 'Underline',
			start: '[u]',
			end: '[/u]',
			previewBuilder: SnippetPreviewBuilders.underline
		),
		ImageboardSnippet.simple(
			icon: Icons.format_overline,
			name: 'Overline',
			start: '[o]',
			end: '[/o]',
			previewBuilder: SnippetPreviewBuilders.overline
		),
		ImageboardSnippet.simple(
			icon: CupertinoIcons.eye_slash,
			name: 'Spoiler',
			start: '[spoiler]',
			end: '[/spoiler]'
		),
		ImageboardSnippet.simple(
			icon: CupertinoIcons.strikethrough,
			name: 'Strikethrough',
			start: '[s]',
			end: '[/s]',
			previewBuilder: SnippetPreviewBuilders.strikethrough
		),
		ImageboardSnippet.simple(
			icon: CupertinoIcons.textformat_superscript,
			name: 'Superscript',
			start: '[sup]',
			end: '[/sup]',
			previewBuilder: SnippetPreviewBuilders.superscript
		),
		ImageboardSnippet.simple(
			icon: CupertinoIcons.textformat_subscript,
			name: 'Subscript',
			start: '[sub]',
			end: '[/sub]',
			previewBuilder: SnippetPreviewBuilders.subscript
		),
	];

	@override
	String get siteType => 'dvach';
	@override
	String get siteData => baseUrl;
	@override
	Uri? get iconUrl => Uri.https(baseUrl, '/favicon.ico');
	@override
	String get defaultUsername => 'Аноним';

	@override
	bool operator ==(Object other) =>
		identical(this, other) ||
		(other is SiteDvach) &&
		(other.name == name) &&
		(other.baseUrl == baseUrl) &&
		(other.overrideUserAgent == overrideUserAgent) &&
		listEquals(other.archives, archives) &&
		mapEquals(other.imageHeaders, imageHeaders) &&
		mapEquals(other.videoHeaders, videoHeaders);

	@override
	int get hashCode => Object.hash(name, baseUrl, overrideUserAgent, Object.hashAll(archives));

	@override
	late final SiteDvachPasscodeLoginSystem loginSystem = SiteDvachPasscodeLoginSystem(this);

	@override
	bool get supportsPushNotifications => true;
}

class SiteDvachPasscodeLoginSystem extends ImageboardSiteLoginSystem {
	@override
	final SiteDvach parent;

	SiteDvachPasscodeLoginSystem(this.parent);

  @override
  List<ImageboardSiteLoginField> getLoginFields() {
    return const [
			ImageboardSiteLoginField(
				displayName: 'Passcode',
				formKey: 'passcode',
				autofillHints: [AutofillHints.password]
			)
		];
  }

  @override
  Future<void> logoutImpl(bool fromBothWifiAndCellular, CancelToken cancelToken) async {
		await parent.client.postUri(
			Uri.https(parent.baseUrl, '/user/passlogout'),
			options: Options(
				extra: {
					kPriority: RequestPriority.interactive
				}
			),
			cancelToken: cancelToken
		);
		loggedIn[Persistence.currentCookies] = false;
		if (fromBothWifiAndCellular) {
			await Persistence.nonCurrentCookies.deletePreservingCloudflare(Uri.https(parent.baseUrl, '/'), true);
			await CookieManager.instance().deleteCookies(
				url: WebUri(parent.baseUrl)
			);
			loggedIn[Persistence.nonCurrentCookies] = false;
		}
  }

  @override
  Future<void> login(Map<ImageboardSiteLoginField, String> fields, CancelToken cancelToken) async {
		final response = await parent.client.postUri(
			Uri.https(parent.baseUrl, '/user/passlogin'),
			data: FormData.fromMap({
				for (final field in fields.entries) field.key.formKey: field.value
			}),
			options: Options(
				responseType: ResponseType.plain,
				validateStatus: (_) => true,
				extra: {
					kPriority: RequestPriority.interactive
				},
				followRedirects: false // This makes sure cookie is remembered
			),
			cancelToken: cancelToken
		);
		
		if ((response.statusCode ?? 400) >= 400) {
			final document = parse(response.data);
			final message = document.querySelector('.msg__title')?.text;
			loggedIn[Persistence.currentCookies] = false;
			await logout(false, cancelToken);
			throw ImageboardSiteLoginException(message ?? 'Unknown error');
		}
		loggedIn[Persistence.currentCookies] = true;
  }

  @override
  String get name => 'Passcode';

	@override
	bool get hidden => false;
}
