import 'dart:async';
import 'dart:math';

import 'package:chan/models/attachment.dart';
import 'package:chan/models/thread.dart';
import 'package:chan/pages/gallery.dart';
import 'package:chan/services/apple.dart';
import 'package:chan/services/imageboard.dart';
import 'package:chan/services/network_image_provider.dart';
import 'package:chan/services/persistence.dart';
import 'package:chan/services/settings.dart';
import 'package:chan/services/util.dart';
import 'package:chan/widgets/adaptive.dart';
import 'package:chan/widgets/attachment_thumbnail.dart';
import 'package:chan/widgets/attachment_viewer.dart';
import 'package:chan/widgets/context_menu.dart';
import 'package:chan/widgets/cupertino_inkwell.dart';
import 'package:chan/widgets/refreshable_list.dart';
import 'package:flutter/cupertino.dart';
import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:flutter/rendering.dart';
import 'package:mutex/mutex.dart';
import 'package:pool/pool.dart';
import 'package:provider/provider.dart';

class AttachmentsPage extends StatefulWidget {
	final List<TaggedAttachment> attachments;
	final TaggedAttachment? initialAttachment;
	final ValueChanged<TaggedAttachment>? onChange;
	final PersistentThreadState threadState;
	const AttachmentsPage({
		required this.attachments,
		this.initialAttachment,
		this.onChange,
		required this.threadState,
		Key? key
	}) : super(key: key);

	@override
	createState() => _AttachmentsPageState();
}

const int _kImageLoadingPoolSize = 3;
class _AttachmentsPageState extends State<AttachmentsPage> {
	final Map<TaggedAttachment, AttachmentViewerController> _controllers = {};
	late final RefreshableListController<TaggedAttachment> _controller;
	TaggedAttachment? _lastPrimary;
	AttachmentViewerController? get _lastPrimaryController {
		if (_lastPrimary == null) {
			return null;
		}
		return _controllers[_lastPrimary!];
	}
	final _listKey = GlobalKey(debugLabel: '_AttachmentsPageState._listKey');
	final _videoLoadingLock = Mutex();
	final _videoLoadingQueue = <AttachmentViewerController>[];
	final _imageLoadingPool = Pool(_kImageLoadingPoolSize);
	final _imageLoadingQueue = <TaggedAttachment>[];
	TaggedAttachment? _lastMiddleVisibleItem;

	void _queueVideoLoading(AttachmentViewerController controller) {
		_videoLoadingQueue.add(controller);
		_videoLoadingLock.protect(() async {
			if (_videoLoadingQueue.isEmpty) {
				return;
			}
			// LIFO stack
			final item = _videoLoadingQueue.removeLast();
			await Future.microtask(() => item.preloadFullAttachment());
		});
	}

	Future<void> _imageQueueWorker() async {
		if (_imageLoadingQueue.isEmpty) {
			return;
		}
		// LIFO stack
		final item = _imageLoadingQueue.removeLast();
		if (_imageLoadingQueue.length > _kImageLoadingPoolSize) {
			// Maybe reorder to prioritize onscreen items
			if (random.nextBool() && !_controller.isOnscreen(item)) {
				_imageLoadingQueue.insert(0, item);
				_imageLoadingPool.withResource(_imageQueueWorker);
				return;
			}
		}
		await Future.microtask(() => _getController(item).preloadFullAttachment());
	}

	void _queueImageLoading(TaggedAttachment attachment) {
		_imageLoadingQueue.add(attachment);
		_imageLoadingPool.withResource(_imageQueueWorker);
	}

	@override
	void initState() {
		super.initState();
		_controller = RefreshableListController();
		if (widget.initialAttachment != null && !Settings.instance.attachmentsPageUsePageView) {
			Future.delayed(const Duration(milliseconds: 250), () {
				_controller.animateTo((a) => a.attachment.id == widget.initialAttachment?.attachment.id);
			});
		}
		Future.microtask(() {
			_controller.slowScrolls.addListener(_onSlowScroll);
			_onSlowScroll();
		});
	}

	void _onSlowScroll() {
		final middleVisibleItem = _controller.middleVisibleItem;
		if (middleVisibleItem != null) {
			if (middleVisibleItem != _lastMiddleVisibleItem) {
				widget.onChange?.call(middleVisibleItem);
			}
			final settings = Settings.instance;
			final maxColumnWidth = settings.attachmentsPageMaxCrossAxisExtent;
			final screenWidth = (context.findRenderObject() as RenderBox?)?.paintBounds.width ?? double.infinity;
			final columnCount = max(1, screenWidth / maxColumnWidth).ceil();
			if (columnCount == 1) {
				// This is one-column view
				if (middleVisibleItem != _lastMiddleVisibleItem) {
					if (_lastMiddleVisibleItem != null) {
						_getController(_lastMiddleVisibleItem!).isPrimary = false;
					}
					_getController(middleVisibleItem).isPrimary = true;
					if (settings.autoloadAttachments) {
						Future.microtask(_getController(middleVisibleItem).loadFullAttachment);
					}
				}
			}
			_lastMiddleVisibleItem = middleVisibleItem;
		}
		if (_lastPrimary != null) {
			if (!_controller.isOnscreen(_lastPrimary!)) {
				_lastPrimaryController?.isPrimary = false;
			}
		}
	}

	AttachmentViewerController _getController(TaggedAttachment attachment) {
		return _controllers.putIfAbsent(attachment, () {
			final controller = AttachmentViewerController(
				context: context,
				attachment: attachment.attachment,
				imageboard: context.read<Imageboard>(),
				isPrimary: false
			);
			if (Settings.instance.autoloadAttachments && !attachment.attachment.isRateLimited) {
				if (attachment.attachment.type.isVideo) {
					_queueVideoLoading(controller);
				}
				else {
					_queueImageLoading(attachment);
				}
			}
			return controller;
		});
	}

	@override
	Widget build(BuildContext context) {
		final maxCrossAxisExtent = Settings.attachmentsPageMaxCrossAxisExtentSetting.watch(context);
		final usePageView = Settings.attachmentsPageUsePageViewSetting.watch(context);
		return AdaptiveScaffold(
			resizeToAvoidBottomInset: false,
			body: Stack(
				children: [
					Container(
						color: Colors.black,
						child: usePageView ? GalleryPage(
							initialAttachment: widget.initialAttachment,
							attachments: widget.attachments,
							axis: Axis.vertical,
							allowScroll: true,
							allowPop: false,
							heroOtherEndIsBoxFitCover: false,
							posts: {
								if (widget.threadState.thread case Thread t)
									if (widget.threadState.imageboard case Imageboard imageboard)
										for (final post in t.posts)
											for (final attachment in post.attachments)
												attachment: imageboard.scope(post)
							},
							additionalContextMenuActionsBuilder: (attachment) => [
								ContextMenuAction(
									trailingIcon: CupertinoIcons.return_icon,
									onPressed: () {
										Navigator.pop(context, attachment);
									},
									child: const Text('Scroll to post')
								)
							],
						) : RefreshableList<TaggedAttachment>(
							key: _listKey,
							filterableAdapter: null,
							id: '${widget.attachments.length} attachments',
							controller: _controller,
							listUpdater: (_) => throw UnimplementedError(),
							disableUpdates: true,
							initialList: widget.attachments,
							gridDelegate: SliverStaggeredGridDelegate(
								aspectRatios: widget.attachments.map((a) {
									final rawRatio = (a.attachment.width ?? 1) / (a.attachment.height ?? 1);
									// Prevent too extreme dimensions
									return rawRatio.clamp(1/6, 6.0);
								}).toList(),
								maxCrossAxisExtent: maxCrossAxisExtent
							),
							itemBuilder: (context, attachment, options) => GestureDetector(
								onDoubleTap: () {
									Navigator.pop(context, attachment);
								},
								child: CupertinoInkwell(
									padding: EdgeInsets.zero,
									onPressed: () async {
										final lastPrimary = _lastPrimaryController;
										lastPrimary?.isPrimary = false;
										final goodSource = _getController(attachment).goodImagePublicSource;
										if (attachment.attachment.type == AttachmentType.image) {
											// Ensure full-resolution copy is loaded into the image cache
											final stream = CNetworkImageProvider(
												goodSource.toString(),
												client: _getController(attachment).site.client,
												cache: true,
												headers: _getController(attachment).getHeaders(goodSource)
											).resolve(ImageConfiguration.empty);
											final completer = Completer<void>();
											ImageStreamListener? listener;
											stream.addListener(listener = ImageStreamListener((image, synchronousCall) {
												completer.complete();
												final toRemove = listener;
												if (toRemove != null) {
													stream.removeListener(toRemove);
												}
											}, onError: (e, st) {
												completer.completeError(e, st);
												final toRemove = listener;
												if (toRemove != null) {
													stream.removeListener(toRemove);
												}
											}));
											await completer.future;
										}
										if (!context.mounted) {
											return;
										}
										await showGalleryPretagged(
											context: context,
											attachments: widget.attachments,
											initialGoodSources: {
												for (final controller in _controllers.values)
													if (controller.goodImageSource != null)
														controller.attachment: controller.goodImageSource!
											},
											posts: {
												if (widget.threadState.thread case Thread t)
													if (widget.threadState.imageboard case Imageboard imageboard)
														for (final post in t.posts)
															for (final attachment in post.attachments)
																attachment: imageboard.scope(post)
											},
											initialAttachment: attachment,
											useHeroDestinationWidget: true,
											heroOtherEndIsBoxFitCover: true,
											additionalContextMenuActionsBuilder: (attachment) => [
												ContextMenuAction(
													trailingIcon: CupertinoIcons.return_icon,
													onPressed: () {
														Navigator.of(context, rootNavigator: true).pop();
														Navigator.pop(context, attachment);
													},
													child: const Text('Scroll to post')
												)
											]
										);
										lastPrimary?.isPrimary = true;
										Future.microtask(() => _getController(attachment).loadFullAttachment());
									},
									child: Stack(
										alignment: Alignment.center,
										children: [
											Positioned.fill(
												child: DecoratedBox(
													decoration: BoxDecoration(
														color: HSVColor.fromAHSV(1, attachment.attachment.id.hashCode.toDouble() % 360, 0.5, 0.2).toColor()
													)
												)
											),
											Hero(
												tag: attachment,
												createRectTween: (startRect, endRect) {
													if (startRect != null && endRect != null) {
														if (attachment.attachment.type == AttachmentType.image) {
															// Need to deflate the original startRect because it has inbuilt layoutInsets
															// This AttachmentViewer doesn't know about them.
															final rootPadding = MediaQueryData.fromView(View.of(context)).padding - sumAdditionalSafeAreaInsets();
															startRect = rootPadding.deflateRect(startRect);
														}
														if (attachment.attachment.width != null && attachment.attachment.height != null) {
															// This is AttachmentViewer -> AttachmentThumbnail (cover)
															// Need to shrink the startRect, so it only contains the image
															final fittedStartSize = applyBoxFit(BoxFit.contain, Size(attachment.attachment.width!.toDouble(), attachment.attachment.height!.toDouble()), startRect.size).destination;
															startRect = Alignment.center.inscribe(fittedStartSize, startRect);
														}
													}
													return CurvedRectTween(curve: Curves.ease, begin: startRect, end: endRect);
												},
												child: AnimatedBuilder(
													animation: _getController(attachment),
													builder: (context, child) => SizedBox.expand(
														child: AttachmentViewer(
															controller: _getController(attachment),
															allowGestures: false,
															semanticParentIds: const [-101],
															useHeroDestinationWidget: true,
															heroOtherEndIsBoxFitCover: true,
															videoThumbnailMicroPadding: false,
															onlyRenderVideoWhenPrimary: true,
															fit: BoxFit.cover,
															maxWidth: PlatformDispatcher.instance.views.first.physicalSize.width * PlatformDispatcher.instance.views.first.devicePixelRatio, // no zoom
															additionalContextMenuActions: [
																ContextMenuAction(
																	trailingIcon: CupertinoIcons.return_icon,
																	onPressed: () {
																		Navigator.pop(context, attachment);
																	},
																	child: const Text('Scroll to post')
																)
															]
														)
													)
												)
											),
											AnimatedBuilder(
												animation: _getController(attachment),
												builder: (context, child) => Visibility(
													visible: (attachment.attachment.type.isVideo && !_getController(attachment).isPrimary),
													child: CupertinoButton(
														onPressed: () {
															_lastPrimaryController?.isPrimary = false;
															Future.microtask(() => _getController(attachment).loadFullAttachment());
															_lastPrimary = attachment;
															_lastPrimaryController?.isPrimary = true;
														},
														child: const Icon(CupertinoIcons.play_fill, size: 50)
													)
												)
											)
										]
									)
								)
							)
						)
					)
				]
			)
		);
	}

	@override
	void dispose() {
		super.dispose();
		_controller.slowScrolls.removeListener(_onSlowScroll);
		_controller.dispose();
		for (final controller in _controllers.values) {
			controller.dispose();
		}
		_videoLoadingQueue.clear();
		_imageLoadingQueue.clear();
	}
}

typedef StaggeredGridMember = ({int index, double height, double offset});

class SliverStaggeredGridDelegate extends SliverGridDelegate {
	final List<double> aspectRatios;
	final double maxCrossAxisExtent;

	const SliverStaggeredGridDelegate({
		required this.aspectRatios,
		required this.maxCrossAxisExtent
	});

	@override
	SliverGridLayout getLayout(SliverConstraints constraints) {
		final columnCount = (constraints.crossAxisExtent / maxCrossAxisExtent).ceil();
		final width = constraints.crossAxisExtent / columnCount;
		final columns = List.generate(columnCount, (_) => <StaggeredGridMember>[]);
		final columnHeightRunningTotals = List.generate(columnCount, (_) => 0.0);
		for (int i = 0; i < aspectRatios.length; i++) {
			int column = -1;
			double minHeight = double.infinity;
			for (int j = 0; j < columnCount; j++) {
				if (columnHeightRunningTotals[j] < minHeight) {
					minHeight = columnHeightRunningTotals[j];
					column = j;
				}
			}
			columns[column].add((
				index: i,
				height: width / aspectRatios[i],
				offset: columnHeightRunningTotals[column]
			));
			columnHeightRunningTotals[column] += columns[column].last.height;
		}
		if (aspectRatios.length > columnCount) {
			for (int swap = 0; swap < columnCount; swap++) {
				int shortestColumn = -1;
				double shortestHeight = double.infinity;
				int tallestColumn = -1;
				double tallestHeight = -1;
				for (int i = 0; i < columns.length; i++) {
					final height = columns[i].last.height + columns[i].last.offset;
					if (height < shortestHeight) {
						shortestColumn = i;
						shortestHeight = height;
					}
					if (height > tallestHeight) {
						tallestColumn = i;
						tallestHeight = height;
					}
				}
				final mismatch = tallestHeight - shortestHeight;
				if (columns[tallestColumn].length > 1) {
					final toMove = columns[tallestColumn][columns[tallestColumn].length - 2];
					final mismatchAfter = (mismatch - (2 * toMove.height)).abs();
					if (mismatchAfter < mismatch) {
						columns[tallestColumn].removeAt(columns[tallestColumn].length - 2);
						columns[tallestColumn].last = (
							index: columns[tallestColumn].last.index,
							height: columns[tallestColumn].last.height,
							offset: columns[tallestColumn].last.offset - toMove.height,
						);
						columns[shortestColumn].add((
							index: toMove.index,
							height: toMove.height,
							offset: columns[shortestColumn].last.offset + columns[shortestColumn].last.height
						));
					}
					else {
						break;
					}
				}
			}
		}
		return SliverStaggeredGridLayout(
			columns: columns,
			columnWidth: width
		);
	}

	@override
	bool shouldRelayout(SliverStaggeredGridDelegate oldDelegate) {
		return !listEquals(aspectRatios, oldDelegate.aspectRatios) || maxCrossAxisExtent != oldDelegate.maxCrossAxisExtent;
	}
	
}

class SliverStaggeredGridLayout extends SliverGridLayout {
	final double columnWidth;
	final Map<int, (int, StaggeredGridMember)> _lookupTable = {};
	final List<List<StaggeredGridMember>> columns;

	SliverStaggeredGridLayout({
		required this.columns,
		required this.columnWidth
	}) {
		_lookupTable.addAll({
			for (int i = 0; i < columns.length; i++)
				for (int j = 0; j < columns[i].length; j++)
					columns[i][j].index: (i, columns[i][j])
		});
	}

	@override
	double computeMaxScrollOffset(int childCount) {
		return columns.map((c) => c.fold<double>(0, (runningMax, item) {
			if (item.index < childCount) {
				return max(runningMax, item.offset + item.height);
			}
			return runningMax;
		})).fold<double>(0, max);
	}

	@override
	SliverGridGeometry getGeometryForChildIndex(int index) {
		final item = _lookupTable[index];
		if (item == null) {
			print('Tried to get geometry for invalid index $index (max is ${_lookupTable.length})');
			return const SliverGridGeometry(
				scrollOffset: 0,
				crossAxisOffset: 0,
				mainAxisExtent: 0,
				crossAxisExtent: 0
			);
		}
		return SliverGridGeometry(
			scrollOffset: item.$2.offset,
			crossAxisOffset: columnWidth * item.$1,
			mainAxisExtent: item.$2.height,
			crossAxisExtent: columnWidth
		);
	}

	@override
	int getMaxChildIndexForScrollOffset(double scrollOffset) {
		return _lookupTable.values.where((w) => w.$2.offset < scrollOffset).fold<int>(0, (t, x) => max(t, x.$2.index));
	}

	@override
	int getMinChildIndexForScrollOffset(double scrollOffset) {
		return _lookupTable.values.where((w) => (w.$2.height + w.$2.offset) >= scrollOffset).fold<int>(_lookupTable.length - 1, (t, x) => min(t, x.$2.index));
	}
}
