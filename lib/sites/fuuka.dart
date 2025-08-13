import 'package:chan/models/attachment.dart';
import 'package:chan/models/board.dart';
import 'package:chan/models/post.dart';
import 'package:chan/sites/util.dart';
import 'package:chan/util.dart';
import 'package:chan/widgets/post_spans.dart';
import 'package:chan/models/search.dart';
import 'package:chan/models/thread.dart';
import 'package:chan/sites/4chan.dart';
import 'package:chan/sites/imageboard_site.dart';
import 'package:dio/dio.dart';
import 'package:flutter/foundation.dart';
import 'package:html/parser.dart' show parse, parseFragment;
import 'package:html/dom.dart' as dom;

extension _EnsurePrefix on String {
	String ensurePrefix(String prefix) {
		if (!startsWith(prefix)) {
			return '$prefix$this';
		}
		return this;
	}
}

class FuukaException implements Exception {
	String error;
	FuukaException(this.error);
	@override
	String toString() => 'Fuuka Error: $error';
}

final _threadLinkMatcher = RegExp(r'\/([a-zA-Z]+)\/thread\/S?(\d+)(#p(\d+))?$');
final _postLinkMatcher = RegExp(r'\/([a-zA-Z]+)\/post\/S?(\d+)$');
final _crossBoardLinkMatcher = RegExp(r'^>>>\/([A-Za-z]+)\/(\d+)$');
final _quoteLinkMatcher = RegExp(r'^#p(\d+)$');
final _attachmentUrlMatcher = RegExp(r'\/data\/([A-Za-z]+)\/img\/\d+\/\d+\/(\d+)(\..+)$');
final _attachmentDetailsMatcher = RegExp(r'File: ([^ ]+) ([KMG]?B), (\d+)x(\d+), (.+)');
final _threadIdMatcher = RegExp(r'^p(\d+)$');

class FuukaArchive extends ImageboardSiteArchive {
	List<ImageboardBoard>? boards;
	@override
	final String baseUrl;
	@override
	final String name;
	static PostNodeSpan makeSpan(String board, int threadId, Map<String, int> linkedPostThreadIds, String data) {
		final body = parseFragment(data.trim());
		final List<PostSpan> elements = [];
		for (final node in body.nodes) {
			if (node is dom.Element) {
				if (node.localName == 'br') {
					elements.add(const PostLineBreakSpan());
				}
				else if (node.localName == 'span') {
					if (node.classes.contains('unkfunc')) {
						final match = _crossBoardLinkMatcher.firstMatch(node.innerHtml);
						if (match != null) {
							elements.add(PostQuoteLinkSpan.dead(board: match.group(1)!, postId: int.parse(match.group(2)!)));
						}
						else {
							elements.add(PostQuoteSpan(makeSpan(board, threadId, linkedPostThreadIds, node.innerHtml)));
						}
					}
					else {
						elements.addAll(Site4Chan.parsePlaintext(node.text));
					}
				}
				else if (node.localName == 'a' && node.attributes.containsKey('href')) {
					final href = node.attributes['href']!;
					final match = _postLinkMatcher.firstMatch(href);
					if (match != null) {
						final board = match.group(1)!;
						final postId = int.parse(match.group(2)!);
						final linkedThreadId = linkedPostThreadIds['$board/$postId'];
						if (linkedThreadId != null) {
							elements.add(PostQuoteLinkSpan(
								board: board,
								postId: postId,
								threadId: linkedThreadId
							));
						}
						else {
							elements.add(PostQuoteLinkSpan.dead(
								board: board,
								postId: postId
							));
						}
					}
					else {
						final match = _quoteLinkMatcher.firstMatch(href);
						if (match != null) {
							elements.add(PostQuoteLinkSpan(
								board: board,
								postId: int.parse(match.group(1)!),
								threadId: threadId
							));
						}
						else {
							elements.add(PostLinkSpan(href, name: node.text.nonEmptyOrNull));
						}
					}
				}
				else {
					elements.addAll(Site4Chan.parsePlaintext(node.text));
				}
			}
			else {
				elements.addAll(Site4Chan.parsePlaintext(node.text ?? ''));
			}
		}
		return PostNodeSpan(elements.toList(growable: false));
	}
	Attachment? _makeAttachment(dom.Element? element, int threadId) {
		if (element != null) {
			final String url = element.attributes['href']!;
			final urlMatch = _attachmentUrlMatcher.firstMatch(url)!;
			final ext = urlMatch.group(3)!;
			RegExpMatch? fileDetailsMatch;
			for (final span in element.parent!.querySelectorAll('span')) {
				fileDetailsMatch = _attachmentDetailsMatcher.firstMatch(span.text);
				if (fileDetailsMatch != null) {
					break;
				}
			}
			if (fileDetailsMatch == null) {
				throw FuukaException('Could not find atttachment details');
			}
			int multiplier = 1;
			if (fileDetailsMatch.group(2) == 'KB') {
				multiplier = 1024;
			}
			else if (fileDetailsMatch.group(2) == 'MB') {
				multiplier = 1024*1024;
			}
			else if (fileDetailsMatch.group(2) == 'GB') {
				multiplier = 1024*1024*1024;
			}
			return Attachment(
				board: urlMatch.group(1)!,
				id: urlMatch.group(2)!,
				filename: fileDetailsMatch.group(5)!,
				ext: ext,
				type: switch (ext) {
					'.webm' => AttachmentType.webm,
					'.mp4' => AttachmentType.mp4,
					_ => AttachmentType.image
				},
				url: url.ensurePrefix('https:'),
				thumbnailUrl: element.querySelector('.thumb')!.attributes['src']!.ensurePrefix('https:'),
				md5: element.parent!.querySelectorAll('a').firstWhere((x) => x.text == 'View same').attributes['href']!.split('/').last,
				spoiler: false,
				width: int.parse(fileDetailsMatch.group(3)!),
				height: int.parse(fileDetailsMatch.group(4)!),
				sizeInBytes: (double.parse(fileDetailsMatch.group(1)!) * multiplier).round(),
				threadId: threadId
			);
		}
		return null;
	}
	Future<Post> _makePost(dom.Element element, {required RequestPriority priority, CancelToken? cancelToken}) async {
		final thisLinkMatches = _threadLinkMatcher.firstMatch(element.querySelector('.js')!.attributes['href']!)!;
		final board = thisLinkMatches.group(1)!;
		final threadId = int.parse(thisLinkMatches.group(2)!);
		final postId = int.tryParse(thisLinkMatches.group(4) ?? '');
		final textNode = element.querySelector('p')!;
		final Map<String, int> linkedPostThreadIds = {};
		for (final link in textNode.querySelectorAll('a')) {
			final linkMatches = _postLinkMatcher.firstMatch(link.attributes['href']!);
			if (linkMatches != null) {
				final response = await client.head(Uri.https(baseUrl, link.attributes['href']!).toString(), options: Options(
					validateStatus: (x) => true,
					extra: {
						kPriority: priority
					}
				), cancelToken: cancelToken);
				if (response.redirects.isNotEmpty) {
					linkedPostThreadIds['${linkMatches.group(1)!}/${linkMatches.group(2)!}'] = int.parse(_threadLinkMatcher.firstMatch(response.redirects.last.location.path)!.group(2)!);
				}
			}
		}
		final a = _makeAttachment(element.querySelector('.thumb')?.parent, threadId);
		final name = element.querySelector('span[itemprop="name"]') ?? element.querySelector('span.postername');
		return Post(
			board: board,
			text: textNode.innerHtml,
			name: name?.text.trim().nonEmptyOrNull ?? 'Anonymous',
			time: DateTime.fromMillisecondsSinceEpoch(int.parse(element.querySelector('.posttime')!.attributes['title']!)),
			id: postId ?? threadId,
			threadId: threadId,
			attachments_: a == null ? [] : [a],
			spanFormat: PostSpanFormat.fuuka,
			extraMetadata: linkedPostThreadIds
		);
	}
	@override
	Future<Post> getPostFromArchive(String board, int id, {required RequestPriority priority, CancelToken? cancelToken}) async {		
		final response = await client.getUri(Uri.https(baseUrl, '/$board/post/$id'), options: Options(
			extra: {
				kPriority: priority
			},
			validateStatus: (_) => true,
			responseType: ResponseType.plain
		), cancelToken: cancelToken);
		if (response.statusCode == 404) {
			throw PostNotFoundException(board, id);
		}
		if ((response.statusCode ?? 400) >= 400) {
			throw HTTPStatusException.fromResponse(response);
		}
		final thread = await _makeThread(parse(response.data).body!, board, int.parse(_threadLinkMatcher.firstMatch(response.redirects.last.location.path)!.group(2)!), priority: priority, cancelToken: cancelToken);
		return thread.posts.firstWhere((t) => t.id == id);
	}
	Future<Thread> _makeThread(dom.Element document, String board, int id, {required RequestPriority priority, CancelToken? cancelToken}) async {
		final op = document.querySelector('#p$id');
		if (op == null) {
			throw FuukaException('OP was not archived');
		}
		final replies = document.querySelectorAll('.reply:not(.subreply)');
		final posts = (await Future.wait([op, ...replies].map((d) => _makePost(d, priority: priority, cancelToken: cancelToken)))).toList();
		final title = document.querySelector('.filetitle')?.text;
		return Thread(
			posts_: posts,
			id: id,
			time: posts[0].time,
			isSticky: false,
			title: title == 'post' ? null : title,
			board: board,
			attachments: posts[0].attachments_,
			replyCount: posts.length - 1,
			isArchived: false,
			imageCount: posts.skip(1).expand((post) => post.attachments).length
		);
	}
	Future<Thread> getThreadContainingPost(String board, int id) async {
		throw Exception('Unimplemented');
	}
	@override
	Future<Thread> getThread(ThreadIdentifier thread, {ThreadVariant? variant, required RequestPriority priority, CancelToken? cancelToken}) async {
		if (!(await getBoards(priority: priority, cancelToken: cancelToken)).any((b) => b.name == thread.board)) {
			throw BoardNotFoundException(thread.board);
		}
		final response = await client.getThreadUri(
			Uri.https(baseUrl, '/${thread.board}/thread/${thread.id}', {
				'board': thread.board,
				'num': thread.id.toString()
			}),
			priority: priority,
			responseType: ResponseType.plain,
			cancelToken: cancelToken
		);
		return await _makeThread(parse(response.data).body!, thread.board, thread.id, priority: priority, cancelToken: cancelToken);
	}
	@override
	Future<List<Thread>> getCatalogImpl(String board, {CatalogVariant? variant, required RequestPriority priority, CancelToken? cancelToken}) async {
		final response = await client.getUri(Uri.https(baseUrl, '/$board/'), options: Options(
			validateStatus: (x) => true,
			responseType: ResponseType.plain,
			extra: {
				kPriority: priority
			}
		), cancelToken: cancelToken);
		final document = parse(response.data);
		int? threadId;
		dom.Element e = dom.Element.tag('div');
		final List<Thread> threads = [];
		for (final child in document.querySelector('.content')!.children) {
			if (child.localName == 'hr') {
				threads.add(await _makeThread(e, board, threadId!, priority: priority, cancelToken: cancelToken));
				e = dom.Element.tag('div');
			}
			else {
				if (child.localName == 'div') {
					final match = _threadIdMatcher.firstMatch(child.id);
					if (match != null) {
						threadId = int.parse(match.group(1)!);
					}
				}
				e.append(child);
			}
		}
		return threads;
	}

	@override
	Future<List<ImageboardBoard>> getBoards({required RequestPriority priority, CancelToken? cancelToken}) async {
		return boards!;
	}

	String _formatDateForSearch(DateTime d) {
		return '${d.year}-${d.dMM}-${d.dDD}';
	}

	@override
	Future<ImageboardArchiveSearchResultPage> search(ImageboardArchiveSearchQuery query, {required int page, ImageboardArchiveSearchResultPage? lastResult, required RequestPriority priority, CancelToken? cancelToken}) async {
		if (query.postTypeFilter == PostTypeFilter.onlyStickies) {
			throw UnsupportedError('"Only stickies" filtering not supported in Fuuka search');
		}
		final knownBoards = await getBoards(priority: priority, cancelToken: cancelToken);
		final unknownBoards = query.boards.where((b) => !knownBoards.any((kb) => kb.name == b));
		if (unknownBoards.isNotEmpty) {
			throw BoardNotFoundException(unknownBoards.first);
		}
		final response = await client.getUri(
			Uri.https(baseUrl, '/${query.boards.first}/', {
				'task': 'search2',
				'ghost': 'yes',
				'search_text': query.query,
				if (query.postTypeFilter == PostTypeFilter.onlyOPs) 'search_op': 'op',
				if (query.startDate != null) 'search_datefrom': _formatDateForSearch(query.startDate!),
				if (query.endDate != null) 'search_dateto': _formatDateForSearch(query.endDate!),
				'offset': ((page - 1) * 24).toString(),
				if (query.deletionStatusFilter == PostDeletionStatusFilter.onlyDeleted) 'search_del': 'yes'
				else if (query.deletionStatusFilter == PostDeletionStatusFilter.onlyNonDeleted) 'search_del': 'no',
				if (query.subject != null) 'search_subject': query.subject,
				if (query.name != null) 'search_username': query.name,
				if (query.trip != null) 'search_tripcode': query.trip,
				if (query.md5 != null) 'search_media_hash': query.md5
		}), options: Options(
			responseType: ResponseType.plain,
			extra: {
				kPriority: priority
			}
		), cancelToken: cancelToken);
		if (response.statusCode != 200) {
			throw HTTPStatusException.fromResponse(response);
		}
		final document = parse(response.data);
		return ImageboardArchiveSearchResultPage(
			posts: (await Future.wait(document.querySelectorAll('.reply:not(.subreply)').map((e) async {
				final p = await _makePost(e, priority: priority, cancelToken: cancelToken);
				if (p.id == p.threadId) {
					return ImageboardArchiveSearchResult.thread(Thread(
						board: p.board,
						id: p.threadId,
						replyCount: 0,
						imageCount: 0,
						title: e.querySelector('.filetitle')?.text,
						isSticky: false,
						time: p.time,
						attachments: p.attachments_,
						posts_: [p]
					));
				}
				return ImageboardArchiveSearchResult.post(p);
			}))).toList(),
			page: page,
			replyCountsUnreliable: true,
			imageCountsUnreliable: true,
			maxPage: null,
			count: null,
			canJumpToArbitraryPage: true,
			archive: this
		);
	}

	@override
	String getWebUrlImpl(String board, [int? threadId, int? postId]) {
		String webUrl = 'https://$baseUrl/$board/';
		if (threadId != null) {
			webUrl += 'thread/$threadId';
			if (postId != null) {
				webUrl += '#p$postId';
			}
		 }
		 return webUrl;
	}

	@override
	Future<BoardThreadOrPostIdentifier?> decodeUrl(Uri url) async {
		if (url.host != baseUrl) {
			return null;
		}
		final p = url.pathSegments.where((s) => s.isNotEmpty).toList();
		switch (p) {
			case [String board]:
				return BoardThreadOrPostIdentifier(board);
			case [String board, 'thread', String threadIdStr]:
				if (threadIdStr.tryParseInt case int threadId) {
					return BoardThreadOrPostIdentifier(board, threadId, url.fragment.extractPrefixedInt('p'));
				}
		}
		return null;
	}

	FuukaArchive({
		required this.baseUrl,
		required this.name,
		this.boards,
		required super.overrideUserAgent
	});

	@override
	bool operator == (Object other) =>
		identical(this, other) ||
		(other is FuukaArchive) &&
		(other.baseUrl == baseUrl) &&
		(other.name == name) &&
		listEquals(other.boards, boards) &&
		super==(other);

	@override
	int get hashCode => baseUrl.hashCode;
}