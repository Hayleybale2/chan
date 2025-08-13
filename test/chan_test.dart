import 'dart:async';
import 'dart:io';
import 'dart:math';

import 'package:chan/models/board.dart';
import 'package:chan/models/thread.dart';
import 'package:chan/services/compress_html.dart';
import 'package:chan/services/imageboard.dart';
import 'package:chan/services/json_cache.dart';
import 'package:chan/services/persistence.dart';
import 'package:chan/services/priority_queue.dart';
import 'package:chan/services/streaming_mp4.dart';
import 'package:chan/services/util.dart';
import 'package:chan/sites/jforum.dart';
import 'package:chan/sites/lainchan2.dart';
import 'package:flutter/foundation.dart';
import 'package:test/test.dart';
import 'package:chan/util.dart';

bool id(bool x) => x;

void main() async {
  await Persistence.initializeForTesting();
  final sites = await JsonCache.instance.sites.updater();
  group('BinarySearch', () {
    test('firstwhere', () {
      for (int length = 1; length < 90; length++) {
        for (int switchpoint = 0; switchpoint <= length; switchpoint++) {
          final List<bool> list = List.generate(length, (i) => i >= switchpoint);
          expect(list.binarySearchFirstIndexWhere(id), switchpoint == length ? -1 : switchpoint);
        }
      }
    });
    test('lastwhere', () {
      for (int length = 1; length < 90; length++) {
        for (int switchpoint = 0; switchpoint <= length; switchpoint++) {
          final List<bool> list = List.generate(length, (i) => i <= switchpoint);
          expect(list.binarySearchLastIndexWhere(id), switchpoint == length ? length - 1 : switchpoint);
        }
      }
    });
  });

  group('insertIntoSortedList', () {
    test('test1', () {
      final methods = <Comparator<String>>[
        (a, b) => a.substring(1, 2).compareTo(b.substring(1, 2)),
        (a, b) => a.substring(0, 1).compareTo(b.substring(0, 1))
      ];
      final list = ['01a', '02', '10'];
      insertIntoSortedList(list: list, sortMethods: methods, reverseSort: false, item: '03');
      expect(listEquals(list, ['01a', '02', '03', '10']), isTrue);
      insertIntoSortedList(list: list, sortMethods: methods, reverseSort: false, item: '00');
      expect(listEquals(list, ['00', '01a', '02', '03', '10']), isTrue);
      insertIntoSortedList(list: list, sortMethods: methods, reverseSort: false, item: '20');
      expect(listEquals(list, ['00', '01a', '02', '03', '10', '20']), isTrue);
      insertIntoSortedList(list: list, sortMethods: methods, reverseSort: false, item: '01b');
      expect(listEquals(list, ['00', '01b', '01a', '02', '03', '10', '20']), isTrue);
    });
  });

  group('decodeUrl and toWebUrl', () {
    for (final siteEntry in sites.entries) {
      test(siteEntry.key, () async {
        final imageboard = Imageboard(key: siteEntry.key, siteData: siteEntry.value);
        await imageboard.initialize(forTesting: true);
        final site = imageboard.site;
        for (final b in [
          if (!site.supportsMultipleBoards) ''
          else if (site is SiteJForum) ...[
            '1.a',
            '2.fdsa',
            '3.λ'
          ]
          else ...[
            'a',
            'fdsa',
            'λ'
          ]
        ]) {
          for (final id in [
            if (site.supportsMultipleBoards) BoardThreadOrPostIdentifier(b),
            BoardThreadOrPostIdentifier(b, 1234 + b.hashCode),
            // Hacker news would need network lookup to find the OP
            if (site.supportsMultipleBoards) BoardThreadOrPostIdentifier(b, 2345 + b.hashCode, 6789),
            if (site.isPaged) BoardThreadOrPostIdentifier(b, 2345 + b.hashCode, -10)
          ]) {
            // Hack around network request need by attempting to prepopulate data
            await imageboard.persistence.setBoard(id.board, ImageboardBoard(
              name: id.board,
              title: 'Fake board "${id.board}"',
              isWorksafe: false,
              webmAudioAllowed: false
            ));
            await Persistence.sharedThreadStateBox.put(
              '${imageboard.key}/${ImageboardBoard.getKey(id.board)}/${id.threadId ?? 0}',
              PersistentThreadState(
                imageboardKey: imageboard.key,
                board: id.board,
                id: id.threadId ?? 0,
                showInHistory: true
              )
            );
            final url = site.getWebUrl(board: id.board, threadId: id.threadId, postId: id.postId);
            expect(await site.decodeUrl(Uri.parse(url)), id);
            for (final archive in site.archives) {
              final url = archive.getWebUrl(board: id.board, threadId: id.threadId, postId: id.postId);
              expect(await archive.decodeUrl(Uri.parse(url)), id);
            }
          }
        }
      });
    }
  });

  group('Lainchan RegExes', () {
    test('decodeUrl', () async {
      final site = SiteLainchan2(
        baseUrl: 'example.com',
        name: 'example',
        overrideUserAgent: null,
        archives: const [],
        imageHeaders: const {},
        videoHeaders: const {},
        turnstileSiteKey: null,
        basePath: '',
        formBypass: const {},
        imageThumbnailExtension: null,
        boardsWithHtmlOnlyFlags: const [],
        boardsWithMemeFlags: const [],
        res: 'res'
      );
      expect(await site.decodeUrl(Uri.https('example.com', '/')), null);
      expect(await site.decodeUrl(Uri.https('example.com', '/board/')), BoardThreadOrPostIdentifier('board'));
      expect(await site.decodeUrl(Uri.https('example.com', '/board/0.json')), null);
      expect(await site.decodeUrl(Uri.https('example.com', '/board/res/1234.html')), BoardThreadOrPostIdentifier('board', 1234));
      expect(await site.decodeUrl(Uri.https('example.com', '/board/res/1234.json')), null);
      expect(await site.decodeUrl(Uri.https('example.com', '/board/res/1234.html').replace(fragment: 'q1235')), BoardThreadOrPostIdentifier('board', 1234, 1235));
      expect(await site.decodeUrl(Uri.https('example.com', '/board/res/1234.html', {'also': 'yes'}).replace(fragment: 'q1235')), BoardThreadOrPostIdentifier('board', 1234, 1235));
    });
  });

  group('HTML compressor', () {
    test('compress', () {
      const html = '<a href="https://example.com">https://example.com</a><br><span>&gt;&gt;12345678</span>';
      final compressed = compressHTML(html);
      expect(compressed.html, '<c><d></d></c><br></br><e><f></f></e>');
      expect(compressed.decompressTranslation(compressed.html), html);
    });
  });

  group('Caching server', () {
    test('normal', () async {
      final root = await Directory.current.createTemp('caching_server_');
      VideoServer.initializeStatic(root, root, port: 4071, bufferOutput: false);
      final fakeServer = await HttpServer.bind(InternetAddress.loopbackIPv4, 0);
      final client = HttpClient();
      final requests = <HttpRequest>[];
      fakeServer.listen((request) {
        requests.add(request);
      });
      try {
        final digestFuture = VideoServer.instance.startCachingDownload(uri: (Uri.http('localhost:${fakeServer.port}')));
        await Future.delayed(const Duration(milliseconds: 100));
        expect(requests.length, equals(1));
        requests[0].response.bufferOutput = false;
        requests[0].response.contentLength = 10000;
        requests[0].response.add(Uint8List(1000));
        await requests[0].response.flush();
        final digest = await digestFuture;
        final clientRequest = await client.getUrl(VideoServer.instance.getUri(digest));
        clientRequest.bufferOutput = false;
        final response = await clientRequest.close();
        await Future.delayed(const Duration(milliseconds: 100));
        expect(response.contentLength, equals(10000));
        expect(response.statusCode, equals(200));
        final chunks = <List<int>>[];
        bool responseStreamSubscriptionIsDone = false;
        response.listen(chunks.add, onDone: () {
          responseStreamSubscriptionIsDone = true;
        });
        await Future.delayed(const Duration(milliseconds: 100));
        expect(chunks.length, equals(1));
        expect(chunks[0].length, equals(1000));
        requests[0].response.add(Uint8List(9000));
        await requests[0].response.flush();
        await Future.delayed(const Duration(milliseconds: 100));
        expect(chunks.length, equals(2));
        expect(chunks[1].length, equals(9000));
        await requests[0].response.close();
        await Future.delayed(const Duration(milliseconds: 100));
        expect(chunks.length, equals(2));
        expect(responseStreamSubscriptionIsDone, isTrue);
        final file = VideoServer.instance.getFile(digest);
        expect(await file.exists(), isTrue);
        expect(await file.length(), equals(10000));
        // Try a second request, it shouldn't hit the original server, and should return all in one chunk.
        final clientRequest2 = await client.getUrl(VideoServer.instance.getUri(digest));
        clientRequest2.bufferOutput = false;
        final response2 = await clientRequest2.close();
        chunks.clear();
        responseStreamSubscriptionIsDone = false;
        response2.listen(chunks.add, onDone: () {
          responseStreamSubscriptionIsDone = true;
        });
        await Future.delayed(const Duration(milliseconds: 100));
        expect(response.contentLength, equals(10000));
        expect(response.statusCode, equals(200));
        await Future.delayed(const Duration(milliseconds: 100));
        expect(chunks.length, equals(1));
        expect(chunks[0].length, equals(10000));
        expect(responseStreamSubscriptionIsDone, isTrue);
        expect(requests.length, equals(1));
        // Now delete the file and check that another request is issued
        await file.delete();
        final future2 = VideoServer.instance.startCachingDownload(uri: (Uri.http('localhost:${fakeServer.port}')));
        await Future.delayed(const Duration(milliseconds: 100));
        expect(requests.length, equals(2));
        requests[1].response.bufferOutput = false;
        requests[1].response.contentLength = 10000;
        requests[1].response.add(Uint8List(10000));
        await requests[0].response.close();
        await future2;
        final clientRequest3 = await client.getUrl(VideoServer.instance.getUri(digest));
        clientRequest3.bufferOutput = false;
        final response3 = await clientRequest3.close();
        chunks.clear();
        responseStreamSubscriptionIsDone = false;
        response3.listen(chunks.add, onDone: () {
          responseStreamSubscriptionIsDone = true;
        });
        await Future.delayed(const Duration(milliseconds: 100));
        expect(response3.contentLength, equals(10000));
        expect(response3.statusCode, equals(200));
        await Future.delayed(const Duration(milliseconds: 100));
        expect(chunks.length, equals(1));
        expect(chunks[0].length, equals(10000));
        expect(responseStreamSubscriptionIsDone, isTrue);
        expect(await file.exists(), isTrue);
        expect(await file.length(), equals(10000));
      }
      finally {
        await root.delete(recursive: true);
        fakeServer.close();
        VideoServer.teardownStatic();
      }
    });

    test('status code 404', () async {
      final root = await Directory.current.createTemp('caching_server_');
      VideoServer.initializeStatic(root, root, port: 4071, bufferOutput: false);
      final fakeServer = await HttpServer.bind(InternetAddress.loopbackIPv4, 0);
      final client = HttpClient();
      final requests = <HttpRequest>[];
      fakeServer.listen((request) {
        requests.add(request);
      });
      try {
        final digestFuture0 = VideoServer.instance.startCachingDownload(uri: (Uri.http('localhost:${fakeServer.port}')));
        await Future.delayed(const Duration(milliseconds: 100));
        expect(requests.length, equals(1));
        requests[0].response.bufferOutput = false;
        requests[0].response.statusCode = 404;
        requests[0].response.contentLength = 10000;
        requests[0].response.add(Uint8List(1000));
        await requests[0].response.flush();
        try {
          await digestFuture0;
          throw Exception('Did not get expected exception');
        }
        on HTTPStatusException catch (e) {
          expect(e.code, 404);
        }
        final digestFuture1 = VideoServer.instance.startCachingDownload(uri: (Uri.http('localhost:${fakeServer.port}')));
        await Future.delayed(const Duration(milliseconds: 100));
        expect(requests.length, equals(2));
        requests[1].response.bufferOutput = false;
        requests[1].response.statusCode = 200;
        requests[1].response.contentLength = 10000;
        requests[1].response.add(Uint8List(1000));
        await requests[0].response.flush();
        final digest = await digestFuture1;
        final clientRequest = await client.getUrl(VideoServer.instance.getUri(digest));
        clientRequest.bufferOutput = false;
        final response = await clientRequest.close();
        await Future.delayed(const Duration(milliseconds: 100));
        expect(response.contentLength, equals(10000));
        expect(response.statusCode, equals(200));
        final chunks = <List<int>>[];
        bool responseStreamSubscriptionIsDone = false;
        response.listen(chunks.add, onDone: () {
          responseStreamSubscriptionIsDone = true;
        });
        await Future.delayed(const Duration(milliseconds: 100));
        expect(chunks.length, equals(1));
        expect(chunks[0].length, equals(1000));
        requests[1].response.add(Uint8List(9000));
        await requests[1].response.flush();
        await Future.delayed(const Duration(milliseconds: 100));
        expect(chunks.length, equals(2));
        expect(chunks[1].length, equals(9000));
        await requests[1].response.close();
        await Future.delayed(const Duration(milliseconds: 100));
        expect(chunks.length, equals(2));
        expect(responseStreamSubscriptionIsDone, isTrue);
        final file = VideoServer.instance.getFile(digest);
        expect(await file.exists(), isTrue);
        expect(await file.length(), equals(10000));
        // Try again
        final clientRequest2 = await client.getUrl(VideoServer.instance.getUri(digest));
        clientRequest2.bufferOutput = false;
        final response2 = await clientRequest2.close();
        chunks.clear();
        responseStreamSubscriptionIsDone = false;
        response2.listen(chunks.add, onDone: () {
          responseStreamSubscriptionIsDone = true;
        });
        await Future.delayed(const Duration(milliseconds: 100));
        expect(response2.contentLength, equals(10000));
        expect(response2.statusCode, equals(200));
        await Future.delayed(const Duration(milliseconds: 100));
        expect(chunks.length, equals(1));
        expect(chunks[0].length, equals(10000));
        expect(responseStreamSubscriptionIsDone, isTrue);
        expect(requests.length, equals(2));
      }
      finally {
        await root.delete(recursive: true);
        fakeServer.close();
        VideoServer.teardownStatic();
      }
    });

    test('incomplete', () async {
      final root = await Directory.current.createTemp('caching_server_');
      final fakeServer = await HttpServer.bind(InternetAddress.loopbackIPv4, 0);
      final client = HttpClient();
      final requests = <HttpRequest>[];
      fakeServer.listen((request) {
        requests.add(request);
      });
      try {
        VideoServer.initializeStatic(root, root, port: 4071, bufferOutput: false);
        final digestFuture = VideoServer.instance.startCachingDownload(uri: (Uri.http('localhost:${fakeServer.port}')));
        await Future.delayed(const Duration(milliseconds: 100));
        expect(requests.length, equals(1));
        requests[0].response.bufferOutput = false;
        requests[0].response.contentLength = 10000;
        requests[0].response.add(Uint8List(1000));
        await requests[0].response.flush();
        final digest = await digestFuture;
        final clientRequest = await client.getUrl(VideoServer.instance.getUri(digest));
        clientRequest.bufferOutput = false;
        final response = await clientRequest.close();
        await Future.delayed(const Duration(milliseconds: 100));
        expect(response.contentLength, equals(10000));
        final chunks = <List<int>>[];
        bool responseStreamSubscriptionIsErrored = false;
        response.listen(chunks.add, onError: (e) {
          responseStreamSubscriptionIsErrored = true;
        });
        await Future.delayed(const Duration(milliseconds: 100));
        expect(chunks.length, equals(1));
        expect(chunks[0].length, equals(1000));
        try {
          await requests[0].response.close();
        }
        on HttpException {
          // Expected, we are prematurely closing the stream
        }
        await Future.delayed(const Duration(milliseconds: 200));
        expect(chunks.length, equals(1));
        expect(responseStreamSubscriptionIsErrored, isTrue);
        final file = VideoServer.instance.getFile(digest);
        expect(await file.exists(), isFalse);
      }
      finally {
        await root.delete(recursive: true);
        fakeServer.close();
        VideoServer.teardownStatic();
      }
    });

    test('content', () async {
      final root = await Directory.current.createTemp('caching_server_');
      VideoServer.initializeStatic(root, root, port: 4071, bufferOutput: false);
      final fakeServer = await HttpServer.bind(InternetAddress.loopbackIPv4, 0);
      final client = HttpClient();
      final requests = <HttpRequest>[];
      fakeServer.listen((request) {
        requests.add(request);
      });
      try {
        const int kLength = 10000;
        final random = Random();
        final buffer = Uint8List.fromList(List.generate(kLength, (i) => random.nextInt(256)));
        final digestFuture = VideoServer.instance.startCachingDownload(uri: (Uri.http('localhost:${fakeServer.port}')));
        await Future.delayed(const Duration(milliseconds: 100));
        expect(requests.length, equals(1));
        requests[0].response.bufferOutput = false;
        requests[0].response.contentLength = kLength;
        requests[0].response.add(buffer.sublist(0, 10));
        await requests[0].response.flush();
        final digest = await digestFuture;
        final clientRequest = await client.getUrl(VideoServer.instance.getUri(digest));
        clientRequest.bufferOutput = false;
        const int rangeStart = 1;
        final rangeEndInclusive = 1 + random.nextInt(kLength ~/ 3) + kLength ~/ 2;
        clientRequest.headers.set(HttpHeaders.rangeHeader, 'bytes=$rangeStart-$rangeEndInclusive');
        await requests[0].response.flush();
        final response = await clientRequest.close();
        await Future.delayed(const Duration(milliseconds: 100));
        expect(response.contentLength, equals(1 + rangeEndInclusive - rangeStart));
        expect(response.statusCode, equals(206));
        final toListFuture = response.toList();
        int i = 10;
        while (i < kLength) {
          final chunkSize = random.nextInt(50);
          requests[0].response.add(buffer.sublist(i, min(i + chunkSize, kLength)));
          await requests[0].response.flush();
          i += chunkSize;
        }
        await requests[0].response.close();
        await Future.delayed(const Duration(milliseconds: 100));
        final file = VideoServer.instance.getFile(digest);
        expect(await file.exists(), isTrue);
        expect(await file.length(), equals(10000));
        final outputBuffer = (await toListFuture).expand((x) => x).toList();
        expect(outputBuffer, equals(buffer.sublist(rangeStart, rangeEndInclusive + 1)));
      }
      finally {
        await root.delete(recursive: true);
        fakeServer.close();
        VideoServer.teardownStatic();
      }
    });

    test('Sibling', () async {
      final root = await Directory.current.createTemp('caching_server_');
      VideoServer.initializeStatic(root, root, port: 4071, bufferOutput: false);
      final fakeServer = await HttpServer.bind(InternetAddress.loopbackIPv4, 0);
      final client = HttpClient();
      final requests = <HttpRequest>[];
      fakeServer.listen((request) {
        requests.add(request);
      });
      try {
        final uri1 = Uri.http('localhost:${fakeServer.port}', '/Dir1/File1.ext1');
        final digestFuture = VideoServer.instance.startCachingDownload(uri: uri1);
        await Future.delayed(const Duration(milliseconds: 100));
        expect(requests.length, equals(1));
        expect(requests[0].requestedUri.path, equals('/Dir1/File1.ext1'));
        requests[0].response.bufferOutput = false;
        requests[0].response.contentLength = 10000;
        requests[0].response.add(Uint8List(1000));
        await requests[0].response.flush();
        final digest = await digestFuture;
        final clientRequest = await client.getUrl(VideoServer.instance.getUri(digest));
        expect(VideoServer.instance.getUri(digest).path, endsWith('.ext1'));
        clientRequest.bufferOutput = false;
        final response = await clientRequest.close();
        await Future.delayed(const Duration(milliseconds: 100));
        expect(response.contentLength, equals(10000));
        expect(response.statusCode, equals(200));
        final chunks = <List<int>>[];
        bool responseStreamSubscriptionIsDone = false;
        response.listen(chunks.add, onDone: () {
          responseStreamSubscriptionIsDone = true;
        });
        await Future.delayed(const Duration(milliseconds: 100));
        expect(chunks.length, equals(1));
        expect(chunks[0].length, equals(1000));
        requests[0].response.add(Uint8List(9000));
        await requests[0].response.flush();
        await Future.delayed(const Duration(milliseconds: 100));
        expect(chunks.length, equals(2));
        expect(chunks[1].length, equals(9000));
        await requests[0].response.close();
        await Future.delayed(const Duration(milliseconds: 100));
        expect(chunks.length, equals(2));
        expect(responseStreamSubscriptionIsDone, isTrue);
        final file = VideoServer.instance.getFile(digest);
        expect(await file.exists(), isTrue);
        expect(await file.length(), equals(10000));
        // Now try a file relative to the first URI
        final uri2 = VideoServer.instance.getUri(digest).resolve('./File2.ext2');
        final clientRequest2 = await client.getUrl(uri2);
        clientRequest2.bufferOutput = false;
        final clientRequest2Future = clientRequest2.close();
        await Future.delayed(const Duration(milliseconds: 100));
        expect(requests.length, equals(2));
        expect(requests[1].requestedUri.path, equals('/Dir1/File2.ext2'));
        requests[1].response.bufferOutput = false;
        requests[1].response.contentLength = 300;
        requests[1].response.add(Uint8List(100));
        await requests[1].response.flush();
        final response2 = await clientRequest2Future;
        bool response2StreamSubscriptionIsDone = false;
        final chunks2 = <List<int>>[];
        response2.listen(chunks2.add, onDone: () {
          response2StreamSubscriptionIsDone = true;
        });
        await Future.delayed(const Duration(milliseconds: 100));
        expect(chunks2.length, equals(1));
        expect(chunks2[0].length, equals(100));
        requests[1].response.add(Uint8List(200));
        await requests[1].response.close();
        await Future.delayed(const Duration(milliseconds: 100));
        expect(chunks2.length, equals(2));
        expect(chunks2[1].length, equals(200));
        expect(response2StreamSubscriptionIsDone, isTrue);
        final file2 = VideoServer.instance.optimisticallyGetFile(uri1.resolve('./File2.ext2'))!;
        expect(await file2.exists(), isTrue);
        expect(await file2.length(), equals(300));
        await VideoServer.instance.cleanupCachedDownloadTree(digest);
        expect(await file.exists(), isFalse);
        expect(await file2.exists(), isFalse);
      }
      finally {
        await root.delete(recursive: true);
        fakeServer.close();
        VideoServer.teardownStatic();
      }
    });

    test('incomplete m3u8', () async {
      final root = await Directory.current.createTemp('caching_server_');
      final fakeServer = await HttpServer.bind(InternetAddress.loopbackIPv4, 0);
      final requests = <HttpRequest>[];
      fakeServer.listen((request) {
        requests.add(request);
      });
      try {
        VideoServer.initializeStatic(root, root, port: 4071, bufferOutput: false);
        String? digest;
        bool digestErrored = false;
        VideoServer.instance.startCachingDownload(uri: (Uri.http('localhost:${fakeServer.port}', '/test.m3u8'))).then((h) {
          digest = h;
        }).catchError((e) {
          digestErrored = true;
        });
        await Future.delayed(const Duration(milliseconds: 100));
        expect(requests.length, equals(1));
        requests[0].response.bufferOutput = false;
        requests[0].response.contentLength = 10000;
        requests[0].response.add(Uint8List(1000));
        await requests[0].response.flush();
        try {
          await requests[0].response.close();
        }
        on HttpException {
          // Expected, we are prematurely closing the stream
        }
        await Future.delayed(const Duration(milliseconds: 100));
        expect(digest, isNull);
        expect(digestErrored, isTrue);
      }
      finally {
        await root.delete(recursive: true);
        fakeServer.close();
        VideoServer.teardownStatic();
      }
    });

    test('Sibling incomplete m3u8s', () async {
      final root = await Directory.current.createTemp('caching_server_');
      VideoServer.initializeStatic(root, root, port: 4071, bufferOutput: false);
      final fakeServer = await HttpServer.bind(InternetAddress.loopbackIPv4, 0);
      final client = HttpClient();
      final requests = <HttpRequest>[];
      fakeServer.listen((request) {
        requests.add(request);
      });
      try {
        final uri1 = Uri.http('localhost:${fakeServer.port}', '/Dir1/File1.ext1');
        final digestFuture = VideoServer.instance.startCachingDownload(uri: uri1);
        await Future.delayed(const Duration(milliseconds: 100));
        expect(requests.length, equals(1));
        expect(requests[0].requestedUri.path, equals('/Dir1/File1.ext1'));
        requests[0].response.bufferOutput = false;
        requests[0].response.contentLength = 10000;
        requests[0].response.add(Uint8List(1000));
        await requests[0].response.flush();
        final digest = await digestFuture;
        final clientRequest = await client.getUrl(VideoServer.instance.getUri(digest));
        expect(VideoServer.instance.getUri(digest).path, endsWith('.ext1'));
        clientRequest.bufferOutput = false;
        final response = await clientRequest.close();
        await Future.delayed(const Duration(milliseconds: 100));
        expect(response.contentLength, equals(10000));
        expect(response.statusCode, equals(200));
        final chunks = <List<int>>[];
        bool responseStreamSubscriptionIsDone = false;
        response.listen(chunks.add, onDone: () {
          responseStreamSubscriptionIsDone = true;
        });
        await Future.delayed(const Duration(milliseconds: 100));
        expect(chunks.length, equals(1));
        expect(chunks[0].length, equals(1000));
        requests[0].response.add(Uint8List(9000));
        await requests[0].response.flush();
        await Future.delayed(const Duration(milliseconds: 100));
        expect(chunks.length, equals(2));
        expect(chunks[1].length, equals(9000));
        await requests[0].response.close();
        await Future.delayed(const Duration(milliseconds: 100));
        expect(chunks.length, equals(2));
        expect(responseStreamSubscriptionIsDone, isTrue);
        final file = VideoServer.instance.getFile(digest);
        expect(await file.exists(), isTrue);
        expect(await file.length(), equals(10000));
        // Now try a m3u8 file relative to the first URI
        final uri2 = VideoServer.instance.getUri(digest).resolve('./File2.m3u8');
        final clientRequest2 = await client.getUrl(uri2);
        clientRequest2.bufferOutput = false;
        final clientRequest2Future = clientRequest2.close();
        await Future.delayed(const Duration(milliseconds: 100));
        expect(requests.length, equals(2));
        expect(requests[1].requestedUri.path, equals('/Dir1/File2.m3u8'));
        requests[1].response.bufferOutput = false;
        requests[1].response.contentLength = 300;
        requests[1].response.add(Uint8List(100));
        await requests[1].response.flush();
        try {
          await requests[1].response.close();
        }
        on HttpException {
          // Expected, we are prematurely closing the stream
        }
        final response2 = await clientRequest2Future;
        expect(response2.statusCode, equals(502));
        bool response2StreamSubscriptionIsDone = false;
        bool response2StreamSubscriptionIsErrored = false;
        final chunks2 = <List<int>>[];
        response2.listen(chunks2.add, onDone: () {
          response2StreamSubscriptionIsDone = true;
        }, onError: () {
          response2StreamSubscriptionIsErrored = true;
        });
        await Future.delayed(const Duration(milliseconds: 100));
        expect(chunks2.length, equals(0));
        expect(response2StreamSubscriptionIsDone, isTrue);
        expect(response2StreamSubscriptionIsErrored, isFalse);
        final file2 = VideoServer.instance.optimisticallyGetFile(uri1.resolve('./File2.m3u8'))!;
        expect(await file2.exists(), isFalse);
      }
      finally {
        await root.delete(recursive: true);
        fakeServer.close();
        VideoServer.teardownStatic();
      }
    });

    test('interruptOngoingDownload', () async {
      final root = await Directory.current.createTemp('caching_server_');
      final fakeServer = await HttpServer.bind(InternetAddress.loopbackIPv4, 0);
      final client = HttpClient();
      final requests = <HttpRequest>[];
      fakeServer.listen((request) {
        requests.add(request);
      });
      try {
        VideoServer.initializeStatic(root, root, port: 4071, bufferOutput: false, insignificantByteThreshold: 0);
        final url = Uri.http('localhost:${fakeServer.port}');
        final digestFuture = VideoServer.instance.startCachingDownload(uri: url, interruptible: true);
        await Future.delayed(const Duration(milliseconds: 100));
        expect(requests[0].method, equals('GET'));
        requests[0].response.bufferOutput = false;
        requests[0].response.contentLength = 10000;
        requests[0].response.add(Uint8List(1000));
        await requests[0].response.flush();
        final digest = await digestFuture;
        final clientRequest = await client.getUrl(VideoServer.instance.getUri(digest));
        clientRequest.bufferOutput = false;
        final response = await clientRequest.close();
        await Future.delayed(const Duration(milliseconds: 100));
        expect(response.contentLength, equals(10000));
        final chunks = <List<int>>[];
        bool responseStreamSubscriptionIsErrored = false;
        bool responseStreamSubscriptionIsDone = false;
        response.listen(chunks.add, onError: (e) {
          responseStreamSubscriptionIsErrored = true;
        }, onDone: () {
          responseStreamSubscriptionIsDone = true;
        });
        await Future.delayed(const Duration(milliseconds: 100));
        expect(chunks.length, equals(1));
        expect(chunks[0].length, equals(1000));
        await VideoServer.instance.interruptOngoingDownloadFromUri(url);
        await Future.delayed(const Duration(milliseconds: 200));
        requests[0].response.add(Uint8List(9000));
        await requests[0].response.close();
        await Future.delayed(const Duration(milliseconds: 200));
        expect(chunks.length, equals(1));
        expect(responseStreamSubscriptionIsDone, isTrue);
        expect(responseStreamSubscriptionIsErrored, isTrue);
        await Future.delayed(const Duration(milliseconds: 200));
        final digestFuture2 = VideoServer.instance.startCachingDownload(uri: url, interruptible: true);
        await Future.delayed(const Duration(milliseconds: 100));
        expect(requests.length, equals(2));
        expect(requests[1].method, equals('HEAD'));
        requests[1].response.bufferOutput = false;
        requests[1].response.contentLength = 10000;
        await requests[1].response.close();
        await Future.delayed(const Duration(milliseconds: 100));
        expect(requests.length, equals(3));
        expect(requests[2].method, equals('GET'));
        expect(requests[2].headers.value(HttpHeaders.rangeHeader), equals('bytes=1000-'));
        requests[2].response.bufferOutput = false;
        requests[2].response.contentLength = 9000;
        requests[2].response.add(Uint8List(1));
        await requests[2].response.flush();
        final digest2 = await digestFuture2;
        final clientRequest2 = await client.getUrl(VideoServer.instance.getUri(digest2));
        clientRequest2.bufferOutput = false;
        final response2 = await clientRequest2.close();
        await Future.delayed(const Duration(milliseconds: 100));
        expect(response2.contentLength, equals(10000));
        final chunks2 = <List<int>>[];
        bool response2StreamSubscriptionIsErrored = false;
        bool response2StreamSubscriptionIsDone = false;
        response2.listen(chunks2.add, onError: (e) {
          response2StreamSubscriptionIsErrored = true;
        }, onDone: () {
          response2StreamSubscriptionIsDone = true;
        });
        await Future.delayed(const Duration(milliseconds: 100));
        expect(chunks2.length, equals(1));
        expect(chunks2[0].length, equals(1001));
        requests[2].response.add(Uint8List(8999));
        await requests[2].response.close();
        await Future.delayed(const Duration(milliseconds: 100));
        expect(chunks2.length, equals(2));
        expect(chunks2[1].length, equals(8999));
        expect(response2StreamSubscriptionIsDone, isTrue);
        expect(response2StreamSubscriptionIsErrored, isFalse);
      }
      finally {
        await root.delete(recursive: true);
        fakeServer.close();
        VideoServer.teardownStatic();
      }
    });
  });

  group('PriorityQueue', () {
    test('basic', () async {
      final q = PriorityQueue<(String, String), String>(groupKeyer: (k) => k.$1);
      // Both should start (start in parallel mode)
      const a = ('1', 'a');
      const b = ('1', 'b');
      await q.start(a);
      await q.start(b);
      bool d1a = false;
      q.delay(a, const Duration(seconds: 1)).then((_) => d1a = true);
      bool d2b = false;
      q.delay(b, const Duration(seconds: 2)).then((_) => d2b = true);
      const c = ('1', 'c');
      bool sc = false;
      q.start(c).then((_) => sc = true);
      // The delay should be extended
      await Future.delayed(const Duration(milliseconds: 1100));
      expect(d1a, isFalse);
      expect(d2b, isFalse);
      expect(sc, isFalse);
      await Future.delayed(const Duration(seconds: 1));
      expect(d1a, isTrue);
      expect(d2b, isFalse);
      expect(sc, isFalse);
      await q.end(a);
      await Future.delayed(Duration.zero);
      expect(d2b, isTrue);
      expect(sc, isFalse);
      await q.end(b);
      await Future.delayed(Duration.zero);
      expect(sc, isTrue);
      await q.end(c);
      // Should be back in parallel mode
      const d = ('1', 'd');
      const e = ('1', 'e');
      const f = ('1', 'f');
      await q.start(d);
      await q.start(e);
      await q.end(d);
      await q.start(f);
      await q.end(e);
      await q.end(f);
      q.dispose();
    });
  });

  test('FileBasename', () {
    expect(FileBasename.get('asdf///'), 'asdf');
    expect(FileBasename.get('/'), '/');
    expect(FileBasename.get('a//'), 'a');
    expect(FileBasename.get('asdf'), 'asdf');
    expect(FileBasename.get('/f/g/b/c'), 'c');
  });

  test('debounce', () async {
    int retval = 0;
    final debouncer = Debouncer1((int x) async {
      final r = retval;
      await Future.delayed(Duration(milliseconds: x));
      return r;
    });
    final f1 = debouncer.debounce(100);
    retval = 1;
    await Future.delayed(const Duration(milliseconds: 50));
    final f2 = debouncer.debounce(100);
    await Future.delayed(const Duration(milliseconds: 51));
    final v1 = await f1;
    expect(v1, equals(0));
    final v2 = await f2;
    expect(v2, equals(0));
    final v3 = await debouncer.debounce(100);
    expect(v3, equals(1));
  });
}