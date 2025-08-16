

import 'dart:async';
import 'dart:io';
import 'dart:math';

import 'package:chan/models/board.dart';
import 'package:chan/models/post.dart';
import 'package:chan/models/thread.dart';
import 'package:chan/pages/cookie_browser.dart';
import 'package:chan/services/captcha.dart';
import 'package:chan/services/notifications.dart';
import 'package:chan/services/outbox.dart';
import 'package:chan/services/persistence.dart';
import 'package:chan/services/settings.dart';
import 'package:chan/services/share.dart';
import 'package:chan/services/thread_watcher.dart';
import 'package:chan/services/util.dart';
import 'package:chan/sites/imageboard_site.dart';
import 'package:chan/util.dart';
import 'package:chan/widgets/adaptive.dart';
import 'package:chan/widgets/util.dart';
import 'package:dio/dio.dart' as dio;
import 'package:flutter/cupertino.dart';
import 'package:flutter/material.dart';
import 'package:mutex/mutex.dart';
import 'package:string_similarity/string_similarity.dart';

class ImageboardNotFoundException implements Exception {
	String board;
	ImageboardNotFoundException(this.board);
	@override
	String toString() => 'Imageboard not found: $board';
}

class Imageboard extends ChangeNotifier {
	Map siteData;
	ImageboardSite? _site;
	ImageboardSite get site => _site!;
	late final Persistence persistence;
	late final ThreadWatcher threadWatcher;
	late final Notifications notifications;
	(Object, StackTrace)? setupError;
	(Object, StackTrace)? boardFetchError;
	bool boardsLoading = false;
	bool initialized = false;
	bool _persistenceInitialized = false;
	bool _threadWatcherInitialized = false;
	bool _notificationsInitialized = false;
	final String key;
	bool get seemsOk => initialized && !(boardsLoading && persistence.boards.isEmpty) && setupError == null && boardFetchError == null;
	final ThreadWatcherController? threadWatcherController;

	Imageboard({
		required this.key,
		required this.siteData,
		this.threadWatcherController
	});
	
	void updateSiteData(Map siteData) {
		try {
			final newSite = makeSite(siteData);
			if (newSite != _site) {
				if (_site != null) {
					newSite.migrateFromPrevious(_site!);
					_site!.dispose();
				}
				_site = newSite;
				site.imageboard = this;
				site.initState();
				notifyListeners();
			}
		}
		catch (e, st) {
			Future.error(e, st); // Crashlytics
			setupError = (e, st);
			notifyListeners();
		}
	}

	Future<void> initialize({
		List<String> threadWatcherWatchForStickyOnBoards = const [],
		bool forTesting = false
	}) async {
		try {
			final site = _site = makeSite(siteData);
			if (forTesting) {
				site.client.interceptors.insert(0, dio.InterceptorsWrapper(
					onRequest: (options, handler) {
						handler.reject(dio.DioError(
							requestOptions: options,
							error: Exception('Not allowed to use network during test')
						));
					}
				));
			}
			persistence = Persistence(key);
			await persistence.initialize();
			site.imageboard = this;
			_persistenceInitialized = true;
			notifications = Notifications(
				imageboard: this,
				site: site
			);
			notifications.initialize(allowDeleteAll: false);
			_notificationsInitialized = true;
			if (!forTesting) {
				threadWatcher = ThreadWatcher(
					imageboardKey: key,
					site: site,
					persistence: persistence,
					notifications: notifications,
					watchForStickyOnBoards: threadWatcherWatchForStickyOnBoards,
					controller: threadWatcherController ?? ImageboardRegistry.threadWatcherController
				);
				notifications.localWatcher = threadWatcher;
				_threadWatcherInitialized = true;
				if (persistence.boards.isEmpty) {
					await setupBoards();
				}
			}
			site.initState();
			initialized = true;
			// submitPost might mutate the outbox
			for (final draft in persistence.browserState.outbox.toList(growable: false)) {
				final thread = draft.thread;
				if (thread != null) {
					// Load for [title], [isArchived]
					await persistence.getThreadStateIfExists(thread)?.ensureThreadLoaded();
				}
				Outbox.instance.submitPost(key, draft, QueueStateIdle());
			}
		}
		catch (e, st) {
			setupError = (e, st);
			print('Error initializing $key');
			print(e);
			print(st);
		}
		notifyListeners();
	}

	Future<void> deleteAllData() async {
		await notifications.deleteAllNotificationsFromServer();
		await persistence.deleteAllData();
	}

	Future<void> setupBoards() async {
		try {
			boardsLoading = true;
			boardFetchError = null;
			notifyListeners();
			final freshBoards = await site.getBoards(priority: RequestPriority.interactive);
			if (freshBoards.isEmpty) {
				throw('No boards found');
			}
			await persistence.storeBoards(freshBoards);
		}
		catch (error, st) {
			print('Error setting up boards for $key');
			print(error);
			print(st);
			boardFetchError = (error, st);
		}
		boardsLoading = false;
		notifyListeners();
	}

	Future<List<ImageboardBoard>> refreshBoards() async {
		final freshBoards = await site.getBoards(priority: RequestPriority.interactive);
		await persistence.storeBoards(freshBoards);
		return freshBoards;
	}

	void _maybeShowDubsToast(int id) {
		if (Settings.instance.highlightRepeatingDigitsInPostIds && site.explicitIds) {
			final digits = id.toString();
			int repeatingDigits = 1;
			for (; repeatingDigits < digits.length; repeatingDigits++) {
				if (digits[digits.length - 1 - repeatingDigits] != digits[digits.length - 1]) {
					break;
				}
			}
			if (repeatingDigits > 1) {
				showToast(
					context: ImageboardRegistry.instance.context!,
					icon: CupertinoIcons.hand_point_right,
					message: switch(repeatingDigits) {
						< 3 => 'Dubs GET!',
						3 => 'Trips GET!',
						4 => 'Quads GET!',
						5 => 'Quints GET!',
						6 => 'Sexts GET!',
						7 => 'Septs GET!',
						8 => 'Octs GET!',
						_ => 'Insane GET!!'
					}
				);
			}
		}
	}

	void _listenForSpamFilter(DraftPost submittedPost, PostReceipt receipt, CaptchaSolution captchaSolution, bool showToastOnSuccess) async {
		final threadIdentifier =
			// Reply
			submittedPost.thread ??
			// Thread
			ThreadIdentifier(submittedPost.board, receipt.id);
		final postShowedUpCompleter = Completer<bool>();
		int? lastPostsCount;
		// Using listenForThreadChanges so it works on incognito tabs too
		final listenable = persistence.listenForThreadChanges(threadIdentifier);
		final forcedCheckFuture = () async {
			await Future.delayed(const Duration(seconds: 15));
			if (!postShowedUpCompleter.isCompleted) {
				while (!postShowedUpCompleter.isCompleted) {
					try {
						await threadWatcher.updateThread(threadIdentifier);
						break;
					}
					catch (e, st) {
						Future.error(e, st); // crashlytics
						// Try again after some time
						await Future.delayed(switch (e) {
							dio.DioError() => switch (e.error) {
								// Flaky network connection (TCP reset / timeout)
								HttpException || SocketException => const Duration(seconds: 1),
								// Something higher level -- bad status code?
								_ => const Duration(seconds: 15)
							},
							// Something else -- internal?
							_ => const Duration(seconds: 25)
						});
					}
				}
				// Give listener() some time to always finish first
				await Future.delayed(const Duration(seconds: 1));
			}
		}();
		void listener() async {
			final posts = (await Persistence.getCachedThread(key, threadIdentifier.board, threadIdentifier.id))?.posts_;
			bool? found;
			if (posts?.length == lastPostsCount) {
				return;
			}
			lastPostsCount = posts?.length;
			for (final post in posts?.reversed ?? <Post>[]) {
				if (post.id > receipt.id) {
					found = false;
				}
				else if (post.id == receipt.id) {
					final similarity = post.buildText().similarityTo(submittedPost.text);
					found = similarity > 0.65;
					break;
				}
				else {
					// post.id < receipt.id
					break;
				}
			}
			if (found != null) {
				// Post is certainly there or not
				postShowedUpCompleter.complete(found);
			}
		}
		listenable.addListener(listener);
		final postShowedUp = await Future.any<bool>([
			postShowedUpCompleter.future,
			Future.wait([
				// Wait for both forcedCheck and minimum time
				// Because if dart is paused while backgrounded, the minimum time
				// will be misleading
				forcedCheckFuture.catchError((Object e, StackTrace st) {
					Future.error(e, st); // crashlytics
				}),
				Future.delayed(const Duration(seconds: 20))
			]).then((_) => false)
		]);
		listenable.removeListener(listener);
		if (postShowedUp) {
			onSuccessfulCaptchaSubmitted(captchaSolution);
			receipt.spamFiltered = false;
			if (showToastOnSuccess) {
				showToast(
					context: ImageboardRegistry.instance.context!,
					message: 'Post successful',
					icon: captchaSolution.autoSolved ? CupertinoIcons.checkmark_seal : CupertinoIcons.check_mark,
					hapticFeedback: false
				);
			}
		}
		else {
			captchaSolution.dispose(); // junk
			receipt.spamFiltered = true;
			// Put it back in the Outbox
			if (!persistence.browserState.outbox.contains(submittedPost)) {
				// It may already be in the outbox if it's a draft
				persistence.browserState.outbox.add(submittedPost); // For restoration if app is closed
			}
			persistence.didUpdateBrowserState();
			Outbox.instance.headlessSolveFailed = true;
			Outbox.instance.submitPost(key, submittedPost, QueueStateIdle());
			showToast(
				context: ImageboardRegistry.instance.context!,
				message: '${submittedPost.threadId == null ? 'Thread' : 'Post'} spam-filtered',
				icon: CupertinoIcons.exclamationmark_shield,
				easyButton: ('More info', () => alertError(
					ImageboardRegistry.instance.context!,
					'Your ${submittedPost.threadId == null ? 'thread' : 'post'} seems to have been blocked by ${site.name}\'s anti-spam firewall.\nIt has been restored as a draft for you to try again.',
					null,
					barrierDismissible: true
				)),
				hapticFeedback: false
			);
		}
	}

	void listenToReplyPosting(QueuedPost post) {
		QueueState<PostReceipt>? lastState;
		void listener() async {
			final state = post.state;
			if (state == lastState) {
				// Sometimes notifyListeners() just used to internally rebuild
				return;
			}
			lastState = state;
			if (state is QueueStateDeleted<PostReceipt>) {
				// Don't remove listener, in case undeleted
				// Who cares about a leak....
				return;
			}
			if (state is QueueStateDone<PostReceipt>) {
				post.removeListener(listener);
				print(state.result);
				mediumHapticFeedback();
				final showTwoToasts = persistence.getSpamFilterStatus(state.captchaSolution.ip) != SpamFilterStatus.never;
				if (state.captchaSolution.autoSolved) {
					Outbox.instance.headlessSolveFailed = false;
				}
				if (state.result.spamFiltered) {
					_listenForSpamFilter(post.post, state.result, state.captchaSolution, showTwoToasts);
				}
				else {
					onSuccessfulCaptchaSubmitted(state.captchaSolution);
				}
				showToast(
					context: ImageboardRegistry.instance.context!,
					message: showTwoToasts ? 'Post submitted' : 'Post successful',
					icon: showTwoToasts ? CupertinoIcons.clock : (state.captchaSolution.autoSolved ? CupertinoIcons.checkmark_seal : CupertinoIcons.check_mark),
					hapticFeedback: false
				);
				_maybeShowDubsToast(state.result.id);
				if (state.captchaSolution.autoSolved && (Settings.instance.useCloudCaptchaSolver ?? false) && (Settings.instance.useHeadlessCloudCaptchaSolver == null)) {
					Settings.useHeadlessCloudCaptchaSolverSetting.value = await showAdaptiveDialog<bool>(
						context: ImageboardRegistry.instance.context!,
						barrierDismissible: true,
						builder: (context) => AdaptiveAlertDialog(
							title: const Text('Skip captcha confirmation?'),
							content: const Text('Cloud captcha solutions will be submitted directly without showing a popup and asking for confirmation.'),
							actions: [
								AdaptiveDialogAction(
									isDefaultAction: true,
									child: const Text('Skip confirmation'),
									onPressed: () {
										Navigator.of(context).pop(true);
									},
								),
								AdaptiveDialogAction(
									child: const Text('No'),
									onPressed: () {
										Navigator.of(context).pop(false);
									}
								)
							]
						)
					);
				}
			}
			else if (state is QueueStateFailed<PostReceipt>) {
				final e = state.error;
				if (e is BannedException) {
					final url = e.url;
					await showAdaptiveDialog(
						context: ImageboardRegistry.instance.context!,
						builder: (context) {
							return AdaptiveAlertDialog(
								title: const Text('Error'),
								content: Text(e.toStringDio()),
								actions: [
									if (url != null) AdaptiveDialogAction(
										child: const Text('See reason'),
										onPressed: () => openCookieBrowser(context, url, useFullWidthGestures: false)
									),
									AdaptiveDialogAction(
										child: const Text('Clear cookies'),
										onPressed: () {
											Persistence.clearCookies(fromWifi: null);
										}
									),
									AdaptiveDialogAction(
										child: const Text('OK'),
										onPressed: () {
											Navigator.of(context).pop();
										}
									)
								]
							);
						}
					);
				}
				else if (e is WebAuthenticationRequiredException) {
					alertError(ImageboardRegistry.instance.context!, 'Web authentication required\n\nMaking a post via the website is required to whitelist your IP for posting via Chance.', null, actions: {
						'Go to web': () => shareOne(
							context: ImageboardRegistry.instance.context!,
							text: post.site.getWebUrl(
								board: post.post.board,
								threadId: post.post.threadId
							),
							type: 'text',
							sharePositionOrigin: null
						)
					});
				}
				else if (e is! AdditionalCaptchaRequiredException) {
					alertError(ImageboardRegistry.instance.context!, e, state.stackTrace);
				}
			}
		}
		post.addListener(listener);
		listener();
	}

	Future<PostReceipt> _submitPostWithAdditionalCaptchaHandling(DraftPost post, CaptchaSolution captchaSolution, dio.CancelToken cancelToken) async {
		try {
			return await site.submitPost(post, captchaSolution, cancelToken);
		}
		catch (e) {
			if (e is AdditionalCaptchaRequiredException) {
				showToast(
					context: ImageboardRegistry.instance.context!,
					message: 'Additional captcha required',
					icon: CupertinoIcons.exclamationmark_square
				);
				final solution2 = await solveCaptcha(
					context: ImageboardRegistry.instance.context!,
					site: site,
					request: e.captchaRequest,
					cancelToken: cancelToken
				);
				if (solution2 == null) {
					// Just show that another captcha was needed and not provided
					rethrow;
				}
				await e.onSolved(solution2, cancelToken);
				return await site.submitPost(post, captchaSolution, cancelToken);
			}
			if (e is WebGatewayException) {
				// Should pop up cloudflare browser. If user closes it early, it should properly throw
				await e.openWebGateway(ImageboardRegistry.instance.context!);
				// Now retry it
				return await site.submitPost(post, captchaSolution, cancelToken);
			}
			rethrow;
		}
	}

	Future<PostReceipt> submitPost(DraftPost post, CaptchaSolution captchaSolution, dio.CancelToken cancelToken) async {
		final path = post.file;
		if (path != null && !File(path).existsSync()) {
			throw Exception('Selected file not found: $path');
		}
		if (!persistence.browserState.outbox.contains(post)) {
			// It may already be in the outbox if it's a draft
			persistence.browserState.outbox.add(post); // For restoration if app is closed
		}
		runWhenIdle(const Duration(milliseconds: 500), persistence.didUpdateBrowserState);
		final receipt = await _submitPostWithAdditionalCaptchaHandling(post, captchaSolution, cancelToken);
		persistence.browserState.outbox.remove(post);
		runWhenIdle(const Duration(milliseconds: 500), persistence.didUpdateBrowserState);
		final thread = ThreadIdentifier(post.board, post.threadId ?? receipt.id);
		final persistentState = persistence.getThreadState(thread);
		persistentState.receipts = [...persistentState.receipts, receipt];
		persistentState.didUpdateYourPosts();
		final settings = Settings.instance;
		if (
			(post.threadId == null && settings.watchThreadAutomaticallyWhenCreating) ||
			(post.threadId != null && settings.watchThreadAutomaticallyWhenReplying)
		) {
			notifications.subscribeToThread(
				thread: thread,
				lastSeenId: receipt.id,
				localYousOnly: (persistentState.threadWatch ?? settings.defaultThreadWatch)?.localYousOnly ?? post.threadId != null,
				pushYousOnly: (persistentState.threadWatch ?? settings.defaultThreadWatch)?.pushYousOnly ?? post.threadId != null,
				foregroundMuted: (persistentState.threadWatch ?? settings.defaultThreadWatch)?.foregroundMuted ?? false,
				push: (persistentState.threadWatch ?? settings.defaultThreadWatch)?.push ?? true,
				youIds: persistentState.freshYouIds(),
				notifyOnSecondLastPage: (persistentState.threadWatch ?? settings.defaultThreadWatch)?.notifyOnSecondLastPage ?? false,
				notifyOnLastPage: (persistentState.threadWatch ?? settings.defaultThreadWatch)?.notifyOnLastPage ?? true,
				notifyOnDead: (persistentState.threadWatch ?? settings.defaultThreadWatch)?.notifyOnDead ?? false
			);
		}
		if (settings.saveThreadAutomaticallyWhenReplying) {
			persistentState.savedTime ??= DateTime.now();
		}
		await persistentState.save();
		return receipt;
	}

	@override
	void dispose() {
		super.dispose();
		if (_threadWatcherInitialized) {
			threadWatcher.dispose();
		}
		if (_persistenceInitialized) {
			persistence.dispose();
		}
		if (_notificationsInitialized) {
			notifications.dispose();
		}
	}

	ImageboardScoped<T> scope<T>(T item) => ImageboardScoped(
		imageboard: this,
		item: item
	);

	@override
	String toString() => 'Imageboard($key)';
}

const _devImageboardKey = 'devsite';

class ImageboardRegistry extends ChangeNotifier {
	static ImageboardRegistry? _instance;
	static ImageboardRegistry get instance {
		_instance ??= ImageboardRegistry._();
		return _instance!;
	}

	ImageboardRegistry._();
	
	(Object, StackTrace)? setupError;
	final Map<String, Imageboard> _sites = {};
	final Map<Imageboard?, (Object, StackTrace)> notificationErrors = {};
	int get count => _sites.length;
	Iterable<Imageboard> get imageboardsIncludingUninitialized => _sites.values;
	Iterable<Imageboard> get imageboards => _sites.values.where((s) => s.initialized);
	Iterable<Imageboard> get imageboardsIncludingDev sync* {
		yield* _sites.values.where((s) => s.initialized);
		final dev_ = dev;
		if (dev_ != null && dev_.initialized) {
			yield dev_;
		}
	}
	bool initialized = false;
	BuildContext? context;
	final _mutex = Mutex();
	static final threadWatcherController = ThreadWatcherController();
	Imageboard? dev;

	Future<void> initializeDev() async {
		dev?.dispose();
		final tmpDev = dev = Imageboard(
			key: _devImageboardKey,
			siteData: defaultSite,
			threadWatcherController: ThreadWatcherController(interval: const Duration(minutes: 10))
		);
		await tmpDev.initialize(
			threadWatcherWatchForStickyOnBoards: ['chance']
		);
		notifyListeners();
	}

	Future<void> handleSites({
		required Map<String, Map> sites,
		required Set<String> keys,
		required BuildContext context
	}) {
		return _mutex.protect(() async {
			context = context;
			setupError = null;
			try {
				final siteKeysToRemove = _sites.keys.toList();
				final initializations = <Future<void>>[];
				final yourSites = sites.entries.where((e) => keys.contains(e.key));
				if (yourSites.isEmpty) {
					throw Exception('No site data available for $keys');
				}
				for (final entry in yourSites) {
					siteKeysToRemove.remove(entry.key);
					if (_sites.containsKey(entry.key)) {
						// Site not changed
						_sites[entry.key]?.updateSiteData(entry.value);
						continue;
					}
					_sites[entry.key] = Imageboard(
						siteData: entry.value,
						key: entry.key
					);
					initializations.add(_sites[entry.key]!.initialize());
				}
				await Future.wait(initializations);
				final initialTabsLength = Persistence.tabs.length;
				final initialTab = Persistence.tabs[Persistence.currentTabIndex];
				final initialTabIndex = Persistence.currentTabIndex;
				for (final key in siteKeysToRemove) {
					_sites[key]?.dispose();
					_sites.remove(key);
					Persistence.tabs.removeWhere((t) => t.imageboardKey == key);
				}
				if (Persistence.tabs.contains(initialTab)) {
					Persistence.currentTabIndex = Persistence.tabs.indexOf(initialTab);
				}
				else if (Persistence.tabs.isEmpty) {
					Persistence.tabs.add(PersistentBrowserTab());
					Persistence.currentTabIndex = 0;
				}
				else {
					Persistence.currentTabIndex = min(Persistence.tabs.length - 1, initialTabIndex);
				}
				await Future.wait(Persistence.tabs.map((tab) => tab.initialize()));
				if (initialTabsLength != Persistence.tabs.length) {
					Persistence.saveTabs();
				Persistence.globalTabMutator.value = Persistence.currentTabIndex;
				}
			}
			catch (e, st) {
				setupError = (e, st);
				print(e);
				print(st);
			}
			initialized = true;
			notifyListeners();
		});
	}

	Imageboard? getImageboard(String? key) {
		if (key == null) {
			return null;
		}
		if (key == _devImageboardKey) {
			return dev;
		}
		if (_sites[key]?.initialized == true) {
			return _sites[key];
		}
		return null;
	}

	Imageboard? getImageboardUnsafe(String key) {
		if (key == _devImageboardKey) {
			return dev;
		}
		return _sites[key];
	}

	Future<void> retryFailedBoardSetup() async {
		final futures = <Future>[];
		for (final i in imageboards) {
			if (i.boardFetchError != null) {
				futures.add(i.setupBoards());
			}
		}
		await Future.wait(futures);
	}

	Future<(Imageboard, BoardThreadOrPostIdentifier, String?)?> decodeUrl(Uri url) async {
		for (final imageboard in ImageboardRegistry.instance.imageboardsIncludingDev) {
			BoardThreadOrPostIdentifier? dest = await imageboard.site.decodeUrl(url);
			String? usedArchive;
			for (final archive in imageboard.site.archives) {
				if (dest != null) {
					break;
				}
				dest = await archive.decodeUrl(url);
				usedArchive = archive.name;
			}
			if (dest != null) {
				return (imageboard, dest, usedArchive);
			}
		}
		return null;
	}

	Future<void> clearAllPseudoCookies() async {
		for (final i in imageboards) {
			await i.site.clearPseudoCookies();
		}
	}

	Future<void> didImport() async {
		// Need to do some reinitialization
		// This will both set the counts and also load the threads from disk
		try {
			final devFuture = dev?.threadWatcher.setInitialCounts();
			await Future.wait([
				...imageboards.map((i) => i.threadWatcher.setInitialCounts()),
				if (devFuture != null) devFuture
			]);
		}
		catch (e, st) {
			Future.error(e, st);
		}
	}

	ImageboardRedirectGateway? getRedirectGateway(Uri? uri, String? title) {
		if (uri == null) {
			return null;
		}
		return imageboards.tryMapOnce((i) => i.site.getRedirectGateway(uri, title));
	}

	void setNotificationError(Imageboard? imageboard, (Object, StackTrace)? pair) {
		if (pair != notificationErrors[imageboard]) {
			if (pair != null) {
				notificationErrors[imageboard] = pair;
			}
			else {
				notificationErrors.remove(imageboard);
			}
			notifyListeners();
		}
	}

	bool isRedirectGateway(Uri? uri, String? title) => getRedirectGateway(uri, title) != null;
}

class ImageboardScoped<T> {
	final Imageboard imageboard;
	final T item;

	ImageboardScoped({
		required this.imageboard,
		required this.item
	});

	@override
	bool operator == (Object other) =>
		identical(this, other) ||
		(other is ImageboardScoped) &&
		(other.imageboard == imageboard) &&
		(other.item == item);
	@override
	int get hashCode => Object.hash(imageboard, item);

	@override
	String toString() => 'ImageboardScoped(${imageboard.key}, $item)';
}