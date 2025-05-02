import 'dart:async';

import 'package:chan/models/board.dart';
import 'package:chan/models/thread.dart';
import 'package:chan/services/auth_page_helper.dart';
import 'package:chan/services/captcha.dart';
import 'package:chan/services/imageboard.dart';
import 'package:chan/services/persistence.dart';
import 'package:chan/services/settings.dart';
import 'package:chan/services/util.dart';
import 'package:chan/sites/imageboard_site.dart';
import 'package:chan/util.dart';
import 'package:chan/widgets/util.dart';
import 'package:dio/dio.dart';
import 'package:flutter/cupertino.dart';
import 'package:flutter/foundation.dart';
import 'package:mutex/mutex.dart';

typedef QueueEntryActionKey = (String imageboardKey, BoardKey board, ImageboardAction action);

sealed class QueueState<T> {
	QueueState();
	bool get isIdle;
	bool get isSubmittable;
	bool get isFinished => isIdle && !isSubmittable;
	bool get _needsCaptcha => false;
	DateTime? get _submissionTime => null;
	String get idleName;
	void _dispose() {}
}

class QueueStateIdle<T> extends QueueState<T> {
	QueueStateIdle();
	@override
	bool get isIdle => true;
	@override
	bool get isSubmittable => true;
	@override
	String get idleName => 'Idle';
}

class QueueStateNeedsCaptcha<T> extends QueueState<T> {
	final BuildContext? context;
	final VoidCallback? beforeModal;
	final VoidCallback? afterModal;
	QueueStateNeedsCaptcha(this.context, {this.beforeModal, this.afterModal});
	@override
	bool get isIdle => false;
	@override
	bool get isSubmittable => false;
	@override
	bool get _needsCaptcha => true;
	@override
	String get idleName => 'Needs captcha';
}

class QueueStateGettingCaptcha<T> extends QueueState<T> {
	final CancelToken? cancelToken;
	QueueStateGettingCaptcha({
		this.cancelToken
	});
	@override
	bool get isIdle => false;
	@override
	bool get isSubmittable => false;
	@override
	String toString() => 'QueueStateGettingCaptcha(cancelToken: $cancelToken)';
	@override
	String get idleName => 'Getting captcha';
}

class QueueStateWaitingWithCaptcha<T> extends QueueState<T> {
	final DateTime submittedAt;
	final CaptchaSolution captchaSolution;
	QueueStateWaitingWithCaptcha(this.submittedAt, this.captchaSolution);
	@override
	bool get isIdle => false;
	@override
	bool get isSubmittable => false;
	@override
	void _dispose() {
		captchaSolution.dispose();
	}
	@override
	String get idleName => 'Waiting to submit';
}

typedef WaitMetadata = ({DateTime until, VoidCallback skip});

class QueueStateSubmitting<T> extends QueueState<T> {
	final String? message;
	/// Can be called to skip current step (arbitrary delay?)
	final WaitMetadata? wait;
	final CancelToken? cancelToken;
	QueueStateSubmitting({
		required this.message,
		this.wait,
		this.cancelToken
	});
	@override
	bool get isIdle => false;
	@override
	bool get isSubmittable => false;
	@override
	String toString() => 'QueueStateSubmitting(message: $message, wait: $wait, cancelToken: $cancelToken)';
	@override
	String get idleName => message ?? 'Submitting';
}

class QueueStateFailed<T> extends QueueState<T> {
	final Object error;
	final StackTrace stackTrace;
	final CaptchaSolution? captchaSolution;
	QueueStateFailed(this.error, this.stackTrace, {this.captchaSolution});
	@override
	bool get isIdle => true;
	@override
	bool get isSubmittable => true;
	@override
	void _dispose() {
		captchaSolution?.dispose();
	}
	@override
	String get idleName => 'Failed';
}

class QueueStateDone<T> extends QueueState<T> {
	final DateTime time;
	final CaptchaSolution captchaSolution;
	final T result;
	QueueStateDone(this.time, this.result, this.captchaSolution);
	@override
	bool get isIdle => true;
	@override
	bool get isSubmittable => false;
	@override
	DateTime? get _submissionTime => time;
	@override
	String get idleName => 'Done';
}

class QueueStateDeleted<T> extends QueueState<T> {
	QueueStateDeleted();
	@override
	bool get isIdle => true;
	@override
	bool get isSubmittable => false;
	@override
	String get idleName => 'Deleted';
}

sealed class QueueEntry<T> extends ChangeNotifier {
	final _lock = Mutex();
	bool get isActivelyProcessing => _lock.isLocked;
	String get statusText => state.idleName;
	final String imageboardKey;
	Imageboard get imageboard => ImageboardRegistry.instance.getImageboard(imageboardKey)!;
	ImageboardSite get site => imageboard.site;
	Future<T> _submitImpl(CaptchaSolution captchaSolution, CancelToken cancelToken);
	QueueState<T> _state;
	QueueState<T> get state => _state;
	bool get useLoginSystem;
	bool get isArchived;
	set _useLoginSystem(bool newUseLoginSystem);
	set useLoginSystem(bool newUseLoginSystem) {
		_useLoginSystem = newUseLoginSystem;
		notifyListeners();
	}

	@override
	String toString() => 'QueueEntry<$T>(state: $state)';

	QueueEntry({
		required this.imageboardKey,
		required QueueState<T> state
	}) : _state = state;

	BoardKey get _board;
	ImageboardAction get action;
	Future<CaptchaRequest> _getCaptchaRequest(CancelToken cancelToken);

	QueueEntryActionKey get _key => (imageboardKey, _board, site.getQueue(action));
	OutboxQueue? get queue => Outbox.instance.queues[_key];
	DateTime? get allowedTime => queue?.allowedTime;
	Duration get _cooldown => site.getActionCooldown(_board.s, action, Persistence.currentCookies);
	ThreadIdentifier? get thread;
	Duration get _regretDelay => Duration.zero;

	bool shouldReplace(QueueEntry other);

	bool _transitionIfActive(QueueState<T> newState) {
		if (_state is QueueStateDeleted<T>) {
			return false;
		}
		_state._dispose();
		_state = newState;
		notifyListeners();
		return true;
	}

	Future<void> submit(BuildContext? context) async {
		// Note -- if we are failed here. we might have a captcha.
		// But just throw it away, it avoids tracking captcha problems.
		try {
			if (_transitionIfActive(QueueStateNeedsCaptcha(context))) {
				if (queue?.captchaAllowedTime.isAfter(DateTime.now()) == false) {
					// Grab the new captcha right away
					await _preSubmit();
				}
			}
		}
		finally {
			Future.microtask(Outbox.instance._process);
		}
	}

	@mustCallSuper
	void delete({bool isReplacement = false}) {
		final state = this.state;
		if (state is QueueStateSubmitting<T>) {
			state.cancelToken?.cancel();
		}
		else if (state is QueueStateGettingCaptcha<T>) {
			state.cancelToken?.cancel();
		}
		if (_transitionIfActive(QueueStateDeleted())) {
			Future.microtask(Outbox.instance._process);
		}
	}

	void undelete() {
		_state._dispose();
		_state = QueueStateIdle();
		notifyListeners();
		Future.microtask(Outbox.instance._process);
	}

	void cancel() {
		print('$this::cancel()');
		final state = this.state;
		if (_transitionIfActive(QueueStateIdle<T>())) {
			if (state is QueueStateSubmitting<T>) {
				state.cancelToken?.cancel();
			}
			else if (state is QueueStateGettingCaptcha<T>) {
				state.cancelToken?.cancel();
			}
			Future.microtask(Outbox.instance._process);
		}
	}

	/// Convenience for UI
	({
		DateTime deadline,
		FutureOr Function(BuildContext) action,
		String label,
		bool highPriority
	})? get pair {
		final state = _state;
		final queue = this.queue;
		if (state is QueueStateNeedsCaptcha<T> && queue != null && queue.captchaAllowedTime.isAfter(DateTime.now())) {
			if (
				imageboard.site.authPage != null &&
				imageboard.site.hasLinkCookieAuth &&
				queue.captchaAllowedTime.difference(DateTime.now()) > const Duration(minutes: 3)
			){
				return (
					deadline: queue.captchaAllowedTime,
					action: (context) async {
						final authorized = await showAuthPageHelperPopup(context, imageboard);
						if (authorized) {
							queue.captchaAllowedTime = DateTime.now();
						}
					},
					label: 'Tap to login',
					highPriority: true
				);
			}
			return (
				deadline: queue.captchaAllowedTime,
				action: (_) => queue.captchaAllowedTime = DateTime.now(),
				label: 'Waiting for captcha',
				highPriority: false
			);
		}
		else if (state is QueueStateWaitingWithCaptcha<T> && queue != null && queue.allowedTime.isAfter(DateTime.now())) {
			return (
				deadline: queue.allowedTime,
				action: (_) => queue.allowedTime = DateTime.now(),
				label: 'Waiting for cooldown',
				highPriority: false
			);
		}
		else if (state is QueueStateSubmitting<T>) {
			final wait = state.wait;
			if (wait != null) {
				return (
					deadline: wait.until,
					action: (_) => wait.skip(),
					label: state.message ?? 'Waiting',
					highPriority: false
				);
			}
		}
		return null;
	}

	Future<void> _preSubmit() => _lock.protect(() async {
		final initialState = state;
		final QueueStateNeedsCaptcha<T>? initialNeedsCaptchaState;
		if (initialState is QueueStateNeedsCaptcha<T>) {
			initialNeedsCaptchaState = initialState;
			final cancelToken = CancelToken();
			try {
				_state = QueueStateGettingCaptcha(cancelToken: cancelToken);
				final savedFields = site.loginSystem?.getSavedLoginFields();
				if (useLoginSystem && savedFields != null) {
					try {
						await site.loginSystem?.login(savedFields, cancelToken).timeout(const Duration(seconds: 15));
					}
					catch (e) {
						final context = initialState.context?.ifMounted ?? ImageboardRegistry.instance.context;
						if (context != null && context.mounted) {
							showToast(
								context: context,
								icon: CupertinoIcons.exclamationmark_triangle,
								message: 'Failed to log in to ${site.loginSystem?.name}'
							);
						}
						print('Problem auto-logging-in to ${site.loginSystem?.name}: $e');
					}
				}
				else {
					await site.loginSystem?.logout(false, cancelToken);
				}
				DateTime? tryAgainAt0;
				final request = await _getCaptchaRequest(cancelToken);
				final captcha = await solveCaptcha(
					context: initialState.context?.ifMounted ?? ImageboardRegistry.instance.context,
					beforeModal: initialState.beforeModal,
					afterModal: initialState.afterModal,
					site: site,
					request: request,
					cancelToken: cancelToken,
					onTryAgainAt: (x) => tryAgainAt0 = x,
					forceHeadless: null, // Try headless solver
				);
				if (_state is QueueStateIdle<T>) {
					// Cancelled in the meantime
					return;
				}
				final tryAgainAt = tryAgainAt0;
				if (captcha != null) {
					_state = QueueStateWaitingWithCaptcha(DateTime.now(), captcha);
				}
				else {
					if (tryAgainAt != null) {
						queue?.captchaAllowedTime = tryAgainAt;
					}
					// Maybe remember the captcha cooldown. But don't try to resubmit then.
					if (_transitionIfActive(QueueStateIdle())) {
						print('Idling following captcha == null');
					}
				}
			}
			on CooldownException catch (e) {
				print('Got cooldown in $this:_preSubmit() to try again in ${e.tryAgainAt.difference(DateTime.now())}');
				final context = initialState.context?.ifMounted ?? ImageboardRegistry.instance.context;
				if (context != null && context.mounted) {
					showToast(
						context: context,
						message: 'Need to wait ${formatDuration(e.tryAgainAt.difference(DateTime.now()))} to get captcha',
						icon: CupertinoIcons.exclamationmark_shield
					);
				}
				queue?.captchaAllowedTime = e.tryAgainAt;
				_transitionIfActive(initialNeedsCaptchaState);
			}
			on HeadlessSolveNotPossibleException {
				final context = initialState.context?.ifMounted ?? ImageboardRegistry.instance.context;
				if (context != null && context.mounted) {
					showToast(
						context: context,
						message: 'Captcha needed',
						icon: CupertinoIcons.checkmark_shield,
						easyButton: ('Solve', () => submit(context))
					);
				}
				if (_transitionIfActive(QueueStateIdle())) {
					print('Idling after headless solve failed');
				}
			}
			catch (e, st) {
				print(e);
				print(st);
				_transitionIfActive(QueueStateFailed(e, st));
			}
			notifyListeners();
		}
		else {
			initialNeedsCaptchaState = null;
		}
		if (initialState is QueueStateWaitingWithCaptcha<T> && _state is! QueueStateIdle<T>) {
			final deadline = DateTime.now().add(const Duration(seconds: 5));
			final expiresAt = initialState.captchaSolution.expiresAt;
			if (expiresAt != null && expiresAt.isBefore(deadline)) {
				initialState.captchaSolution.dispose();
				_transitionIfActive(initialNeedsCaptchaState ?? QueueStateNeedsCaptcha(null));
			}
		}
	});

	Future<bool> _submit() async {
		// _lock is not re-entrant...
		await _preSubmit();
		return await _lock.protect(() async {
			final initialState = state;
			if (initialState is QueueStateWaitingWithCaptcha<T>) {
				final cancelToken = CancelToken();
				final captchaSolution = initialState.captchaSolution;
				try {
					final regretTime = initialState.submittedAt.add(_regretDelay);
					if (regretTime.isAfter(DateTime.now())) {
						final skipCompleter = Completer<void>();
						_state = QueueStateSubmitting(
							message: 'Waiting ${formatDuration(_regretDelay)}',
							wait: (
								until: regretTime,
								skip: skipCompleter.complete
							),
							cancelToken: cancelToken
						);
						notifyListeners();
						await Future.any([Future.delayed(regretTime.difference(DateTime.now())), skipCompleter.future, cancelToken.whenCancel]);
						if (cancelToken.isCancelled || _state.isIdle) {
							if (!_state.isIdle) {
								_state = QueueStateIdle();
								notifyListeners();
							}
							return false;
						}
					}
					final delay = site.getCaptchaUsableTime(captchaSolution).difference(DateTime.now());
					if (delay > Duration.zero) {
						final skipCompleter = Completer<void>();
						_state = QueueStateSubmitting(
							message: 'Waiting to use captcha',
							wait: delay > const Duration(seconds: 3) ? (
								until: DateTime.now().add(delay),
								skip: skipCompleter.complete
							) : null,
							cancelToken: cancelToken
						);
						notifyListeners();
						await Future.any([Future.delayed(delay), skipCompleter.future, cancelToken.whenCancel]);
						if (cancelToken.isCancelled || _state.isIdle) {
							if (!_state.isIdle) {
								_state = QueueStateIdle();
								notifyListeners();
							}
							return false;
						}
					}
					_state = QueueStateSubmitting(
						message: 'Submitting',
						cancelToken: cancelToken
					);
					notifyListeners();
					final result = await _submitImpl(captchaSolution, cancelToken);
					_state = QueueStateDone(DateTime.now(), result, captchaSolution);
					notifyListeners();
					return true;
				}
				on CooldownException catch (e) {
					print('got cd $e');
					_state = initialState; // Restore to wait with captcha
					final context = ImageboardRegistry.instance.context;
					if (context != null && context.mounted) {
						showToast(
							context: context,
							message: 'Need to wait ${formatDuration(e.tryAgainAt.difference(DateTime.now()))} to ${action.verbSimplePresentLowercase}',
							icon: CupertinoIcons.exclamationmark_shield
						);
					}
					queue?.allowedTime = e.tryAgainAt;
					notifyListeners();
				}
				catch (e, st) {
					print(e);
					print(st);
					if (e.toStringDio().toLowerCase().contains('captcha')) {
						// Captcha didn't work. For now, let's disable the auto captcha solver
						Outbox.instance.headlessSolveFailed = true;
					}
					_transitionIfActive(QueueStateFailed(e, st, captchaSolution: captchaSolution));
				}
			}
			return false;
		});
	}
}

class QueuedPost extends QueueEntry<PostReceipt> {
	final DraftPost post;
	@override
	bool get useLoginSystem => post.useLoginSystem ?? true;
	@override
	set _useLoginSystem(bool newUseLoginSystem) => post.useLoginSystem = newUseLoginSystem;

	@override
	Future<PostReceipt> _submitImpl(CaptchaSolution captchaSolution, CancelToken cancelToken) async {
		return await imageboard.submitPost(post, captchaSolution, cancelToken);
	}

	@override
	Future<CaptchaRequest> _getCaptchaRequest(CancelToken cancelToken) => site.getCaptchaRequest(post.board, post.threadId, cancelToken: cancelToken);

	@override
	void delete({bool isReplacement = false}) {
		super.delete();
		if (!isReplacement) {
			imageboard.persistence.browserState.outbox.remove(post);
			imageboard.persistence.didUpdateBrowserState();
		}
	}

	@override
	BoardKey get _board => ImageboardBoard.getKey(post.board);

	@override
	ImageboardAction get action => post.action;

	@override
	ThreadIdentifier? get thread => post.thread;

	@override
	Duration get _regretDelay => Settings.instance.postingRegretDelay;

	@override
	bool get isArchived {
		final thread = post.thread;
		if (thread == null) {
			// New thread -> no parent thread to check
			return false;
		}
		return imageboard.persistence.getThreadStateIfExists(thread)?.thread?.isArchived ?? false;
	}

	QueuedPost({
		required super.imageboardKey,
		required this.post,
		required super.state
	}) {
		// This is really important that it happens first
		// The listener in ReplyBox may mutate us...
		imageboard.listenToReplyPosting(this);
	}

	@override
	bool shouldReplace(QueueEntry other) {
		if (other is QueuedPost) {
			return other.imageboardKey == imageboardKey && other.post == post;
		}
		return false;
	}
}

class QueuedReport extends QueueEntry<void> {
	final ChoiceReportMethod method;
	final ChoiceReportMethodChoice choice;
	@override
	bool _useLoginSystem;
	@override
	bool get useLoginSystem => _useLoginSystem;

	QueuedReport({
		required super.imageboardKey,
		required this.method,
		required this.choice,
		required bool useLoginSystem,
		required super.state
	}) : _useLoginSystem = useLoginSystem;

	@override
	Future<void> _submitImpl(CaptchaSolution captchaSolution, CancelToken cancelToken) async {
		await method.onSubmit(choice, captchaSolution, cancelToken: cancelToken);
	}

	@override
	BoardKey get _board => ImageboardBoard.getKey(method.post.board);

	@override
	ImageboardAction get action => ImageboardAction.report;

	@override
	bool get isArchived {
		return imageboard.persistence.getThreadStateIfExists(method.post.thread)?.thread?.isArchived ?? false;
	}

	@override
	ThreadIdentifier? get thread => method.post.thread;

	@override
	Future<CaptchaRequest> _getCaptchaRequest(CancelToken cancelToken) async => method.getCaptchaRequest(cancelToken: cancelToken);

	@override
	bool shouldReplace(QueueEntry other) {
		if (other is QueuedReport) {
			return other.imageboardKey == imageboardKey && other.method.post == method.post;
		}
		return false;
	}
}

class QueuedDeletion extends QueueEntry<void> {
	@override
	final ThreadIdentifier thread;
	final PostReceipt receipt;
	@override
	bool _useLoginSystem;
	@override
	bool get useLoginSystem => _useLoginSystem;
	final bool imageOnly;

	QueuedDeletion({
		required super.imageboardKey,
		required this.thread,
		required this.receipt,
		required super.state,
		required this.imageOnly
	}) : _useLoginSystem = true;

	@override
	Future<void> _submitImpl(CaptchaSolution captchaSolution, CancelToken cancelToken) async {
		await site.deletePost(thread, receipt, captchaSolution, cancelToken, imageOnly: imageOnly);
	}

	@override
	BoardKey get _board => thread.boardKey;

	@override
	ImageboardAction get action => ImageboardAction.delete;

	@override
	bool get isArchived {
		return imageboard.persistence.getThreadStateIfExists(thread)?.thread?.isArchived ?? false;
	}

	@override
	Future<CaptchaRequest> _getCaptchaRequest(CancelToken cancelToken) async => site.getDeleteCaptchaRequest(thread, cancelToken: cancelToken);


	@override
	bool shouldReplace(QueueEntry other) {
		if (other is QueuedDeletion) {
			return other.imageboardKey == imageboardKey && other.thread == thread && other.receipt.id == receipt.id;
		}
		return false;
	}
}

class OutboxQueue extends ChangeNotifier {
	final List<QueueEntry> list = [];
	void _sortList() {
		mergeSort(list, compare: (a, b) {
			final aIdle = a.state.isIdle;
			final bIdle = b.state.isIdle;
			if (aIdle == bIdle) {
				return 0;
			}
			else if (aIdle) {
				return 1;
			}
			else {
				return -1;
			}
		});
	}
	DateTime allowedTimeWifi = DateTime.now();
	DateTime allowedTimeCellular = DateTime.now();
	DateTime get allowedTime {
		if (Settings.instance.isConnectedToWifiForCookies) {
			return allowedTimeWifi;
		}
		else {
			return allowedTimeCellular;
		}
	}
	set allowedTime (DateTime newTime) {
		if (Settings.instance.isConnectedToWifiForCookies) {
			allowedTimeWifi = newTime;
		}
		else {
			allowedTimeCellular = newTime;
		}
		notifyListeners();
	}
	DateTime captchaAllowedTimeWifi = DateTime.now();
	DateTime captchaAllowedTimeCellular = DateTime.now();
	DateTime get captchaAllowedTime {
		if (Settings.instance.isConnectedToWifiForCookies) {
			return captchaAllowedTimeWifi;
		}
		else {
			return captchaAllowedTimeCellular;
		}
	}
	set captchaAllowedTime (DateTime newTime) {
		if (Settings.instance.isConnectedToWifiForCookies) {
			captchaAllowedTimeWifi = newTime;
		}
		else {
			captchaAllowedTimeCellular = newTime;
		}
		notifyListeners();
	}
}

class Outbox extends ChangeNotifier {
	static final _instance = Outbox._();
	static Outbox get instance => _instance;
	Outbox._() {
		_lastIsConnectedToWifi = Settings.instance.isConnectedToWifiForCookies;
		// No unsubscribing because Outbox never dies
		Settings.instance.addListener(_onSettingsUpdate);
	}

	final _lock = Mutex();
	Timer? _timer;
	final Map<QueueEntryActionKey, OutboxQueue> queues = {};
	bool headlessSolveFailed = false;
	bool? _lastIsConnectedToWifi;

	void _onSettingsUpdate() {
		if (_lastIsConnectedToWifi != Settings.instance.isConnectedToWifiForCookies) {
			_onConnectionChanged(Settings.instance.isConnectedToWifiForCookies);
			_lastIsConnectedToWifi = Settings.instance.isConnectedToWifiForCookies;
		}
	}

	void _onConnectionChanged(bool onWifi) {
		final toIdle = queues.values.expand((q) => q.list.where((e) => !e.state.isIdle));
		// Stop all submissions
		for (final e in toIdle) {
			e.cancel();
		}
		// Reset all timers
		for (final queue in queues.values) {
			queue.captchaAllowedTime = DateTime.now();
			queue.allowedTime = DateTime.now();
		}
		final context = ImageboardRegistry.instance.context;
		if (context != null && context.mounted && toIdle.isNotEmpty) {
			showToast(
				context: context,
				message: 'Network changed!',
				icon: CupertinoIcons.wifi_exclamationmark,
				easyButton: ('Resubmit', () {
					for (final e in toIdle) {
						e.submit(null);
					}
				})
			);
		}
	}

	void _onOutboxQueueUpdate() {
		// Some cooldown changed
		Future.microtask(_process);
	}

	Future<void> _process<T>([QueueEntry<T>? newEntry]) => _lock.protect(() async {
		try {
			print('Woken up!');
			if (newEntry != null) {
				final queue = queues.putIfAbsent(newEntry._key, () => OutboxQueue()..addListener(_onOutboxQueueUpdate));
				for (final other in queue.list) {
					if (newEntry.shouldReplace(other)) {
						other.delete(isReplacement: true);
					}
				}
				queue.list.add(newEntry);
				if (queue.list.first.state.isIdle) {
					// List was idle, set the cooldown based on new entry type
					final submissionTimes = queue.list.tryMap((e) => e.state._submissionTime).toList();
					if (submissionTimes.isNotEmpty) {
						queue.allowedTime = submissionTimes.reduce((a, b) => a.isAfter(b) ? a : b).add(newEntry._cooldown);
					}
				}
			}
			final nextWakeups = <DateTime>[];
			for (final queue in queues.entries) {
				if (queue.value.list.isEmpty) {
					continue;
				}
				if (queue.value.list.every((e) => e.state.isIdle)) {
					continue;
				}
				// Put idle entries at the end
				queue.value._sortList();
				if (queue.value.captchaAllowedTime.isAfter(DateTime.now()) && queue.value.list.first.state._needsCaptcha) {
					print('Can\'t fill first captcha yet');
					// Need captcha and not allowed yet, go to sleep
					nextWakeups.add(queue.value.captchaAllowedTime);
					continue;
				}
				print('Try filling first captcha');
				// Fill the captcha
				await queue.value.list.first._preSubmit();
				if (queue.value.captchaAllowedTime.isAfter(DateTime.now()) && queue.value.list.first.state._needsCaptcha) {
					print('Got cooldown filling first captcha');
					// Need captcha and not allowed yet, go to sleep
					nextWakeups.add(queue.value.captchaAllowedTime);
					continue;
				}
				if (queue.value.allowedTime.isAfter(DateTime.now())) {
					print('Can\'t submit yet');
					// Can't submit yet, go to sleep
					nextWakeups.add(queue.value.allowedTime);
					continue;
				}
				print('Try submitting first entry');
				// Submit the post
				final submitted = await queue.value.list.first._submit();
				if (queue.value.list.length > 1 && !queue.value.list[1].state.isIdle) {
					if (submitted) {
						queue.value.allowedTime = DateTime.now().add(queue.value.list[1]._cooldown);
					}
					// Retrigger wakeup immediately to look at next post for captcha purposes
					nextWakeups.add(DateTime.now());
				}
				else {
					// Just use current queue subitem type. It could be corrected if a different subtype is submitted
					if (submitted) {
						queue.value.allowedTime = DateTime.now().add(queue.value.list.first._cooldown);
					}
					// Mainly to notifyListeners() and freshen up widgets that show timer 
					nextWakeups.add(queue.value.allowedTime);
				}
			}
			if (nextWakeups.isNotEmpty) {
				final time = nextWakeups.reduce((a, b) => a.isBefore(b) ? a : b);
				final delay = time.difference(DateTime.now());
				print('Will wake up again in $delay');
				_timer?.cancel();
				_timer = Timer(delay, _process);
			}
			else {
				print('Will not wake up again');
			}
			notifyListeners();
		}
		catch (e, st) {
			Future.error(e, st); // crashlytics
			print(e);
			print(st);
			print('Something went wrong in _process, rescheduling in 1 second');
			_timer?.cancel();
			_timer = Timer(const Duration(seconds: 1), _process);
		}
	});

	QueuedPost submitPost(String imageboardKey, DraftPost post, QueueState<PostReceipt> initialState) {
		final entry = QueuedPost(
			imageboardKey: imageboardKey,
			post: post,
			state: initialState
		);
		Future.microtask(() => _process(entry));
		return entry;
	}

	QueuedReport submitReport(BuildContext context, String imageboardKey, ChoiceReportMethod method, ChoiceReportMethodChoice choice, bool useLoginSystem) {
		final entry = QueuedReport(
			imageboardKey: imageboardKey,
			method: method,
			choice: choice,
			state: QueueStateNeedsCaptcha(context),
			useLoginSystem: useLoginSystem
		);
		Future.microtask(() => _process(entry));
		return entry;
	}

	QueuedDeletion submitDeletion(BuildContext context, String imageboardKey, ThreadIdentifier thread, PostReceipt receipt, {required bool imageOnly}) {
		final entry = QueuedDeletion(
			imageboardKey: imageboardKey,
			thread: thread,
			receipt: receipt,
			state: QueueStateNeedsCaptcha(context),
			imageOnly: imageOnly
		);
		Future.microtask(() => _process(entry));
		return entry;
	}

	int get submittableCount {
		int count = 0;
		for (final queue in queues.values) {
			for (final entry in queue.list) {
				if (entry.state.isSubmittable) {
					count++;
				}
			}
		}
		return count;
	}

	int get activeCount {
		int count = 0;
		for (final queue in queues.values) {
			for (final entry in queue.list) {
				if (!entry.state.isFinished) {
					count++;
				}
			}
		}
		return count;
	}

	Iterable<QueuedPost> queuedPostsFor(String imageboardKey, String board, int? threadId) sync* {
		for (final queue in queues.values) {
			for (final entry in queue.list) {
				if (entry is QueuedPost &&
				    entry.state is! QueueStateDone<PostReceipt> &&
						entry.imageboardKey == imageboardKey &&
						entry.post.board == board &&
						entry.post.threadId == threadId) {
					yield entry;
				}
			}
		}
	}
}