import 'package:chan/util.dart';
import 'package:flutter/foundation.dart';
import 'package:flutter/widgets.dart' hide WeakMap;
import 'package:provider/provider.dart';
import 'package:weak_map/weak_map.dart';

const allPatternFields = ['text', 'subject', 'name', 'filename', 'dimensions', 'postID', 'posterID', 'flag', 'capcode', 'trip', 'email'];
const defaultPatternFields = ['subject', 'name', 'filename', 'text'];
final newGeneralPattern = RegExp(r'(?<=^| )\/([^/ ]+)\/(?=$| )');

class AutoWatchType {
	final bool? push;

	const AutoWatchType({
		required this.push
	});

	bool get hasProperties => push != null;

	@override
	String toString() => 'AutoWatchType(push: $push)';
}

class FilterResultType {
	final bool hide;
	final bool highlight;
	final bool pinToTop;
	final bool autoSave;
	final AutoWatchType? autoWatch;
	final bool notify;
	final bool collapse;
	final bool hideReplies;
	final bool hideReplyChains;
	final bool hideThumbnails;

	const FilterResultType({
		this.hide = false,
		this.highlight = false,
		this.pinToTop = false,
		this.autoSave = false,
		this.autoWatch,
		this.notify = false,
		this.collapse = false,
		this.hideReplies = false,
		this.hideReplyChains = false,
		this.hideThumbnails = false
	});

	static const FilterResultType empty = FilterResultType();

	@override
	String toString() => 'FilterResultType(${[
		if (hide) 'hide',
		if (highlight) 'highlight',
		if (pinToTop) 'pinToTop',
		if (autoSave) 'autoSave',
		if (autoWatch != null) autoWatch.toString(),
		if (notify) 'notify',
		if (collapse) 'collapse',
		if (hideReplies) 'hideReplies',
		if (hideReplyChains) 'hideReplyChains',
		if (hideThumbnails) 'hideThumbnails'
	].join(', ')})';

	@override
	bool operator == (Object other) =>
		identical(this, other) ||
		other is FilterResultType &&
		other.hide == hide &&
		other.highlight == highlight &&
		other.pinToTop == pinToTop &&
		other.autoSave == autoSave &&
		other.autoWatch == autoWatch &&
		other.notify == notify &&
		other.collapse == collapse &&
		other.hideReplies == hideReplies &&
		other.hideReplyChains == hideReplyChains &&
		other.hideThumbnails == hideThumbnails;

	@override
	int get hashCode => Object.hash(hide, highlight, pinToTop, autoSave, autoWatch, notify, collapse, hideReplies, hideReplyChains, hideThumbnails);
}

class FilterResult {
	FilterResultType type;
	String reason;
	FilterResult(this.type, this.reason);

	@override
	String toString() => 'FilterResult(type: $type, reason: $reason)';
}

abstract class Filterable {
	String? getFilterFieldText(String fieldName);
	String get board;
	int get id;
	int get threadId;
	Iterable<int> get repliedToIds;
	bool get hasFile;
	bool get isThread;
	Iterable<String> get md5s;
	int get replyCount;
	bool get isDeleted;
	bool get isSticky;
	DateTime get time;
}

class EmptyFilterable implements Filterable {
	@override
	final int id;
	const EmptyFilterable(this.id);
	@override
	String? getFilterFieldText(String fieldName) => null;

  @override
  String get board => '';

  @override
  bool get hasFile => false;

  @override
  bool get isThread => false;

	@override
	int get threadId => 0;

	@override
	List<int> get repliedToIds => [];

	@override
	int get replyCount => 0;

	@override
	Iterable<String> get md5s => [];

	@override
	bool get isDeleted => false;

	@override
	bool get isSticky => false;

	@override
	DateTime get time => DateTime(2000);
}

abstract class Filter {
	FilterResult? filter(String imageboardKey, Filterable item);

	static Filter of(BuildContext context, {bool listen = true}) {
		return (listen ? context.watch<Filter?>() : context.read<Filter?>()) ?? const DummyFilter();
	}

	bool get supportsMetaFilter;
}

class FilterCache<T extends Filter> implements Filter {
	T wrappedFilter;
	FilterCache(this.wrappedFilter);
	// Need to use two seperate maps as we can't store null in [_cache]
	final Map<String, WeakMap<Filterable, bool?>> _contains = {};
	final Map<String, WeakMap<Filterable, FilterResult?>> _cache = {};

	@override
	FilterResult? filter(String imageboardKey, Filterable item) {
		final contains = _contains[imageboardKey] ??= WeakMap();
		final cache = _cache[imageboardKey] ??= WeakMap();
		if (contains.get(item) != true) {
			contains.add(key: item, value: true);
			final result = wrappedFilter.filter(imageboardKey, item);
			if (result != null) {
				cache.add(key: item, value: result);
			}
			return result;
		}
		return cache.get(item);
	}

	@override
	bool get supportsMetaFilter => wrappedFilter.supportsMetaFilter;

	@override
	String toString() => 'FilterCache($wrappedFilter)';

	@override
	bool operator ==(Object other) =>
		identical(this, other) ||
		other is FilterCache &&
		other.wrappedFilter == wrappedFilter;

	@override
	int get hashCode => wrappedFilter.hashCode;
}

class CustomFilter implements Filter {
	late final String configuration;
	final String label;
	final RegExp pattern;
	List<String> patternFields;
	FilterResultType outputType;
	Set<String> boards;
	Map<String, Set<String>> boardsBySite;
	Set<String> excludeBoards;
	Map<String, Set<String>> excludeBoardsBySite;
	Set<String> sites;
	Set<String> excludeSites;
	bool? hasFile;
	bool? threadsOnly;
	int? minRepliedTo;
	int? maxRepliedTo;
	bool disabled;
	int? minReplyCount;
	int? maxReplyCount;
	bool? deletedOnly;
	bool? repliesToOP;
	CustomFilter({
		String? configuration,
		this.disabled = false,
		this.label = '',
		required this.pattern,
		this.patternFields = defaultPatternFields,
		this.outputType = const FilterResultType(hide: true),
		this.boards = const {},
		this.boardsBySite = const {},
		this.excludeBoards = const {},
		this.excludeBoardsBySite = const {},
		this.sites = const {},
		this.excludeSites = const {},
		this.hasFile,
		this.threadsOnly,
		this.minRepliedTo,
		this.maxRepliedTo,
		this.minReplyCount,
		this.maxReplyCount,
		this.deletedOnly,
		this.repliesToOP
	}) {
		this.configuration = configuration ?? toStringConfiguration();
	}
	@override
	FilterResult? filter(String imageboardKey, Filterable item) {
		if (disabled) {
			return null;
		}
		if (sites.isNotEmpty && !sites.contains(imageboardKey)) {
			return null;
		}
		if (excludeSites.contains(imageboardKey)) {
			return null;
		}
		if ((boards.isNotEmpty || boardsBySite.isNotEmpty)
		     && !boards.contains(item.board)
				 && !(boardsBySite[imageboardKey]?.contains(item.board) ?? false)) {
			return null;
		}
		if (excludeBoards.contains(item.board)) {
			return null;
		}
		if (excludeBoardsBySite[imageboardKey]?.contains(item.board) ?? false) {
			return null;
		}
		if (hasFile != null && hasFile != item.hasFile) {
			return null;
		}
		if (threadsOnly == !item.isThread) {
			return null;
		}
		if (minRepliedTo != null && item.repliedToIds.length < minRepliedTo!) {
			return null;
		}
		if (maxRepliedTo != null && item.repliedToIds.length > maxRepliedTo!) {
			return null;
		}
		if (minReplyCount != null && item.replyCount < minReplyCount!) {
			return null;
		}
		if (maxReplyCount != null && item.replyCount > maxReplyCount!) {
			return null;
		}
		if (deletedOnly != null && item.isDeleted != deletedOnly) {
			return null;
		}
		if (repliesToOP != null && item.repliedToIds.contains(item.threadId) != repliesToOP) {
			return null;
		}
		if (pattern.pattern.isNotEmpty) {
			if (!patternFields.any((field) => pattern.hasMatch(item.getFilterFieldText(field) ?? ''))) {
				return null;
			}
		}
		return FilterResult(outputType, label.isEmpty ? 'Matched "$configuration"' : '$label filter');
	}

	static final _separatorPattern = RegExp(r':|,');

	factory CustomFilter.fromStringConfiguration(String configuration) {
		final match = _configurationLinePattern.firstMatch(configuration);
		if (match == null) {
			throw FilterException('Invalid syntax: "$configuration"');
		}
		try {
			final flags = match.group(3) ?? '';
			final filter = CustomFilter(
				configuration: configuration,
				disabled: configuration.startsWith('#'),
				label: match.group(1)!.replaceAll('%2F', '/'),
				// Initialize these things so they aren't const
				boards: {},
				boardsBySite: {},
				excludeBoards: {},
				excludeBoardsBySite: {},
				sites: {},
				excludeSites: {},
				pattern: RegExp(match.group(2)!, multiLine: !flags.contains('s'), caseSensitive: !flags.contains('i'))
			);
			int i = 5;
			bool hide = true;
			bool highlight = false;
			bool pinToTop = false;
			bool autoSave = false;
			AutoWatchType? autoWatch;
			bool notify = false;
			bool collapse = false;
			bool hideReplies = false;
			bool hideReplyChains = false;
			bool hideThumbnails = false;
			while (true) {
				final s = match.group(i);
				if (s == null) {
					break;
				}
				else if (s == 'highlight') {
					highlight = true;
					hide = false;
				}
				else if (s == 'top') {
					pinToTop = true;
					hide = false;
				}
				else if (s == 'save') {
					autoSave = true;
					hide = false;
				}
				else if (s == 'watch' || s.startsWith('watch:')) {
					bool? push;
					for (final part in s.split(_separatorPattern).skip(1)) {
						if (part == 'push') {
							push = true;
						}
						else if (part == 'noPush') {
							push = false;
						}
						else {
							throw FilterException('Unknown watch qualifier: $part');
						}
					}
					autoWatch = AutoWatchType(
						push: push
					);
					hide = false;
				}
				else if (s == 'notify') {
					notify = true;
					hide = false;
				}
				else if (s == 'collapse') {
					collapse = true;
					hide = false;
				}
				else if (s == 'show') {
					hide = false;
				}
				else if (s == 'hideReplies') {
					hideReplies = true;
				}
				else if (s == 'hideReplyChains') {
					hideReplyChains = true;
				}
				else if (s == 'hideThumbnails') {
					hideThumbnails = true;
					hide = false;
				}
				else if (s.startsWith('type:')) {
					filter.patternFields = s.split(_separatorPattern).skip(1).toList();
					if (filter.patternFields.remove('thread')) {
						// 4chan-X filters use ;type:thread instead of ;thread
						// Move it from patternFields
						filter.threadsOnly = true;
					}
				}
				else if (s.startsWith('boards:') || s.startsWith('board:')) {
					for (final board in s.split(_separatorPattern).skip(1)) {
						final slashIndex = board.indexOf('/');
						if (slashIndex != -1) {
							(filter.boardsBySite[board.substring(0, slashIndex)] ??= {}).add(board.substring(slashIndex + 1));
						}
						else {
							filter.boards.add(board);
						}
					}
				}
				else if (s.startsWith('exclude:')) {
					for (final board in s.split(_separatorPattern).skip(1)) {
						final slashIndex = board.indexOf('/');
						if (slashIndex != -1) {
							(filter.excludeBoardsBySite[board.substring(0, slashIndex)] ??= {}).add(board.substring(slashIndex + 1));
						}
						else {
							filter.excludeBoards.add(board);
						}
					}
				}
				else if (s.startsWith('site:') || s.startsWith('sites:')) {
					filter.sites.addAll(s.split(_separatorPattern).skip(1));
				}
				else if (s.startsWith('excludeSite:') || s.startsWith('excludeSites:')) {
					filter.excludeSites.addAll(s.split(_separatorPattern).skip(1));
				}
				else if (s == 'file:only') {
					filter.hasFile = true;
				}
				else if (s == 'file:no') {
					filter.hasFile = false;
				}
				else if (s == 'thread' || s == 'op:only') {
					filter.threadsOnly = true;
				}
				else if (s == 'reply' || s == 'op:no') {
					filter.threadsOnly = false;
				}
				else if (s == 'deleted:only') {
					filter.deletedOnly = true;
				}
				else if (s == 'deleted:no') {
					filter.deletedOnly = false;
				}
				else if (s.startsWith('minReplied')) {
					filter.minRepliedTo = int.tryParse(s.split(':')[1]);
					if (filter.minRepliedTo == null) {
						throw FilterException('Not a valid number for minReplied: "${s.split(':')[1]}"');
					}
				}
				else if (s.startsWith('maxReplied')) {
					filter.maxRepliedTo = int.tryParse(s.split(':')[1]);
					if (filter.maxRepliedTo == null) {
						throw FilterException('Not a valid number for maxReplied: "${s.split(':')[1]}"');
					}
				}
				else if (s.startsWith('minReplyCount')) {
					filter.minReplyCount = int.tryParse(s.split(':')[1]);
					if (filter.minReplyCount == null) {
						throw FilterException('Not a valid number for minReplyCount: "${s.split(':')[1]}"');
					}
				}
				else if (s.startsWith('maxReplyCount')) {
					filter.maxReplyCount = int.tryParse(s.split(':')[1]);
					if (filter.maxReplyCount == null) {
						throw FilterException('Not a valid number for maxReplyCount: "${s.split(':')[1]}"');
					}
				}
				else if (s == 'repliesToOP:only') {
					filter.repliesToOP = true;
				}
				else if (s == 'repliesToOP:no') {
					filter.repliesToOP = false;
				}
				else {
					throw FilterException('Unknown qualifier "$s"');
				}
				i += 2;
			}
			filter.outputType = FilterResultType(
				hide: hide,
				highlight: highlight,
				pinToTop: pinToTop,
				autoSave: autoSave,
				autoWatch: autoWatch,
				notify: notify,
				collapse: collapse,
				hideReplies: hideReplies,
				hideReplyChains: hideReplyChains,
				hideThumbnails: hideThumbnails
			);
			return filter;
		}
		catch (e) {
			if (e is FilterException) {
				rethrow;
			}
			throw FilterException(e.toString());
		}
	}

	String toStringConfiguration() {
		final out = StringBuffer();
		if (disabled) {
			out.write('#');
		}
		out.write(label.replaceAll('/', '%2F'));
		out.write('/');
		out.write(pattern.pattern);
		out.write('/');
		if (!pattern.isCaseSensitive) {
			out.write('i');
		}
		if (!pattern.isMultiLine) {
			out.write('s');
		}
		if (outputType.highlight) {
			out.write(';highlight');
		}
		if (outputType.pinToTop) {
			out.write(';top');
		}
		if (outputType.autoSave) {
			out.write(';save');
		}
		if (outputType.autoWatch != null) {
			out.write(';watch');
			if (outputType.autoWatch?.hasProperties ?? false) {
				out.write(':');
				if (outputType.autoWatch?.push == true) {
					out.write('push');
				}
				else if (outputType.autoWatch?.push == false) {
					out.write('noPush');
				}
			}
		}
		if (outputType.notify) {
			out.write(';notify');
		}
		if (outputType.collapse) {
			out.write(';collapse');
		}
		if (outputType.hideReplies) {
			out.write(';hideReplies');
		}
		if (outputType.hideReplyChains) {
			out.write(';hideReplyChains');
		}
		if (outputType.hideThumbnails) {
			out.write(';hideThumbnails');
		}
		if (outputType == FilterResultType.empty ||
		    outputType == const FilterResultType(hideReplies: true) ||
				outputType == const FilterResultType(hideReplyChains: true)) {
			// Kind of a dummy filter, just used to override others
			// Also lets you hideReplies without hiding primary post
			out.write(';show');
		}
		if (patternFields.isNotEmpty && !setEquals(patternFields.toSet(), defaultPatternFields.toSet())) {
			out.write(';type:${patternFields.join(',')}');
		}
		if (boards.isNotEmpty || boardsBySite.isNotEmpty) {
			out.write(';boards:${[
				...boards,
				...boardsBySite.entries.expand((e) => e.value.map((v) => '${e.key}/$v'))
			].join(',')}');
		}
		if (excludeBoards.isNotEmpty || excludeBoardsBySite.isNotEmpty) {
			out.write(';exclude:${[
				...excludeBoards,
				...excludeBoardsBySite.entries.expand((e) => e.value.map((v) => '${e.key}/$v'))
			].join(',')}');
		}
		if (sites.isNotEmpty) {
			out.write(';sites:${sites.join(',')}');
		}
		if (excludeSites.isNotEmpty) {
			out.write(';excludeSites:${excludeSites.join(',')}');
		}
		if (hasFile == true) {
			out.write(';file:only');
		}
		else if (hasFile == false) {
			out.write(';file:no');
		}
		if (threadsOnly == true) {
			out.write(';thread');
		}
		else if (threadsOnly == false) {
			out.write(';reply');
		}
		if (minRepliedTo != null) {
			out.write(';minReplied:$minRepliedTo');
		}
		if (maxRepliedTo != null) {
			out.write(';maxReplied:$maxRepliedTo');
		}
		if (minReplyCount != null) {
			out.write(';minReplyCount:$minReplyCount');
		}
		if (maxReplyCount != null) {
			out.write(';maxReplyCount:$maxReplyCount');
		}
		if (deletedOnly == true) {
			out.write(';deleted:only');
		}
		else if (deletedOnly == false) {
			out.write(';deleted:no');
		}
		if (repliesToOP == true) {
			out.write(';repliesToOP:only');
		}
		else if (repliesToOP == false) {
			out.write(';repliesToOP:no');
		}
		return out.toString();
	}

	@override
	bool get supportsMetaFilter => outputType.hideReplies || outputType.hideReplyChains;

	@override
	String toString() => 'CustomFilter(configuration: $configuration, pattern: $pattern, patternFields: $patternFields, outputType: $outputType, boards: $boards, excludeBoards: $excludeBoards, hasFile: $hasFile, threadsOnly: $threadsOnly, minRepliedTo: $minRepliedTo, maxRepliedTo: $maxRepliedTo, minReplyCount: $minReplyCount, maxReplyCount: $maxReplyCount, repliesToOP: $repliesToOP)';

	@override
	bool operator == (Object other) =>
		identical(this, other) ||
		other is CustomFilter &&
		other.configuration == configuration;

	@override
	int get hashCode => configuration.hashCode;
}

class IDFilter implements Filter {
	final List<int> hideIds;
	final List<int> showIds;
	IDFilter({
		required this.hideIds,
		required this.showIds
  });
	@override
	FilterResult? filter(String imageboardKey, Filterable item) {
		if (hideIds.contains(item.id)) {
			return FilterResult(const FilterResultType(hide: true), 'Manually hidden');
		}
		else if (showIds.contains(item.id)) {
			return FilterResult(FilterResultType.empty, 'Manually shown');
		}
		else {
			return null;
		}
	}

	@override
	bool get supportsMetaFilter => false;

	@override
	String toString() => 'IDFilter(hideIds: $hideIds, showIds: $showIds)';

	@override
	bool operator == (Object other) =>
		identical(this, other) ||
		other is IDFilter &&
		listEquals(other.hideIds, hideIds) &&
		listEquals(other.showIds, showIds);

	@override
	int get hashCode => Object.hash(Object.hashAll(hideIds), Object.hashAll(showIds));
}

class ThreadFilter implements Filter {
	final List<int> hideIds;
	final List<int> showIds;
	final List<int> repliedToIds;
	final List<String> posterIds;
	ThreadFilter({
		required this.hideIds,
		required this.showIds,
		required this.repliedToIds,
		required this.posterIds
	});
	@override
	FilterResult? filter(String imageboardKey, Filterable item) {
		if (hideIds.contains(item.id)) {
			return FilterResult(const FilterResultType(hide: true), 'Manually hidden');
		}
		else if (showIds.contains(item.id)) {
			return FilterResult(FilterResultType.empty, 'Manually shown');
		}
		else if (repliedToIds.any(item.repliedToIds.contains)) {
			return FilterResult(const FilterResultType(hide: true), 'Replied to manually hidden');
		}
		else if (posterIds.contains(item.getFilterFieldText('posterID'))) {
			return FilterResult(const FilterResultType(hide: true), 'Posted by "${item.getFilterFieldText('posterID')}"');
		}
		else {
			return null;
		}
	}

	@override
	bool get supportsMetaFilter => false;

	@override
	String toString() => 'ThreadFilter(hideIds: $hideIds, showIds: $showIds, repliedToIds: $repliedToIds, posterIds: $posterIds)';

	@override
	bool operator == (Object other) =>
		identical(this, other) ||
		other is ThreadFilter &&
		listEquals(other.hideIds, hideIds) &&
		listEquals(other.showIds, showIds) &&
		listEquals(other.repliedToIds, repliedToIds) &&
		listEquals(other.posterIds, posterIds);

	@override
	int get hashCode => Object.hash(Object.hashAll(hideIds), Object.hashAll(showIds), Object.hashAll(repliedToIds), Object.hashAll(posterIds));
}

class MD5Filter implements Filter {
	final Set<String> md5s;
	final bool applyToThreads;
	final int depth; 
	MD5Filter(this.md5s, this.applyToThreads, this.depth);
	@override
	FilterResult? filter(String imageboardKey, Filterable item) {
		if (!applyToThreads && item.isThread) {
			return null;
		}
		return item.md5s.any(md5s.contains) ?
			FilterResult(
				FilterResultType(
					hide: true,
					hideReplies: depth > 0,
					hideReplyChains: depth > 1
				),
				'Matches filtered image')
			: null;
	}

	@override
	bool get supportsMetaFilter => depth > 0;

	@override
	String toString() => 'MD5Filter(md5s: $md5s, applyToThreads: $applyToThreads, depth: $depth)';

	@override
	bool operator == (Object other) =>
		identical(this, other) ||
		other is MD5Filter &&
		setEquals(other.md5s, md5s) &&
		other.applyToThreads == applyToThreads &&
		other.depth == depth;

	@override
	int get hashCode => Object.hash(Object.hashAllUnordered(md5s), applyToThreads, depth);
}

class FilterGroup<T extends Filter> implements Filter {
	final List<T> filters;
	FilterGroup(this.filters);
	@override
	FilterResult? filter(String imageboardKey, Filterable item) {
		for (final filter in filters) {
			final result = filter.filter(imageboardKey, item);
			if (result != null) {
				return result;
			}
		}
		return null;
	}

	@override
	bool get supportsMetaFilter => filters.any((f) => f.supportsMetaFilter);

	@override
	String toString() => 'FilterGroup(filters: $filters)';

	@override
	bool operator == (Object other) =>
		identical(this, other) ||
		other is FilterGroup &&
		listEquals(other.filters, filters);

	@override
	int get hashCode => Object.hashAll(filters);
}

class DummyFilter implements Filter {
	const DummyFilter();
	@override
	FilterResult? filter(String imageboardKey, Filterable item) => null;

	@override
	bool get supportsMetaFilter => false;

	@override
	bool operator == (Object other) =>
		identical(this, other) ||
		other is DummyFilter;

	@override
	int get hashCode => 0;

	@override
	String toString() => 'DummyFilter()';
}

class FilterException implements Exception {
	String message;
	FilterException(this.message);

	@override
	String toString() => 'Filter Error: $message';
}

final _configurationLinePattern = RegExp(r'^#?([^\/]*)\/(.*)\/([is]*)(;([^;]+))?(;([^;]+))?(;([^;]+))?(;([^;]+))?(;([^;]+))?(;([^;]+))?(;([^;]+))?(;([^;]+))?(;([^;]+))?(;([^;]+))?$');

FilterGroup<CustomFilter> makeFilter(String configuration) {
	final filters = <CustomFilter>[];
	for (final (i, line) in configuration.split(lineSeparatorPattern).indexed) {
		if (line.isEmpty) {
			continue;
		}
		try {
			filters.add(CustomFilter.fromStringConfiguration(line));
		}
		catch (e) {
			// It might be a filter, or it could just be a comment
			if (!line.startsWith('#')) {
				throw Exception('Problem with filter on line ${i + 1} "$line"\n${e.toString()}');
			}
		}
	}
	return FilterGroup(filters);
}

class FilterZone extends StatefulWidget {
	final Filter filter;
	final Widget child;

	const FilterZone({
		required this.filter,
		required this.child,
		Key? key
	}) : super(key: key);

	@override
	createState() => _FilterZoneState();
}

class _FilterZoneState extends State<FilterZone> {
	Filter _filter = const DummyFilter();
	Filter _lastFilterFromContext = const DummyFilter();
	FilterCache _cachedFilter = FilterCache(const DummyFilter());
	FilterCache _makeCachedFilter() => switch (widget.filter) {
		FilterCache cachedAlready => cachedAlready,
		Filter raw => FilterCache(raw)
	};
	
	@override
	void initState() {
		super.initState();
		_cachedFilter = _makeCachedFilter();
		_filter = _cachedFilter; // This should be overwritten in didChangeDependencies
	}

	@override
	void didChangeDependencies() {
		super.didChangeDependencies();
		final filterFromContext = Filter.of(context);
		if (filterFromContext != _lastFilterFromContext) {
			_lastFilterFromContext = filterFromContext;
			// Maintain _cachedFilter
			_filter = FilterCache(FilterGroup([_cachedFilter, _lastFilterFromContext]));
		}
	}

	@override
	void didUpdateWidget(FilterZone oldWidget) {
		super.didUpdateWidget(oldWidget);
		if (widget.filter != oldWidget.filter) {
			_cachedFilter = _makeCachedFilter();
			// Maintain _lastFilterFromContext
			_filter = FilterCache(FilterGroup([_cachedFilter, _lastFilterFromContext]));
		}
	}

	@override
	Widget build(BuildContext context) {
		return Provider<Filter>.value(
			value: _filter,
			child: widget.child
		);
	}
}

class MetaFilter implements Filter {
	final toxicRepliedToIds = <int, String>{};
	final treeToxicRepliedToIds = <int, String>{};

	MetaFilter({
		required Filter parent,
		required String imageboardKey,
		required List<int> initialTreeToxicRepliedToIds,
		required List<Filterable>? list
	}) {
		if (list == null || (!parent.supportsMetaFilter && initialTreeToxicRepliedToIds.isEmpty)) {
			// Nothing to do
			return;
		}
		for (final initial in initialTreeToxicRepliedToIds) {
			treeToxicRepliedToIds[initial] = 'manually hidden';
		}
		// Not all sites ensure strictly chronological sorting
		// This is important so that only one pass is needed to tree-hide
		final sorted = list.toList();
		sorted.sort((a, b) => a.id.compareTo(b.id));

		for (final item in sorted) {
			final result = parent.filter(imageboardKey, item);
			if (result != null && result.type.hideReplyChains) {
				treeToxicRepliedToIds[item.id] = result.reason;
			}
			else if (result != null && result.type.hideReplies) {
				toxicRepliedToIds[item.id] = result.reason;
			}
			if (item.repliedToIds.any(treeToxicRepliedToIds.containsKey)) {
				final match = item.repliedToIds.tryMapOnce((id) => treeToxicRepliedToIds[id]);
				if (match != null) {
					treeToxicRepliedToIds[item.id] = match;
				}
			}
		}
	}

	@override
	FilterResult? filter(String imageboardKey, Filterable item) {
		if (toxicRepliedToIds.isEmpty && treeToxicRepliedToIds.isEmpty) {
			return null;
		}
		for (final id in item.repliedToIds) {
			final match = toxicRepliedToIds[id];
			if (match != null) {
				return FilterResult(const FilterResultType(hide: true), 'Replied to $id ($match)');
			}
			final treeMatch = treeToxicRepliedToIds[id];
			if (treeMatch != null) {
				return FilterResult(const FilterResultType(hide: true), 'In reply chain of $id ($treeMatch)');
			}
		}
		return null;
	}

	@override
	bool get supportsMetaFilter => false;

	@override
	bool operator == (Object other) =>
		identical(this, other);
	
	@override
	int get hashCode => identityHashCode(this);
}

class OldStickiedThreadsFilter implements Filter {
	final Set<String> excludeBoards;
	final DateTime threshold;

	OldStickiedThreadsFilter({
		required this.excludeBoards,
		required this.threshold
	});

	@override
	FilterResult? filter(String imageboardKey, Filterable item) {
		if (!item.isThread) {
			return null;
		}
		if (!item.isSticky) {
			return null;
		}
		if (item.time.isAfter(threshold)) {
			return null;
		}
		if (excludeBoards.contains(item.board)) {
			return null;
		}
		return FilterResult(const FilterResultType(hide: true), 'Old sticky');
	}

	@override
	bool get supportsMetaFilter => false;

	@override
	bool operator == (Object other) =>
		identical(this, other)
		|| other is OldStickiedThreadsFilter
		&& setEquals(other.excludeBoards, excludeBoards)
		&& other.threshold == threshold;
	
	@override
	int get hashCode => Object.hash(excludeBoards, threshold);

	@override
	String toString() => 'OldStickiedThreadsFilter(excludeBoards: $excludeBoards, threshold: $threshold)';
}
