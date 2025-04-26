// ignore_for_file: file_names

import 'dart:convert';

import 'package:chan/models/board.dart';
import 'package:chan/models/flag.dart';
import 'package:chan/sites/imageboard_site.dart';
import 'package:chan/sites/lainchan2.dart';
import 'package:dio/dio.dart';
import 'package:flutter/foundation.dart';

class Site8Kun extends SiteLainchan2 {
	@override
	final String sysUrl;
	@override
	final String imageUrl;

	Site8Kun({
		required super.baseUrl,
		required super.basePath,
		required this.sysUrl,
		required this.imageUrl,
		required super.name,
		required super.formBypass,
		required super.imageThumbnailExtension,
		required super.overrideUserAgent,
		required super.boardsWithHtmlOnlyFlags,
		required super.boardsWithMemeFlags,
		required super.archives,
		super.faviconPath,
		super.boardsPath,
		super.boards,
		super.defaultUsername
	});

	@override
	Uri getAttachmentUrl(String board, String filename) => Uri.https(imageUrl, '/file_store/$filename');

	@override
	Uri getThumbnailUrl(String board, String filename) => Uri.https(imageUrl, '/file_store/thumb/$filename');

	/// 8kun reuses same image ID for reports. So need to make it unique within thread
	@override
	String getAttachmentId(int postId, String imageId) => '${postId}_$imageId';

	@override
	Future<List<ImageboardBoard>> getBoards({required RequestPriority priority, CancelToken? cancelToken}) async {
		final response = await client.getUri(Uri.https(sysUrl, '/board-search.php'), options: Options(
			responseType: ResponseType.plain,
			extra: {
				kPriority: priority
			},
			// Needed to allow multiple interception
			validateStatus: (_) => true
		), cancelToken: cancelToken);
		if (response.statusCode != 200) {
			throw HTTPStatusException.fromResponse(response);
		}
		return (jsonDecode(response.data as String)['boards'] as Map).cast<String, Map>().entries.map((board) => ImageboardBoard(
			name: board.key,
			title: board.value['title'] as String,
			isWorksafe: board.value['sfw'] == 1,
			webmAudioAllowed: true,
			popularity: switch (board.value['posts_total']) {
				int count => count,
				String str => int.tryParse(str),
				_ => null
			}
		)).toList();
	}

	@override
	ImageboardBoardPopularityType? get boardPopularityType => ImageboardBoardPopularityType.postsCount;

	@override
	Future<List<ImageboardBoard>> getBoardsForQuery(String query) async {
		final response = await client.getUri(Uri.https(sysUrl, '/board-search.php', {
			'lang': '',
			'tags': '',
			'title': query,
			'sfw': '0'
		}), options: Options(
			responseType: ResponseType.plain,
			extra: {
				kPriority: RequestPriority.interactive
			},
			// Needed to allow multiple interception
			validateStatus: (_) => true
		));
		if (response.statusCode != 200) {
			throw HTTPStatusException.fromResponse(response);
		}
		return (jsonDecode(response.data as String)['boards'] as Map).cast<String, Map>().entries.map((board) => ImageboardBoard(
			name: board.key,
			title: board.value['title'] as String,
			isWorksafe: board.value['sfw'] == 1,
			webmAudioAllowed: true,
			popularity: switch (board.value['posts_total']) {
				int count => count,
				String str => int.tryParse(str),
				_ => null
			}
		)).toList();
	}

	@override
	Future<void> updatePostingFields(DraftPost post, Map<String, dynamic> fields, CancelToken? cancelToken) async {
		fields['domain_name_post'] = baseUrl;
		fields['tor'] = 'null';
	}

	@override
	@protected
	ImageboardFlag? makeFlag(dynamic data) {
		if ((data['country'], data['country_name']) case (String code, String name)) {
			return ImageboardFlag(
				name: name,
				imageUrl: Uri.https(imageUrl, '$basePath/static/flags/${code.toLowerCase()}.png').toString(),
				imageWidth: 16,
				imageHeight: 11
			);
		}
		return null;
	}

	@override
	String get siteType => '8kun';
	@override
	String get siteData => baseUrl;

	@override
	bool operator == (Object other) =>
		identical(this, other) ||
		(other is Site8Kun) &&
		(other.baseUrl == baseUrl) &&
		(other.basePath == basePath) &&
		(other.sysUrl == sysUrl) &&
		(other.imageUrl == imageUrl) &&
		(other.name == name) &&
		(other.overrideUserAgent == overrideUserAgent) &&
		listEquals(other.archives, archives) &&
		(other.faviconPath == faviconPath) &&
		(other.defaultUsername == defaultUsername) &&
		(other.boardsPath == boardsPath) &&
		mapEquals(other.formBypass, formBypass) &&
		(other.imageThumbnailExtension == imageThumbnailExtension) &&
		(other.boardsPath == boardsPath) &&
		(other.faviconPath == faviconPath) &&
		listEquals(other.boards, boards) &&
		listEquals(other.boardsWithHtmlOnlyFlags, boardsWithHtmlOnlyFlags) &&
		listEquals(other.boardsWithMemeFlags, boardsWithMemeFlags);

	@override
	int get hashCode => Object.hash(baseUrl, basePath, sysUrl, imageUrl);
}