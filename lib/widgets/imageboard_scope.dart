import 'package:chan/services/imageboard.dart';
import 'package:chan/services/persistence.dart';
import 'package:chan/services/report_bug.dart';
import 'package:chan/util.dart';
import 'package:chan/widgets/util.dart';
import 'package:flutter/material.dart';
import 'package:provider/provider.dart';

class ImageboardScope extends StatelessWidget {
	final Widget child;
	final String? imageboardKey;
	final Imageboard? imageboard;
	final Persistence? overridePersistence;
	final Offset loaderOffset;

	const ImageboardScope({
		required this.child,
		required this.imageboardKey,
		this.imageboard,
		this.overridePersistence,
		this.loaderOffset = Offset.zero,
		Key? key
	}) : super(key: key);

	@override
	Widget build(BuildContext context) {
		final b = imageboard ?? ImageboardRegistry.instance.getImageboardUnsafe(imageboardKey ?? 'null');
		if (b == null) {
			return Center(
				child: ErrorMessageCard(
					'No such imageboard: $imageboardKey',
					remedies: {
						if (Navigator.of(context).canPop()) 'Close': Navigator.of(context).pop
					}
				)
			);
		}
		return AnimatedBuilder(
			animation: b,
			builder: (context, child) {
				if (b.boardsLoading && b.persistence.boards.isEmpty) {
					return Center(
						child: Transform(
							transform: Matrix4.translationValues(loaderOffset.dx, loaderOffset.dy, 0),
							child: const CircularProgressIndicator.adaptive()
						)
					);
				}
				else if (b.setupError != null) {
					return Center(
						child: ErrorMessageCard(
							'Error with imageboard $imageboardKey:\n${b.setupError!.$1.toStringDio()}',
							remedies: generateBugRemedies(b.setupError!.$1, b.setupError!.$2, context)
						)
					);
				}
				else if (b.boardFetchError != null) {
					return Center(
						child: ErrorMessageCard('Error fetching boards for imageboard $imageboardKey:\n${b.boardFetchError!.$1.toStringDio()}', remedies: {
							'Retry': b.setupBoards,
							...generateBugRemedies(b.boardFetchError!.$1, b.boardFetchError!.$2, context)
						})
					);
				}
				return child!;
			},
			child: MultiProvider(
				providers: [
					ChangeNotifierProvider.value(value: b),
					if (b.initialized) ...[
						Provider.value(value: b.site),
						ChangeNotifierProvider.value(value: overridePersistence ?? b.persistence),
						ChangeNotifierProvider.value(value: b.threadWatcher),
						Provider.value(value: b.notifications)
					]
				],
				child: child
			)
		);
	}
}