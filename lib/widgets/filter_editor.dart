import 'package:chan/models/board.dart';
import 'package:chan/pages/board_switcher.dart';
import 'package:chan/services/filtering.dart';
import 'package:chan/services/imageboard.dart';
import 'package:chan/services/settings.dart';
import 'package:chan/services/theme.dart';
import 'package:chan/util.dart';
import 'package:chan/widgets/adaptive.dart';
import 'package:chan/widgets/imageboard_icon.dart';
import 'package:chan/widgets/util.dart';
import 'package:flutter/cupertino.dart';
import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:google_fonts/google_fonts.dart';
import 'package:provider/provider.dart';

class FilterEditor extends StatefulWidget {
	final bool showRegex;
	final String? forBoard;
	final CustomFilter? blankFilter;
	final bool fillHeight;

	const FilterEditor({
		required this.showRegex,
		this.forBoard,
		this.blankFilter,
		this.fillHeight = false,
		Key? key
	}) : super(key: key);

	@override
	createState() => _FilterEditorState();
}

/// Lazy hack to deal with pipe within groups
List<String> _splitByTopLevelPipe(String str) {
	final out = <String>[];
	final buffer = StringBuffer();
	bool escapeNext = false;
	final stack = <String>[];
	for (int i = 0; i < str.length; i++) {
		final c = str[i];
		if (c == '|' && stack.isEmpty) {
			out.add(buffer.toString());
			buffer.clear();
			continue;
		}
		buffer.write(c);
		if (escapeNext) {
			escapeNext = false;
			continue;
		}
		if (c == '\\') {
			escapeNext = true;
		}
		else if (c == '(' || c == '[') {
			stack.add(c);
		}
		else if (c == ')') {
			if (stack.tryLast == '(') {
				stack.removeLast();
			}
			else {
				// Bail
				Future.error(FormatException('Missing opening (', str, i), StackTrace.current);
				return [str];
			}
		}
		else if (c == ']') {
			if (stack.tryLast == '[') {
				stack.removeLast();
			}
			else {
				// Bail
				Future.error(FormatException('Missing opening [', str, i), StackTrace.current);
				return [str];
			}
		}
	}
	out.add(buffer.toString());
	return out;
}

Future<void> editSiteSet({
	required BuildContext context,
	required Set<String> siteKeys,
	required String title,
}) async {
	final theme = context.read<SavedTheme>();
	final siteKeyList = siteKeys.toList();
	await showAdaptiveDialog(
		barrierDismissible: true,
		context: context,
		builder: (context) => StatefulBuilder(
			builder: (context, setDialogState) {
				final unselectedImageboards = ImageboardRegistry.instance.imageboards.where((imageboard) => !siteKeyList.contains(imageboard.key)).toList();
				return AdaptiveAlertDialog(
					title: Padding(
						padding: const EdgeInsets.only(bottom: 16),
						child: Text(title)
					),
					content: SizedBox(
						width: 100,
						height: 350,
						child: ListView.builder(
							itemCount: siteKeyList.length,
							itemBuilder: (context, i) {
								final imageboard = ImageboardRegistry.instance.getImageboard(siteKeyList[i]);
								return Padding(
									padding: const EdgeInsets.all(4),
									child: Container(
										decoration: BoxDecoration(
											borderRadius: const BorderRadius.all(Radius.circular(4)),
											color: theme.primaryColor.withOpacity(0.1)
										),
										padding: const EdgeInsets.only(left: 16),
										child: Row(
											children: [
												if (imageboard != null) Padding(
													padding: const EdgeInsets.only(right: 8),
													child: ImageboardIcon(
														site: imageboard.site
													)
												),
												Expanded(
													child: Text(imageboard?.site.name ?? 'Unknown site: "${siteKeyList[i]}"', style: const TextStyle(fontSize: 15), textAlign: TextAlign.left)
												),
												CupertinoButton(
													child: const Icon(CupertinoIcons.delete),
													onPressed: () {
														siteKeyList.removeAt(i);
														setDialogState(() {});
													}
												)
											]
										)
									)
								);
							}
						)
					),
					actions: [
						AdaptiveDialogAction(
							onPressed: unselectedImageboards.isEmpty ? null : () async {
								final controller = TextEditingController();
								final newItem = await showAdaptiveModalPopup<Imageboard?>(
									context: context,
									builder: (context) => AdaptiveActionSheet(
										title: const Text('Select site'),
										actions: unselectedImageboards.map((imageboard) => AdaptiveActionSheetAction(
											child: Row(
												mainAxisSize: MainAxisSize.min,
												children: [
													ImageboardIcon(imageboardKey: imageboard.key),
													const SizedBox(width: 8),
													Text(imageboard.site.name)
												]
											),
											onPressed: () {
												Navigator.of(context, rootNavigator: true).pop(imageboard);
											}
										)).toList(),
										cancelButton: AdaptiveActionSheetAction(
											child: const Text('Cancel'),
											onPressed: () => Navigator.of(context, rootNavigator: true).pop()
										)
									)
								);
								if (newItem != null) {
									siteKeyList.add(newItem.key);
									setDialogState(() {});
								}
								controller.dispose();
							},
							child: const Text('Add site')
						),
						AdaptiveDialogAction(
							child: const Text('Close'),
							onPressed: () => Navigator.pop(context)
						)
					]
				);
			}
		)
	);
	siteKeys.clear();
	siteKeys.addAll(siteKeyList);
}

Future<void> editBoardSet({
	required BuildContext context,
	required Set<String> boards,
	required String title,
}) async {
	final theme = context.read<SavedTheme>();
	final boardList = boards.toList();
	await showAdaptiveDialog(
		barrierDismissible: true,
		context: context,
		builder: (context) => StatefulBuilder(
			builder: (context, setDialogState) => AdaptiveAlertDialog(
				title: Padding(
					padding: const EdgeInsets.only(bottom: 16),
					child: Text(title)
				),
				content: SizedBox(
					width: 100,
					height: 350,
					child: ListView.builder(
						itemCount: boardList.length,
						itemBuilder: (context, i) {
							final (imageboardKey, boardName) = switch (boardList[i].indexOf('/')) {
								-1 => (null, boardList[i]),
								int slashIndex => (boardList[i].substring(0, slashIndex), boardList[i].substring(slashIndex + 1))
							};
							return Padding(
								padding: const EdgeInsets.all(4),
								child: Container(
									decoration: BoxDecoration(
										borderRadius: const BorderRadius.all(Radius.circular(4)),
										color: theme.primaryColor.withOpacity(0.1)
									),
									padding: const EdgeInsets.only(left: 16),
									child: Row(
										children: [
											if (imageboardKey != null) Padding(
												padding: const EdgeInsets.only(right: 8),
												child: ImageboardIcon(
													imageboardKey: imageboardKey,
													boardName: boardName
												)
											),
											Expanded(
												child: Text(boardName, style: const TextStyle(fontSize: 15), textAlign: TextAlign.left)
											),
											CupertinoButton(
												child: const Icon(CupertinoIcons.delete),
												onPressed: () {
													boardList.removeAt(i);
													setDialogState(() {});
												}
											)
										]
									)
								)
							);
						}
					)
				),
				actions: [
					AdaptiveDialogAction(
						child: const Text('Add board'),
						onPressed: () async {
							final controller = TextEditingController();
							final newItem = await Navigator.of(context).push<ImageboardScoped<ImageboardBoard>>(TransparentRoute(
								builder: (ctx) => const BoardSwitcherPage(
									allowPickingWholeSites: false
								)
							));
							if (newItem != null) {
								boardList.add('${newItem.imageboard.key}/${newItem.item.boardKey}');
								setDialogState(() {});
							}
							controller.dispose();
						}
					),
					AdaptiveDialogAction(
						child: const Text('Close'),
						onPressed: () => Navigator.pop(context)
					)
				]
			)
		)
	);
	boards.clear();
	boards.addAll(boardList);
}

class _FilterEditorState extends State<FilterEditor> {
	late final TextEditingController regexController;
	late final FocusNode regexFocusNode;
	bool dirty = false;

	@override
	void initState() {
		super.initState();
		regexController = TextEditingController(text: Settings.instance.filterConfiguration);
		regexFocusNode = FocusNode();
	}

	@override
	void didUpdateWidget(FilterEditor oldWidget) {
		super.didUpdateWidget(oldWidget);
		if (!widget.showRegex && oldWidget.showRegex) {
			// Save regex changes upon switching back to wizard
			if (dirty) {
				WidgetsBinding.instance.addPostFrameCallback((_) {
					_save();
				});
			}
		}
	}

	void _save() {
		Settings.instance.filterConfiguration = regexController.text;
		regexFocusNode.unfocus();
		setState(() {
			dirty = false;
		});
	}

	@override
	Widget build(BuildContext context) {
		final settings = context.watch<Settings>();
		final filters = <int, CustomFilter>{};
		for (final line in settings.filterConfiguration.split(lineSeparatorPattern).asMap().entries) {
			if (line.value.isEmpty) {
				continue;
			}
			try {
				filters[line.key] = CustomFilter.fromStringConfiguration(line.value);
			}
			on FilterException {
				// don't show
			}
		}
		if (widget.forBoard != null) {
			filters.removeWhere((k, v) {
				return v.excludeBoards.contains(widget.forBoard!) || (v.boards.isNotEmpty && !v.boards.contains(widget.forBoard!));
			});
		}
		Future<(bool, CustomFilter?)?> editFilter(CustomFilter? originalFilter) {
			final filter = originalFilter ?? widget.blankFilter ?? CustomFilter(
				configuration: '',
				pattern: RegExp('', caseSensitive: false)
			);
			final patternController = TextEditingController(text: filter.pattern.pattern);
			final useListEditor = _splitByTopLevelPipe(filter.pattern.pattern).isNotEmpty;
			bool isCaseSensitive = filter.pattern.isCaseSensitive;
			bool isSingleLine = !filter.pattern.isMultiLine;
			final labelController = TextEditingController(text: filter.label);
			final patternFields = filter.patternFields.toList();
			bool? hasFile = filter.hasFile;
			bool? threadsOnly = filter.threadsOnly;
			bool? deletedOnly = filter.deletedOnly;
			bool? repliesToOP = filter.repliesToOP;
			final Set<String> boards = {
				...filter.boards,
				...filter.boardsBySite.entries.expand((e) => e.value.map((v) => '${e.key}/$v'))
			};
			final Set<String> excludeBoards = {
				...filter.excludeBoards,
				...filter.excludeBoardsBySite.entries.expand((e) => e.value.map((v) => '${e.key}/$v'))
			};
			final Set<String> sites = filter.sites.toSet();
			final Set<String> excludeSites = filter.excludeSites.toSet();
			int? minRepliedTo = filter.minRepliedTo;
			int? maxRepliedTo = filter.maxRepliedTo;
			int? minReplyCount = filter.minReplyCount;
			int? maxReplyCount = filter.maxReplyCount;
			bool hide = filter.outputType.hide;
			bool highlight = filter.outputType.highlight;
			bool pinToTop = filter.outputType.pinToTop;
			bool autoSave = filter.outputType.autoSave;
			AutoWatchType? autoWatch = filter.outputType.autoWatch;
			bool notify = filter.outputType.notify;
			bool collapse = filter.outputType.collapse;
			bool hideReplies = filter.outputType.hideReplies;
			bool hideReplyChains = filter.outputType.hideReplyChains;
			bool hideThumbnails = filter.outputType.hideThumbnails;
			const labelStyle = CommonTextStyles.bold;
			return showAdaptiveModalPopup<(bool, CustomFilter?)>(
				context: context,
				builder: (context) => StatefulBuilder(
					builder: (context, setInnerState) => AdaptiveActionSheet(
						title: const Text('Edit filter'),
						message: DefaultTextStyle(
							style: DefaultTextStyle.of(context).style,
							child: Column(
								mainAxisSize: MainAxisSize.min,
								crossAxisAlignment: CrossAxisAlignment.center,
								children: [
									const Text('Label', style: labelStyle),
									Padding(
										padding: const EdgeInsets.all(16),
										child: SizedBox(
											width: 300,
											child: AdaptiveTextField(
												controller: labelController,
												smartDashesType: SmartDashesType.disabled,
												smartQuotesType: SmartQuotesType.disabled
											)
										)
									),
									const Text('Pattern', style: labelStyle),
									Padding(
										padding: const EdgeInsets.all(16),
										child: SizedBox(
											width: 300,
											child: AdaptiveTextField(
												controller: patternController,
												autocorrect: false,
												enableIMEPersonalizedLearning: false,
												smartDashesType: SmartDashesType.disabled,
												smartQuotesType: SmartQuotesType.disabled,
												enableSuggestions: false
											)
										)
									),
									if (useListEditor) ...[
										AdaptiveFilledButton(
											padding: const EdgeInsets.all(16),
											onPressed: () async {
												final list = _splitByTopLevelPipe(patternController.text);
												await editStringList(
													context: context,
													list: list,
													name: 'pattern',
													title: 'Edit patterns',
													startEditsWithAllSelected: false
												);
												patternController.text = list.join('|');
												setInnerState(() {});
											},
											child: const Text('Edit pattern as list')
										),
										const SizedBox(height: 32),
									],
									AdaptiveListSection(
										children: [
											AdaptiveListTile(
												backgroundColor: ChanceTheme.barColorOf(context),
												backgroundColorActivated: ChanceTheme.primaryColorWithBrightness50Of(context),
												title: const Text('Case-sensitive'),
												trailing: isCaseSensitive ? const Icon(CupertinoIcons.check_mark) : const SizedBox.shrink(),
												onTap: () {
													isCaseSensitive = !isCaseSensitive;
													setInnerState(() {});
												}
											),
											AdaptiveListTile(
												backgroundColor: ChanceTheme.barColorOf(context),
												backgroundColorActivated: ChanceTheme.primaryColorWithBrightness50Of(context),
												title: const Text('Single-line'),
												trailing: isSingleLine ? const Icon(CupertinoIcons.check_mark) : const SizedBox.shrink(),
												onTap: () {
													isSingleLine = !isSingleLine;
													setInnerState(() {});
												}
											)
										]
									),
									const SizedBox(height: 16),
									const Text('Search in fields', style: labelStyle),
									const SizedBox(height: 16),
									AdaptiveListSection(
										children: [
											for (final field in allPatternFields) AdaptiveListTile(
												title: Text(const{
													'text': 'Text',
													'subject': 'Subject',
													'name': 'Name',
													'filename': 'Filename',
													'dimensions': 'File dimensions',
													'postID': 'Post ID',
													'posterID': 'Poster ID',
													'flag': 'Flag',
													'capcode': 'Capcode',
													'trip': 'Trip',
													'email': 'Email'
												}[field] ?? field),
												backgroundColor: ChanceTheme.barColorOf(context),
												backgroundColorActivated: ChanceTheme.primaryColorWithBrightness50Of(context),
												trailing: patternFields.contains(field) ? const Icon(CupertinoIcons.check_mark) : const SizedBox.shrink(),
												onTap:() {
													if (patternFields.contains(field)) {
														patternFields.remove(field);
													}
													else {
														patternFields.add(field);
													}
													setInnerState(() {});
												}
											)
										]
									),
									const SizedBox(height: 32),
									AdaptiveListSection(
										children: [
											for (final field in [null, false, true]) AdaptiveListTile(
												title: Text(const{
													null: 'All posts',
													false: 'Without images',
													true: 'With images'
												}[field]!),
												backgroundColor: ChanceTheme.barColorOf(context),
												backgroundColorActivated: ChanceTheme.primaryColorWithBrightness50Of(context),
												trailing: hasFile == field ? const Icon(CupertinoIcons.check_mark) : const SizedBox.shrink(),
												onTap:() {
													setInnerState(() {
														hasFile = field;
													});
												}
											)
										]
									),
									const SizedBox(height: 32),
									AdaptiveListSection(
										children: [
											for (final field in [null, true, false]) AdaptiveListTile(
												title: Text(const{
													null: 'All posts',
													true: 'Threads only',
													false: 'Replies only'
												}[field]!),
												backgroundColor: ChanceTheme.barColorOf(context),
												backgroundColorActivated: ChanceTheme.primaryColorWithBrightness50Of(context),
												trailing: threadsOnly == field ? const Icon(CupertinoIcons.check_mark) : const SizedBox.shrink(),
												onTap:() {
													setInnerState(() {
														threadsOnly = field;
													});
												}
											)
										]
									),
									const SizedBox(height: 32),
									AdaptiveListSection(
										children: [
											for (final field in [null, true, false]) AdaptiveListTile(
												title: Text(const{
													null: 'All posts',
													true: 'Deleted only',
													false: 'Non-deleted only'
												}[field]!),
												backgroundColor: ChanceTheme.barColorOf(context),
												backgroundColorActivated: ChanceTheme.primaryColorWithBrightness50Of(context),
												trailing: deletedOnly == field ? const Icon(CupertinoIcons.check_mark) : const SizedBox.shrink(),
												onTap:() {
													setInnerState(() {
														deletedOnly = field;
													});
												}
											)
										]
									),
									const SizedBox(height: 32),
									AdaptiveListSection(
										children: [
											for (final field in [null, true, false]) AdaptiveListTile(
												title: Text(const{
													null: 'All posts',
													true: 'Replying to OP only',
													false: 'Not replying to OP only'
												}[field]!),
												backgroundColor: ChanceTheme.barColorOf(context),
												backgroundColorActivated: ChanceTheme.primaryColorWithBrightness50Of(context),
												trailing: repliesToOP == field ? const Icon(CupertinoIcons.check_mark) : const SizedBox.shrink(),
												onTap:() {
													setInnerState(() {
														repliesToOP = field;
													});
												}
											)
										]
									),
									const SizedBox(height: 32),
									AdaptiveFilledButton(
										padding: const EdgeInsets.all(16),
										onPressed: () async {
											await editBoardSet(
												context: context,
												boards: boards,
												title: 'Edit boards'
											);
											setInnerState(() {});
										},
										child: Text(boards.isEmpty ? 'All boards' : 'Only on ${boards.map((b) => '/$b/').join(', ')}')
									),
									const SizedBox(height: 16),
									AdaptiveFilledButton(
										padding: const EdgeInsets.all(16),
										onPressed: () async {
											await editBoardSet(
												context: context,
												boards: excludeBoards,
												title: 'Edit excluded boards'
											);
											setInnerState(() {});
										},
										child: Text(excludeBoards.isEmpty ? 'No excluded boards' : 'Exclude ${excludeBoards.map((b) => '/$b/').join(', ')}')
									),
									const SizedBox(height: 32),
									AdaptiveFilledButton(
										padding: const EdgeInsets.all(16),
										onPressed: () async {
											await editSiteSet(
												context: context,
												siteKeys: sites,
												title: 'Edit sites'
											);
											setInnerState(() {});
										},
										child: Text(sites.isEmpty ? 'All sites' : 'Only on ${sites.join(', ')}')
									),
									const SizedBox(height: 16),
									AdaptiveFilledButton(
										padding: const EdgeInsets.all(16),
										onPressed: () async {
											await editSiteSet(
												context: context,
												siteKeys: excludeSites,
												title: 'Edit excluded sites'
											);
											setInnerState(() {});
										},
										child: Text(excludeSites.isEmpty ? 'No excluded sites' : 'Exclude ${excludeSites.join(', ')}')
									),
									const SizedBox(height: 16),
									AdaptiveFilledButton(
										padding: const EdgeInsets.all(16),
										onPressed: () async {
											final minController = TextEditingController(text: minRepliedTo?.toString());
											final maxController = TextEditingController(text: maxRepliedTo?.toString());
											await showAdaptiveDialog(
												context: context,
												barrierDismissible: true,
												builder: (context) => AdaptiveAlertDialog(
													title: const Text('Set replied-to posts count criteria'),
													actions: [
														AdaptiveDialogAction(
															child: const Text('Close'),
															onPressed: () => Navigator.pop(context)
														)
													],
													content: Column(
														mainAxisSize: MainAxisSize.min,
														children: [
															const SizedBox(height: 16),
															const Text('Minimum'),
															AdaptiveTextField(
																autofocus: true,
																keyboardType: TextInputType.number,
																controller: minController,
																onSubmitted: (s) {
																	Navigator.pop(context);
																}
															),
															const Text('Maximum'),
															AdaptiveTextField(
																autofocus: true,
																keyboardType: TextInputType.number,
																controller: maxController,
																onSubmitted: (s) {
																	Navigator.pop(context);
																}
															)
														]
													)
												)
											);
											minRepliedTo = int.tryParse(minController.text);
											maxRepliedTo = int.tryParse(maxController.text);
											minController.dispose();
											maxController.dispose();
											setInnerState(() {});
										},
										child: Text(switch ((minRepliedTo, maxRepliedTo)) {
											(null, null) => 'No replied-to criteria',
											(int min, null) => 'With at least $min replied-to posts',
											(null, int max) => 'With at most $max replied-to posts',
											(int min, int max) =>
												min == max
													? 'With exactly $min replied-to posts'
													: 'With between $min and $max replied-to posts'
										})
									),
									const SizedBox(height: 16),
									AdaptiveFilledButton(
										padding: const EdgeInsets.all(16),
										onPressed: () async {
											final controller = TextEditingController(text: minReplyCount?.toString());
											await showAdaptiveDialog(
												context: context,
												barrierDismissible: true,
												builder: (context) => AdaptiveAlertDialog(
													title: const Text('Set minimum reply count'),
													actions: [
														AdaptiveDialogAction(
															child: const Text('Clear'),
															onPressed: () {
																controller.text = '';
																Navigator.pop(context);
															}
														),
														AdaptiveDialogAction(
															child: const Text('Close'),
															onPressed: () => Navigator.pop(context)
														)
													],
													content: Padding(
														padding: const EdgeInsets.only(top: 16),
														child: AdaptiveTextField(
															autofocus: true,
															keyboardType: TextInputType.number,
															controller: controller,
															onSubmitted: (s) {
																Navigator.pop(context);
															}
														)
													)
												)
											);
											minReplyCount = int.tryParse(controller.text);
											controller.dispose();
											setInnerState(() {});
										},
										child: Text(minReplyCount == null ? 'No min-replies criteria' : 'With at least $minReplyCount replies')
									),
									const SizedBox(height: 16),
									AdaptiveFilledButton(
										padding: const EdgeInsets.all(16),
										onPressed: () async {
											final controller = TextEditingController(text: maxReplyCount?.toString());
											await showAdaptiveDialog(
												context: context,
												barrierDismissible: true,
												builder: (context) => AdaptiveAlertDialog(
													title: const Text('Set maximum reply count'),
													actions: [
														AdaptiveDialogAction(
															child: const Text('Clear'),
															onPressed: () {
																controller.text = '';
																Navigator.pop(context);
															}
														),
														AdaptiveDialogAction(
															child: const Text('Close'),
															onPressed: () => Navigator.pop(context)
														)
													],
													content: Padding(
														padding: const EdgeInsets.only(top: 16),
														child: AdaptiveTextField(
															autofocus: true,
															keyboardType: TextInputType.number,
															controller: controller,
															onSubmitted: (s) {
																Navigator.pop(context);
															}
														)
													)
												)
											);
											maxReplyCount = int.tryParse(controller.text);
											controller.dispose();
											setInnerState(() {});
										},
										child: Text(maxReplyCount == null ? 'No max-replies criteria' : 'With at most $maxReplyCount replies')
									),
									const SizedBox(height: 16),
									const Text('Action', style: labelStyle),
									Container(
										padding: const EdgeInsets.all(16),
										alignment: Alignment.center,
										child: AdaptiveListSection(
											children: [
												AdaptiveListTile(
													title: const Text('Hide'),
													trailing: hide ? const Icon(CupertinoIcons.check_mark) : const SizedBox.shrink(),
													backgroundColor: ChanceTheme.barColorOf(context),
													backgroundColorActivated: ChanceTheme.primaryColorWithBrightness50Of(context),
													onTap: () {
														if (!hide) {
															hide = true;
															highlight = false;
															pinToTop = false;
															autoSave = false;
															autoWatch = null;
															notify = false;
															collapse = false;
														}
														else {
															hide = false;
														}
														setInnerState(() {});
													}
												)
											]
										)
									),
									Container(
										padding: const EdgeInsets.all(16),
										alignment: Alignment.center,
										child: AdaptiveListSection(
											children: <(String, bool, ValueChanged<bool>)>[
												('Highlight', highlight, (v) => highlight = v),
												('Pin-to-top', pinToTop, (v) => pinToTop = v),
												('Auto-save', autoSave, (v) => autoSave = v),
												('Auto-watch', autoWatch != null, (v) => autoWatch = (v ? const AutoWatchType(push: null) : null)),
												('Notify', notify, (v) => notify = v),
												('Collapse (tree mode)', collapse, (v) => collapse = v),
												('Hide replies', hideReplies, (v) {
													hideReplies = v;
													if (v && hideReplyChains) {
														hideReplyChains = false;
													}
												}),
												('Hide reply chains', hideReplyChains, (v) {
													hideReplyChains = v;
													if (v && hideReplies) {
														hideReplies = false;
													}
												}),
												('Hide thumbnails', hideThumbnails, (v) => hideThumbnails = v)
											].map((t) => AdaptiveListTile(
												title: Text(t.$1),
												trailing: t.$2 ? const Icon(CupertinoIcons.check_mark) : const SizedBox.shrink(),
												backgroundColor: ChanceTheme.barColorOf(context),
												backgroundColorActivated: ChanceTheme.primaryColorWithBrightness50Of(context),
												onTap: () {
													t.$3(!t.$2);
													if (highlight || pinToTop || autoSave || autoWatch != null || notify || collapse) {
														hide = false;
													}
													setInnerState(() {});
												},
											)).toList()
										)
									),
									Opacity(
										opacity: autoWatch == null ? 0.5 : 1.0,
										child: IgnorePointer(
											ignoring: autoWatch == null,
											child: Column(
												mainAxisSize: MainAxisSize.min,
												children: [
													const Text('Auto-watch notifications'),
													Container(
														padding: const EdgeInsets.all(16),
														alignment: Alignment.center,
														child: AdaptiveChoiceControl<NullSafeOptional>(
															children: {
																NullSafeOptional.false_: (null, 'Push off'),
																NullSafeOptional.null_: (null, 'Default (push ${(Settings.instance.defaultThreadWatch?.push ?? true) ? 'on' : 'off'})'),
																NullSafeOptional.true_: (null, 'Push on')
															},
															knownWidth: 0,
															groupValue: (autoWatch?.push).value,
															onValueChanged: (v) {
																autoWatch = AutoWatchType(
																	push: v.value
																);
																setInnerState(() {});
															}
														)
													)
												]
											)
										)
									)
								]
							)
						),
						actions: [
							if (originalFilter != null) AdaptiveActionSheetAction(
								isDestructiveAction: true,
								onPressed: () => Navigator.pop(context, const (true, null)),
								child: const Text('Delete')
							),
							AdaptiveActionSheetAction(
								onPressed: () {
									final boards2 = <String>{};
									final boardsBySite = <String, Set<String>>{};
									for (final board in boards) {
										final slashIndex = board.indexOf('/');
										if (slashIndex != -1) {
											(boardsBySite[board.substring(0, slashIndex)] ??= {}).add(board.substring(slashIndex + 1));
										}
										else {
											boards2.add(board);
										}
									}
									final excludeBoards2 = <String>{};
									final excludeBoardsBySite = <String, Set<String>>{};
									for (final board in excludeBoards) {
										final slashIndex = board.indexOf('/');
										if (slashIndex != -1) {
											(excludeBoardsBySite[board.substring(0, slashIndex)] ??= {}).add(board.substring(slashIndex + 1));
										}
										else {
											excludeBoards2.add(board);
										}
									}
									Navigator.pop(context, (false, CustomFilter(
										pattern: RegExp(patternController.text, caseSensitive: isCaseSensitive, multiLine: !isSingleLine),
										patternFields: patternFields,
										boards: boards2,
										boardsBySite: boardsBySite,
										excludeBoards: excludeBoards2,
										excludeBoardsBySite: excludeBoardsBySite,
										sites: sites,
										excludeSites: excludeSites,
										hasFile: hasFile,
										threadsOnly: threadsOnly,
										deletedOnly: deletedOnly,
										repliesToOP: repliesToOP,
										minRepliedTo: minRepliedTo,
										maxRepliedTo: maxRepliedTo,
										minReplyCount: minReplyCount,
										maxReplyCount: maxReplyCount,
										outputType: FilterResultType(
											hide: hide,
											hideReplies: hideReplies,
											hideReplyChains: hideReplyChains,
											highlight: highlight,
											pinToTop: pinToTop,
											autoSave: autoSave,
											autoWatch: autoWatch,
											notify: notify,
											collapse: collapse,
											hideThumbnails: hideThumbnails
										),
										label: labelController.text
									)));
								},
								child: originalFilter == null ? const Text('Add') : const Text('Save')
							)
						],
						cancelButton: AdaptiveActionSheetAction(
							onPressed: () => Navigator.pop(context),
							child: const Text('Cancel')
						)
					)
				)
			);
		}
		Widget child;
		if (widget.showRegex) {
			child = Column(
				mainAxisSize: widget.fillHeight ? MainAxisSize.max : MainAxisSize.min,
				crossAxisAlignment: CrossAxisAlignment.stretch,
				children: [
					Wrap(
						crossAxisAlignment: WrapCrossAlignment.center,
						alignment: WrapAlignment.start,
						spacing: 16,
						runSpacing: 16,
						children: [
							AdaptiveIconButton(
								minSize: 0,
								icon: const Icon(CupertinoIcons.question_circle),
								onPressed: () {
									showAdaptiveModalPopup(
										context: context,
										builder: (context) => AdaptiveActionSheet(
											message: Text.rich(
												buildFakeMarkdown(context,
													'One regular expression per line, lines starting with # will be ignored\n'
													'Example: `/sneed/` will hide any thread or post containing "sneed"\n'
													'Example: `/bane/;boards:tv;thread` will hide any thread containing "sneed" in the OP on /tv/\n'
													'Add `i` after the regex to make it case-insensitive\n'
													'Example: `/sneed/i` will match `SNEED`\n'
													'Add `s` after the regex to make it single-line. ^ and \$ will match the start and end of text instead of each line\n'
													'You can write text before the opening slash to give the filter a label: `Funposting/bane/i`\n'
													'The first filter in the list to match an item will take precedence over other matching filters\n'
													'\n'
													'Qualifiers may be added after the regex:\n'
													'`;boards:<list>` Only apply on certain boards\n'
													'Example: `;board:tv,mu` will only apply the filter on /tv/ and /mu/\n'
													'Matching a board only on a specific site can be done too e.g. `;board:4chan/tv`\n'
													'`;exclude:<list>` Don\'t apply on certain boards\n'
													'`;site:<list>` Only apply on certain sites\n'
													'`;excludeSite:<list>` Don\'t apply on certain sites\n'
													'`;highlight` Highlight instead of hiding matches\n'
													'`;top` Pin match to top of list instead of hiding\n'
													'`;notify` Send a push notification (if enabled) for matches\n'
													'`;save` Automatically save matching threads\n'
													'`;watch` Automatically watch matching threads\n'
													'    Append `:push` to ensure push is enabled on the watches, or `:noPush` to ensure it\'s disabled\n'
													'`;collapse` Automatically collapse matching posts in tree mode\n'
													'`;hideReplies` Hide replies to matching posts too\n'
													'`;hideReplyChains` Hide replies and their replies (...) to matching posts too\n'
													'`;hideThumbnails` Hide image and video thumbnails\n'
													'`;show` Show matches (use it to override later filters)\n'
													'`;file:only` Only apply to posts with files\n'
													'`;file:no` Only apply to posts without files\n'
													'`;deleted:only` Only apply to deleted posts\n'
													'`;deleted:no` Only apply to non-deleted posts\n'
													'`;thread` Only apply to threads\n'
													'`;reply` Only apply to replies\n'
													'`;type:<list>` Only apply regex filter to certain fields\n'
													'`;minReplied:<number>` Only apply to posts replying to a minimum number of other posts\n'
													'`;maxReplied:<number>` Only apply to posts replying to a maximum number of other posts\n'
													'`;minReplyCount:<number>` Only apply to posts with a minimum number of replies\n'
													'`;maxReplyCount:<number>` Only apply to posts with a maximum number of replies\n'
													'The list of possible fields is $allPatternFields\n'
													'The default fields that are searched are $defaultPatternFields'
												),
												textAlign: TextAlign.left,
												style: const TextStyle(
													fontSize: 16,
													height: 1.5
												)
											),
											actions: [
												AdaptiveActionSheetAction(
													onPressed: () => Navigator.pop(context),
													child: const Text('Close')
												)
											]
										)
									);
								}
							),
							if (dirty) AdaptiveIconButton(
								minSize: 0,
								onPressed: _save,
								icon: const Text('Save')
							)
						]
					),
					const SizedBox(height: 16),
					Expanded(
						child: AdaptiveTextField(
							style: GoogleFonts.ibmPlexMono(),
							minLines: 5,
							maxLines: widget.fillHeight ? null : 5,
							focusNode: regexFocusNode,
							controller: regexController,
							enableSuggestions: false,
							enableIMEPersonalizedLearning: false,
							smartDashesType: SmartDashesType.disabled,
							smartQuotesType: SmartQuotesType.disabled,
							autocorrect: false,
							onChanged: (_) {
								if (!dirty) {
									setState(() {
										dirty = true;
									});
								}
							}
						)
					)
				]
			);
			if (widget.fillHeight) {
				child = Padding(
					padding: const EdgeInsets.all(16),
					child: child
				);
			}
		}
		else {
			child = AdaptiveListSection(
				children: [
					if (filters.length > 10) AdaptiveListTile(
						title: const Text('New filter'),
						leading: const Icon(CupertinoIcons.plus),
						backgroundColor: ChanceTheme.barColorOf(context),
						backgroundColorActivated: ChanceTheme.primaryColorWithBrightness50Of(context),
						onTap: () async {
							final newFilter = await editFilter(null);
							if (newFilter?.$2 != null) {
								final old = settings.filterConfiguration;
								// Add at the top
								settings.filterConfiguration = '${newFilter!.$2!.toStringConfiguration()}\n$old';
								regexController.text = settings.filterConfiguration;
							}
						}
					),
					...filters.entries.map((filter) {
						final icons = [
							if (filter.value.outputType == FilterResultType.empty) const Icon(CupertinoIcons.eye),
							if (filter.value.outputType.hide) const Icon(CupertinoIcons.eye_slash),
							if (filter.value.outputType.highlight) const Icon(CupertinoIcons.sun_max_fill),
							if (filter.value.outputType.pinToTop) const Icon(CupertinoIcons.arrow_up_to_line),
							if (filter.value.outputType.autoSave) Icon(Adaptive.icons.bookmarkFilled),
							if (filter.value.outputType.autoWatch != null) const Icon(CupertinoIcons.bell),
							if (filter.value.outputType.notify) const Icon(CupertinoIcons.bell_fill),
							if (filter.value.outputType.collapse) const Icon(CupertinoIcons.chevron_down_square),
							if (filter.value.outputType.hideReplies) const Icon(CupertinoIcons.reply_all),
							if (filter.value.outputType.hideReplyChains) ...[
								const Icon(CupertinoIcons.reply_all),
								const Icon(CupertinoIcons.repeat)
							],
							if (filter.value.outputType.hideThumbnails) ...[
								const Icon(CupertinoIcons.photo)
							]
						];
						return AdaptiveListTile(
							faded: filter.value.disabled,
							title: Text(filter.value.label.isNotEmpty ? filter.value.label : filter.value.pattern.pattern, maxLines: 1, overflow: TextOverflow.ellipsis),
							backgroundColor: ChanceTheme.barColorOf(context),
							backgroundColorActivated: ChanceTheme.primaryColorWithBrightness50Of(context),
							leading: FittedBox(fit: BoxFit.contain, child: Column(
								mainAxisAlignment: MainAxisAlignment.spaceBetween,
								children: [
									for (int i = 0; i < icons.length; i += 2) Row(
										mainAxisAlignment: MainAxisAlignment.spaceBetween,
										children: [
											if (i < icons.length) icons[i],
											if ((i + 1) < icons.length) icons[i + 1]
										]
									)
								]
							)),
							subtitle: Text.rich(
								TextSpan(
									children: [
										if (filter.value.minRepliedTo != null || filter.value.maxRepliedTo != null) TextSpan(text: 'Replying to ${switch ((filter.value.minRepliedTo, filter.value.maxRepliedTo)) {
											(int min, null) => '>=$min',
											(null, int max) => '<=$max',
											(int? min, int? max) => min == max ? '$min' : '$min-$max'
										}}'),
										if (filter.value.minReplyCount != null && filter.value.maxReplyCount != null) TextSpan(text: '${filter.value.minReplyCount}-${filter.value.maxReplyCount} replies')
										else if (filter.value.minReplyCount != null) TextSpan(text: '>=${filter.value.minReplyCount} replies')
										else if (filter.value.maxReplyCount != null) TextSpan(text: '<=${filter.value.maxReplyCount} replies'),
										if (filter.value.threadsOnly == true) const TextSpan(text: 'Threads only')
										else if (filter.value.threadsOnly == false) const TextSpan(text: 'Replies only'),
										if (filter.value.deletedOnly == true) const TextSpan(text: 'Deleted only')
										else if (filter.value.deletedOnly == false) const TextSpan(text: 'Non-deleted only'),
										if (filter.value.repliesToOP == true) const TextSpan(text: 'Replying-to-OP only')
										else if (filter.value.repliesToOP == false) const TextSpan(text: 'Non-replying-to-OP only'),
										if (filter.value.hasFile == true) const WidgetSpan(
											child: Icon(CupertinoIcons.doc)
										)
										else if (filter.value.hasFile == false) const WidgetSpan(
											child: Stack(
												children: [
													Icon(CupertinoIcons.doc),
													Icon(CupertinoIcons.xmark)
												]
											)
										),
										for (final board in filter.value.boards) TextSpan(text: '/$board/'),
										for (final entry in filter.value.boardsBySite.entries)
											for (final board in entry.value) TextSpan(text: '/${entry.key}/$board/'),
										for (final board in filter.value.excludeBoards) TextSpan(text: 'not /$board/'),
										for (final entry in filter.value.excludeBoardsBySite.entries)
											for (final board in entry.value) TextSpan(text: 'not /${entry.key}/$board/'),
										for (final siteKey in filter.value.sites) TextSpan(text: siteKey),
										for (final siteKey in filter.value.excludeSites) TextSpan(text: 'not $siteKey'),
										if (!setEquals(filter.value.patternFields.toSet(), defaultPatternFields.toSet()))
											for (final field in filter.value.patternFields) TextSpan(text: field)
									].expand((x) => [const TextSpan(text: ', '), x]).skip(1).toList()
								),
								overflow: TextOverflow.ellipsis
							),
							after: DecoratedBox(
								decoration: BoxDecoration(
									color: ChanceTheme.barColorOf(context)
								),
								child: Checkbox.adaptive(
									activeColor: ChanceTheme.primaryColorOf(context),
									checkColor: ChanceTheme.backgroundColorOf(context),
									value: !filter.value.disabled,
									onChanged: (value) {
										filter.value.disabled = !filter.value.disabled;
										final lines = settings.filterConfiguration.split(lineSeparatorPattern);
										lines[filter.key] = filter.value.toStringConfiguration();
										settings.filterConfiguration = lines.join('\n');
										regexController.text = settings.filterConfiguration;
									}
								)
							),
							onTap: () async {
								final newFilter = await editFilter(filter.value);
								if (newFilter != null) {
									final lines = settings.filterConfiguration.split(lineSeparatorPattern);
									if (newFilter.$1) {
										final removed = lines.removeAt(filter.key);
										if (context.mounted) {
											showUndoToast(
												context: context,
												message: 'Deleted filter',
												onUndo: () {
													lines.insert(filter.key, removed);
													settings.filterConfiguration = lines.join('\n');
													regexController.text = settings.filterConfiguration;
												}
											);
										}
									}
									else {
										lines[filter.key] = newFilter.$2!.toStringConfiguration();
									}
									settings.filterConfiguration = lines.join('\n');
									regexController.text = settings.filterConfiguration;
								}
							}
						);
					}),
					if (filters.isEmpty) AdaptiveListTile(
						title: const Text('Suggestion: Add a mass-reply filter'),
						leading: const Icon(CupertinoIcons.lightbulb),
						backgroundColor: ChanceTheme.barColorOf(context),
						backgroundColorActivated: ChanceTheme.primaryColorWithBrightness50Of(context),
						onTap: () async {
							settings.filterConfiguration += '\nMass-reply//;minReplied:10';
							regexController.text = settings.filterConfiguration;
						}
					),
					AdaptiveListTile(
						title: const Text('New filter'),
						leading: const Icon(CupertinoIcons.plus),
						backgroundColor: ChanceTheme.barColorOf(context),
						backgroundColorActivated: ChanceTheme.primaryColorWithBrightness50Of(context),
						onTap: () async {
							final newFilter = await editFilter(null);
							if (newFilter?.$2 != null) {
								settings.filterConfiguration += '\n${newFilter!.$2!.toStringConfiguration()}';
								regexController.text = settings.filterConfiguration;
							}
						}
					)
				]
			);
			if (widget.fillHeight) {
				child = MaybeScrollbar(
					child: SingleChildScrollView(
						padding: const EdgeInsets.all(16),
						child: child
					)
				);
			}
		}
		child = AnimatedSwitcher(
			duration: const Duration(milliseconds: 350),
			switchInCurve: Curves.ease,
			switchOutCurve: Curves.ease,
			layoutBuilder: (currentChild, previousChildren) => Stack(
				alignment: Alignment.topCenter,
				children: <Widget>[
					...previousChildren,
					if (currentChild != null) currentChild
				]
			),
			child: child
		);
		if (!widget.fillHeight) {
			child = AnimatedSize(
				duration: const Duration(milliseconds: 350),
				curve: Curves.ease,
				alignment: Alignment.topCenter,
				child: child
			);
		}
		return child;
	}

	@override
	void dispose() {
		final lastText = regexController.text;
		super.dispose();
		regexController.dispose();
		regexFocusNode.dispose();
		if (dirty) {
			Future.delayed(const Duration(milliseconds: 100), () => showAdaptiveDialog(
				context: ImageboardRegistry.instance.context!,
				builder: (context) => AdaptiveAlertDialog(
					title: const Text('Unsaved Regex'),
					content: const Text('You left without saving your changes. Do you want to keep them?'),
					actions: [
						AdaptiveDialogAction(
							isDefaultAction: true,
							onPressed: () {
								Settings.instance.filterConfiguration = lastText;
								Navigator.pop(context);
							},
							child: const Text('Save')
						),
						AdaptiveDialogAction(
							isDestructiveAction: true,
							onPressed: () => Navigator.pop(context),
							child: const Text('Discard')
						)
					]
				)
			));
		}
	}
}