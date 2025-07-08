import 'package:chan/models/board.dart';
import 'package:chan/models/post.dart';
import 'package:chan/models/thread.dart';
import 'package:chan/pages/board_switcher.dart';
import 'package:chan/pages/gallery.dart';
import 'package:chan/pages/master_detail.dart';
import 'package:chan/services/imageboard.dart';
import 'package:chan/services/persistence.dart';
import 'package:chan/services/settings.dart';
import 'package:chan/services/theme.dart';
import 'package:chan/util.dart';
import 'package:chan/widgets/adaptive.dart';
import 'package:chan/widgets/imageboard_icon.dart';
import 'package:chan/widgets/imageboard_scope.dart';
import 'package:chan/widgets/post_row.dart';
import 'package:chan/widgets/post_spans.dart';
import 'package:chan/widgets/refreshable_list.dart';
import 'package:chan/widgets/thread_row.dart';
import 'package:chan/widgets/util.dart';
import 'package:flutter/cupertino.dart';
import 'package:flutter/material.dart';
import 'package:provider/provider.dart';

class HistorySearchResult {
	final Thread thread;
	final Post? post;
	HistorySearchResult(this.thread, [this.post]);

	ThreadOrPostIdentifier get identifier => post?.identifier.threadOrPostId ?? thread.identifier.threadOrPostIdentifier;

	@override toString() => 'HistorySearchResult(thread: $thread, post: $post)';
}

enum _FilterSavedThreadsOnly {
	everything,
	savedThreads,
	notSavedThreads
}

enum _FilterYourPostsOnly {
	everything,
	yourPosts,
	notYourPosts,
	repliesToYourPosts
}

extension _Comparison on DateTime {
	bool operator >= (DateTime other) {
		return !(isBefore(other));
	}
	bool operator <= (DateTime other) {
		return !(isAfter(other));
	}
}


class HistorySearchPage extends StatefulWidget {
	final String initialQuery;
	final ImageboardScoped<ThreadOrPostIdentifier>? selectedResult;
	final ValueChanged<ImageboardScoped<ThreadOrPostIdentifier>?> onResultSelected;
	final bool initialSavedThreadsOnly;
	final bool initialYourPostsOnly;

	const HistorySearchPage({
		required this.initialQuery,
		required this.selectedResult,
		required this.onResultSelected,
		this.initialSavedThreadsOnly = false,
		this.initialYourPostsOnly = false,
		super.key
	});

	@override
	createState() => _HistorySearchPageState();
}

class _HistorySearchPageState extends State<HistorySearchPage> {
	String _query = '';
	bool _exactMatch = false;
	RegExp get _queryRegex {
		if (_exactMatch) {
			return RegExp(RegExp.escape(_query), caseSensitive: false);
		}
		return RegExp('(?:${RegExp.escape(_query).replaceAll(' ', ')|(?:')})', caseSensitive: false);
	}
	int numer = 0;
	int denom = 1;
	bool _scanningPhase = false;
	List<ImageboardScoped<HistorySearchResult>>? results;
	ImageboardScoped<ImageboardBoard>? _filterBoard;
	DateTime? _filterDateStart;
	DateTime? _filterDateEnd;
	bool? _filterHasAttachment;
	bool? _filterContainsLink;
	bool? _filterIsThread;
	_FilterSavedThreadsOnly _filterSavedThreadsOnly = _FilterSavedThreadsOnly.everything;
	_FilterYourPostsOnly _filterYourPostsOnly = _FilterYourPostsOnly.everything;
	late final RefreshableListController<ImageboardScoped<HistorySearchResult>> _listController;

	@override
	void initState() {
		super.initState();
		_query = widget.initialQuery;
		_listController = RefreshableListController();
		if (widget.initialSavedThreadsOnly) {
			_filterSavedThreadsOnly = _FilterSavedThreadsOnly.savedThreads;
		}
		if (widget.initialYourPostsOnly) {
			_filterYourPostsOnly = _FilterYourPostsOnly.yourPosts;
		}
		if (widget.initialQuery.isEmpty) {
			results = [];
			Future.microtask(_editQuery);
		}
		else {
			_runQuery();
		}
	}

	Future<void> _runQuery() async {
		final theseResults = <ImageboardScoped<HistorySearchResult>>[];
		final firstPass = <ImageboardScoped<BoardKey>, List<PersistentThreadState>>{};
		for (final threadState in Persistence.sharedThreadStateBox.values) {
			final imageboard = threadState.imageboard;
			if (imageboard == null ||
			    !(threadState.showInHistory ?? false) ||
					!threadState.isThreadCached ||
					!mounted ||
					(_filterBoard != null &&
					(_filterBoard!.imageboard != threadState.imageboard ||
						(_filterBoard!.item.name.isNotEmpty && _filterBoard!.item.name != threadState.board))) ||
						switch (_filterSavedThreadsOnly) {
							_FilterSavedThreadsOnly.everything => false,
							_FilterSavedThreadsOnly.savedThreads => threadState.savedTime == null,
							_FilterSavedThreadsOnly.notSavedThreads => threadState.savedTime != null
						} ||
						switch (_filterYourPostsOnly) {
							_FilterYourPostsOnly.everything || _FilterYourPostsOnly.notYourPosts => false,
							_FilterYourPostsOnly.yourPosts || _FilterYourPostsOnly.repliesToYourPosts => threadState.youIds.isEmpty
						}) {
				continue;
			}
			(firstPass[imageboard.scope(BoardKey(threadState.board))] ??= []).add(threadState);
		}
		final filterDateStart = _filterDateStart;
		final filterDateEnd = _filterDateEnd;
		if (filterDateStart != null || filterDateEnd != null) {
			// Need all lists oldest->newest thread
			for (final list in firstPass.values) {
				list.sort((a, b) => a.id.compareTo(b.id));
			}
			_scanningPhase = true;
			denom = (filterDateStart != null ? firstPass.length : 0) + (filterDateEnd != null ? firstPass.length : 0);
		}
		else {
			denom = 1;
		}
		numer = 0;
		setState(() {});
		if (filterDateStart != null) {
			for (final future in firstPass.entries.toList(growable: false).map((e) async {
				if (!mounted) return;
				final startIndex = await e.value.binarySearchFirstIndexWhereAsync((ts) async {
					final thread = await ts.getThread();
					return thread!.time >= filterDateStart;
				});
				if (startIndex == -1) {
					// No matches
					e.value.clear();
				}
				else {
					e.value.removeRange(0, startIndex);
				}
			})) {
				await future;
				if (!mounted) return;
				setState(() {
					numer++;
				});
			}
		}
		if (filterDateEnd != null) {
			for (final future in firstPass.entries.toList(growable: false).map((e) async {
				if (!mounted || e.value.isEmpty) {
					return;
				}
				final endIndex = await e.value.binarySearchLastIndexWhereAsync((ts) async {
					final thread = await ts.getThread();
					return thread!.time <= filterDateEnd;
				});
				if (endIndex == -1) {
					// No matches
					e.value.clear();
				}
				else {
					e.value.removeRange(endIndex + 1, e.value.length);
				}
			})) {
				await future;
				if (!mounted) return;
				setState(() {
					numer++;
				});
			}
		}
		numer = 0;
		denom = firstPass.values.fold(0, (t, l) => t + l.length);
		_scanningPhase = false;
		setState(() {});
		final queryParts =
				_exactMatch
					? [RegExp(RegExp.escape(_query), caseSensitive: false)]
					: _query.split(' ').map((q) => RegExp(RegExp.escape(q), caseSensitive: false));
		for (final future in firstPass.values.expand((l) => l).map((threadState) async {
			if (!mounted) return;
			final thread = await threadState.getThread();
			if (!mounted) return;
			if (thread != null) {
				for (final post in thread.posts) {
					if (post.isStub || post.isPageStub) {
						continue;
					}
					if (_filterIsThread != null && _filterIsThread != (post.id == thread.id)) {
						continue;
					}
					if (_filterHasAttachment != null && _filterHasAttachment != post.attachments.isNotEmpty) {
						continue;
					}
					if (filterDateStart != null && filterDateStart.isAfter(post.time)) {
						continue;
					}
					if (filterDateEnd != null && filterDateEnd.isBefore(post.time)) {
						continue;
					}
					if (_filterYourPostsOnly == _FilterYourPostsOnly.yourPosts || _filterYourPostsOnly == _FilterYourPostsOnly.notYourPosts) {
						final isYou = threadState.youIds.contains(post.id);
						if ((_filterYourPostsOnly == _FilterYourPostsOnly.yourPosts) != isYou) {
							continue;
						}
					}
					if (_filterYourPostsOnly == _FilterYourPostsOnly.repliesToYourPosts && !threadState.youIds.any(post.repliedToIds.contains)) {
						continue;
					}
					if (
						_query.isNotEmpty &&
						!queryParts.every((query) => post.buildText().contains(query)) &&
						!(post.threadId == post.id && queryParts.every((query) => thread.title?.contains(query) == true))
					) {
						continue;
					}
					if (_filterContainsLink != null && _filterContainsLink != post.containsLink) {
						continue;
					}
					if (post.id == thread.id) {
						theseResults.add(threadState.imageboard!.scope(HistorySearchResult(thread, null)));
					}
					else {
						theseResults.add(threadState.imageboard!.scope(HistorySearchResult(thread, post)));
					}
				}
			}
			if (!mounted) return;
		})) {
			await future;
			if (!mounted) return;
			setState(() {
				numer++;
			});
		}
		theseResults.sort((a, b) => (b.item.post?.time ?? b.item.thread.time).compareTo(a.item.post?.time ?? a.item.thread.time));
		results = theseResults;
		setState(() {});
	}

	Future<void> _editQuery() async {
		bool anyChange = false;
		final controller = TextEditingController(text: _query);
		await showAdaptiveModalPopup(
			context: context,
			builder: (context) => StatefulBuilder(
				builder: (context, setDialogState) => AdaptiveActionSheet(
					title: const Text('History filters'),
					message: DefaultTextStyle(
						style: DefaultTextStyle.of(context).style,
						child: Column(
							mainAxisSize: MainAxisSize.min,
							children: [
								const SizedBox(height: 16),
								Row(
									mainAxisAlignment: MainAxisAlignment.center,
									mainAxisSize: MainAxisSize.min,
									children: [
										SizedBox(
											width: 200,
											child: AdaptiveTextField(
												controller: controller,
												placeholder: 'Query',
												onChanged: (_) => anyChange = true
											)
										),
										const SizedBox(width: 8),
										AdaptiveIconButton(
											padding: EdgeInsets.zero,
											minSize: 0,
											icon: Row(
												mainAxisSize: MainAxisSize.min,
												children: [
													Icon(
														_exactMatch ?CupertinoIcons.checkmark_square : CupertinoIcons.square
													),
													const Text('Exact')
												]
											),
											onPressed: () {
												_exactMatch = !_exactMatch;
												anyChange = true;
												setDialogState(() {});
											}
										)
									]
								),
								const SizedBox(height: 16),
								Row(
									mainAxisAlignment: MainAxisAlignment.center,
									children: [
										AdaptiveFilledButton(
											padding: const EdgeInsets.all(8),
											onPressed: () async {
												final newBoard = await Navigator.of(context).push<ImageboardScoped<ImageboardBoard>>(TransparentRoute(
													builder: (ctx) => BoardSwitcherPage(
														initialImageboardKey: _filterBoard?.imageboard.key,
														allowPickingWholeSites: true
													)
												));
												if (newBoard != null) {
													_filterBoard = newBoard;
													setDialogState(() {});
													anyChange = true;
												}
											},
											child: Row(
												mainAxisSize: MainAxisSize.min,
												children: _filterBoard == null ? const [
													Text('Board: any')
												] : [
													if (_filterBoard?.item.name == '')
														const Text('Site: ')
													else
														const Text('Board: '),
													ImageboardIcon(
														imageboardKey: _filterBoard!.imageboard.key,
														boardName: _filterBoard!.item.name
													),
													const SizedBox(width: 8),
													if (_filterBoard?.item.name == '')
														Text(_filterBoard!.imageboard.site.name)
													else
														Text(_filterBoard!.imageboard.site.formatBoardName(_filterBoard!.item.name))
												]
											)
										),
										if (_filterBoard != null) Padding(
											padding: const EdgeInsets.only(left: 8),
											child: AdaptiveIconButton(
												onPressed: () {
													_filterBoard = null;
													anyChange = true;
													setDialogState(() {});
												},
												icon: const Icon(CupertinoIcons.xmark),
												minSize: 0,
												padding: EdgeInsets.zero
											)
										)
									]
								),
								const SizedBox(height: 16),
								AdaptiveFilledButton(
									padding: const EdgeInsets.all(8),
									onPressed: () async {
										_filterDateStart = (await pickDate(
											context: context,
											initialDate: _filterDateStart
										))?.startOfDay;
										setDialogState(() {});
										anyChange = true;
									},
									child: Text(_filterDateStart == null ? 'Pick Start Date' : 'Start Date: ${_filterDateStart?.toISO8601Date}')
								),
								const SizedBox(height: 16),
								AdaptiveFilledButton(
									padding: const EdgeInsets.all(8),
									onPressed: () async {
										_filterDateEnd = (await pickDate(
											context: context,
											initialDate: _filterDateEnd
										))?.endOfDay;
										setDialogState(() {});
										anyChange = true;
									},
									child: Text(_filterDateEnd == null ? 'Pick End Date' : 'End Date: ${_filterDateEnd?.toISO8601Date}')
								),
								const SizedBox(height: 16),
								AdaptiveSegmentedControl<NullSafeOptional>(
									groupValue: _filterIsThread.value,
									children: const {
										NullSafeOptional.false_: (null, 'Only replies'),
										NullSafeOptional.null_: (null, 'Any'),
										NullSafeOptional.true_: (null, 'Only threads')
									},
									onValueChanged: (v) {
										_filterIsThread = v.value;
										setDialogState(() {});
										anyChange = true;
									}
								),
								const SizedBox(height: 16),
								AdaptiveSegmentedControl<NullSafeOptional>(
									groupValue: _filterHasAttachment.value,
									children: const {
										NullSafeOptional.false_: (null, 'Only without attachment(s)'),
										NullSafeOptional.null_: (null, 'Any'),
										NullSafeOptional.true_: (null, 'Only with attachment(s)')
									},
									onValueChanged: (v) {
										_filterHasAttachment = v.value;
										setDialogState(() {});
										anyChange = true;
									}
								),
								const SizedBox(height: 16),
								AdaptiveSegmentedControl<NullSafeOptional>(
									groupValue: _filterContainsLink.value,
									children: const {
										NullSafeOptional.false_: (null, 'Only without link(s)'),
										NullSafeOptional.null_: (null, 'Any'),
										NullSafeOptional.true_: (null, 'Only with link(s)')
									},
									onValueChanged: (v) {
										_filterContainsLink = v.value;
										setDialogState(() {});
										anyChange = true;
									}
								),
								const SizedBox(height: 16),
								AdaptiveSegmentedControl<_FilterSavedThreadsOnly>(
									groupValue: _filterSavedThreadsOnly,
									children: const {
										_FilterSavedThreadsOnly.notSavedThreads: (null, 'Only unsaved threads'),
										_FilterSavedThreadsOnly.everything: (null, 'Any'),
										_FilterSavedThreadsOnly.savedThreads: (null, 'Only saved threads'),
									},
									onValueChanged: (v) {
										_filterSavedThreadsOnly = v;
										setDialogState(() {});
										anyChange = true;
									}
								),
								const SizedBox(height: 16),
								AdaptiveSegmentedControl<_FilterYourPostsOnly>(
									groupValue: _filterYourPostsOnly,
									children: const {
										_FilterYourPostsOnly.notYourPosts: (null, 'Only others\' posts'),
										_FilterYourPostsOnly.everything: (null, 'Any'),
										_FilterYourPostsOnly.yourPosts: (null, 'Only your posts'),
										_FilterYourPostsOnly.repliesToYourPosts: (null, 'Only replies to your posts'),
									},
									onValueChanged: (v) {
										_filterYourPostsOnly = v;
										setDialogState(() {});
										anyChange = true;
									}
								)
							]
						)
					),
					actions: [
						AdaptiveActionSheetAction(
							onPressed: () => Navigator.pop(context),
							child: const Text('Done')
						)
					]
				)
			)
		);
		_query = controller.text;
		if (anyChange || (results?.isEmpty ?? true)) {
			setState(() {
				results = null;
			});
			_runQuery();
		}
	}

	@override
	Widget build(BuildContext context) {
		final queryPattern = _queryRegex;
		Widget itemBuilder(BuildContext context, ImageboardScoped<HistorySearchResult> row, RefreshableListItemOptions options) {
		if (row.item.post != null) {
			return ImageboardScope(
				imageboardKey: null,
				imageboard: row.imageboard,
				child: ChangeNotifierProvider<PostSpanZoneData>(
					create: (context) => PostSpanRootZoneData(
						imageboard: row.imageboard,
						thread: row.item.thread,
						semanticRootIds: [-11],
						style: PostSpanZoneStyle.linear
					),
					builder: (context, _) => PostRow(
						post: row.item.post!,
						onThumbnailTap: (initialAttachment) {
							final attachments = {
								for (final w in _listController.items)
									for (final attachment in w.item.item.post?.attachments ?? w.item.item.thread.attachments)
										attachment: w.item
							};
							showGallery(
								context: context,
								attachments: attachments.keys.toList(),
								threads: {
									for (final item in attachments.entries)
										item.key: item.value.imageboard.scope(item.value.item.thread)
								},
								posts: {
									for (final item in attachments.entries)
										if (item.value.item.post case Post post)
											item.key: item.value.imageboard.scope(post)
								},
								onThreadSelected: (t) {
									final x = _listController.items.firstWhere((w) => w.item.imageboard == t.imageboard && w.item.item.thread.identifier == t.item.identifier).item;
									widget.onResultSelected(x.imageboard.scope(x.item.identifier));
								},
								initialAttachment: attachments.keys.firstWhere((a) => a.id == initialAttachment.id),
								onChange: (attachment) {
									final value = attachments.entries.firstWhere((_) => _.key.id == attachment.id).value;
									_listController.animateTo((p) => p == value);
								},
								semanticParentIds: [-11],
								heroOtherEndIsBoxFitCover: Settings.instance.squareThumbnails
							);
						},
						showCrossThreadLabel: false,
						showBoardName: true,
						showSiteIcon: ImageboardRegistry.instance.count > 1,
						allowTappingLinks: false,
						isSelected: (context.watch<MasterDetailLocation?>()?.twoPane != false) && widget.selectedResult?.imageboard == row.imageboard && widget.selectedResult?.item == row.item.identifier,
						onTap: () {
							row.imageboard.persistence.getThreadState(row.item.identifier.thread).thread ??= row.item.thread;
							widget.onResultSelected(row.imageboard.scope(row.item.identifier));
						},
						hideThumbnails: options.hideThumbnails,
						baseOptions: PostSpanRenderOptions(
							highlightPattern: options.queryPattern ?? (_query.isEmpty ? null : queryPattern)
						),
					)
				)
			);
		}
		else {
			return ImageboardScope(
				imageboardKey: null,
				imageboard: row.imageboard,
				child: Builder(
					builder: (context) => CupertinoButton(
						padding: EdgeInsets.zero,
						onPressed: () {
							row.imageboard.persistence.getThreadState(row.item.identifier.thread).thread ??= row.item.thread;
							widget.onResultSelected(row.imageboard.scope(row.item.identifier));
						},
						child: ThreadRow(
							thread: row.item.thread,
							onThumbnailTap: (attachment) {
								final attachments = {
									for (final w in _listController.items)
										for (final attachment in w.item.item.post?.attachments ?? w.item.item.thread.attachments)
											attachment: w.item
								};
								showGallery(
									context: context,
									attachments: attachments.keys.toList(),
									initialAttachment: attachment,
									semanticParentIds: [-11],
									threads: {
										for (final item in attachments.entries)
											item.key: item.value.imageboard.scope(item.value.item.thread)
									},
									posts: {
										for (final item in attachments.entries)
											if (item.value.item.post case Post post)
												item.key: item.value.imageboard.scope(post)
									},
									heroOtherEndIsBoxFitCover: Settings.instance.squareThumbnails
								);
							},
							isSelected: (context.watch<MasterDetailLocation?>()?.twoPane != false) && widget.selectedResult?.imageboard == row.imageboard && widget.selectedResult?.item == row.item.identifier,
							showBoardName: true,
							showSiteIcon: ImageboardRegistry.instance.count > 1,
							hideThumbnails: options.hideThumbnails,
							baseOptions: PostSpanRenderOptions(
								highlightPattern: _query.isEmpty ? null : queryPattern
							),
						)
					)
				)
			);
		}
	}
		return AdaptiveScaffold(
			bar: AdaptiveBar(
				title: FittedBox(
					fit: BoxFit.contain,
					child: Row(
						mainAxisSize: MainAxisSize.min,
						children: [
							Text('${results != null ? '${results?.length} results' : 'Searching'}${_query.isNotEmpty ? ' for "$_query"' : ''}'),
							...[
								if (_filterBoard != null) Row(
									mainAxisSize: MainAxisSize.min,
									children: [
										ImageboardIcon(
											imageboardKey: _filterBoard!.imageboard.key,
											boardName: _filterBoard!.item.name
										),
										const SizedBox(width: 8),
										if (_filterBoard!.item.name == '')
											Text(_filterBoard!.imageboard.site.name)
										else
											Text(_filterBoard!.imageboard.site.formatBoardName(_filterBoard!.item.name))
									]
								),
								if (_filterSavedThreadsOnly == _FilterSavedThreadsOnly.savedThreads)
									const Text('Saved Thread')
								else if (_filterSavedThreadsOnly == _FilterSavedThreadsOnly.notSavedThreads)
									const Text('Unsaved Thread'),
								if (_filterYourPostsOnly == _FilterYourPostsOnly.yourPosts)
									const Text('(You)')
								else if (_filterYourPostsOnly == _FilterYourPostsOnly.notYourPosts)
									const Text('Not (You)')
								else if (_filterYourPostsOnly == _FilterYourPostsOnly.repliesToYourPosts)
									const Text('Replying to (You)'),
								if (_filterDateStart != null && _filterDateEnd != null)
									Text(_filterDateStart!.startOfDay == _filterDateEnd!.startOfDay ?
										_filterDateStart!.toISO8601Date :
										'${_filterDateStart?.toISO8601Date} -> ${_filterDateEnd?.toISO8601Date}')
								else ...[
									if (_filterDateStart != null) Text('After ${_filterDateStart?.toISO8601Date}'),
									if (_filterDateEnd != null) Text('Before ${_filterDateEnd?.toISO8601Date}')
								],
								if (_filterIsThread != null)
									_filterIsThread! ? const Text('Threads') : const Text('Replies'),
								if (_filterHasAttachment != null)
									_filterHasAttachment! ? const Text('With attachment(s)') : const Text('Without attachment(s)'),
								if (_filterContainsLink != null)
									_filterContainsLink! ? const Text('Containing link(s)') : const Text('Not containing link(s)')
							].map((child) => Container(
								margin: const EdgeInsets.only(left: 4, right: 4),
								padding: const EdgeInsets.all(4),
								decoration: BoxDecoration(
									color: ChanceTheme.primaryColorOf(context).withOpacity(0.3),
									borderRadius: const BorderRadius.all(Radius.circular(4))
								),
								child: child
							))
						]
					)
				),
				actions: [
					AdaptiveIconButton(
						onPressed: _editQuery,
						icon: const Icon(CupertinoIcons.slider_horizontal_3)
					)
				]
			),
			body: (results == null) ? Center(
				child: SizedBox(
					width: 100,
					child: Column(
						mainAxisSize: MainAxisSize.min,
						children: [
							// Maintain centering
							const Text(''),
							const SizedBox(height: 8),
							ClipRRect(
								borderRadius: const BorderRadius.all(Radius.circular(8)),
								child: LinearProgressIndicator(
									value: denom == 0 ? null : numer / denom,
									backgroundColor: ChanceTheme.primaryColorOf(context).withOpacity(0.3),
									color: ChanceTheme.primaryColorOf(context).withOpacity(_scanningPhase ? 0.5 : 1.0),
									minHeight: 8
								)
							),
							const SizedBox(height: 8),
							if (!_scanningPhase && numer > 0)
								Text('$numer / $denom', style: CommonTextStyles.tabularFigures)
							else
								// Maintain height
								const Text('')
						]
					)
				)
			) : MaybeScrollbar(
				child: RefreshableList<ImageboardScoped<HistorySearchResult>>(
					listUpdater: (_) => throw UnimplementedError(),
					id: 'historysearch',
					rebuildId: '${widget.selectedResult}',
					filterHint: 'Filter...',
					controller: _listController,
					filterableAdapter: (i) => (i.imageboard.key, (i.item.post?.isThread ?? false) ? i.item.thread : (i.item.post ?? i.item.thread)),
					initialList: results,
					disableUpdates: true,
					itemBuilder: itemBuilder
				)
			)
		);
	}

	@override
	void dispose() {
		super.dispose();
		_listController.dispose();
	}
}