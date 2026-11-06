import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

import 'shell/window_title_bar.dart';
import 'theme/app_theme.dart';
import 'theme/tokens.dart';
import 'widgets/quelyt_mark.dart';

/// Same theme and language as the app so a startup failure never looks like a
/// blank developer screen. The message explains the next step, not a stack.
class BootstrapErrorApp extends StatelessWidget {
  const BootstrapErrorApp({
    super.key,
    required this.error,
    this.showWindowChrome = false,
  });

  final Object error;
  final bool showWindowChrome;

  @override
  Widget build(BuildContext context) => MaterialApp(
    debugShowCheckedModeBanner: false,
    theme: lightTheme,
    darkTheme: darkTheme,
    themeMode: ThemeMode.system,
    builder: (context, child) => WindowFrame(
      enabled: showWindowChrome,
      showTitleBar: true,
      child: child ?? const SizedBox.shrink(),
    ),
    home: Builder(
      builder: (context) {
        final c = context.colors;
        return Scaffold(
          body: SafeArea(
            child: Center(
              child: SingleChildScrollView(
                padding: const EdgeInsets.all(Space.xl),
                child: ConstrainedBox(
                  constraints: const BoxConstraints(maxWidth: 560),
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Row(
                        children: [
                          const QuelytMark(size: 36, monochrome: true),
                          const SizedBox(width: 10),
                          Text(
                            'Quelyt',
                            style: context.texts.headlineMedium!.copyWith(
                              fontFamily: 'Manrope',
                              color: c.ink,
                              fontSize: 26,
                              fontWeight: FontWeight.w600,
                              letterSpacing: .2,
                            ),
                          ),
                        ],
                      ),
                      const SizedBox(height: Space.xl),
                      Text(
                        '书库未能打开',
                        style: context.texts.headlineMedium,
                      ),
                      const SizedBox(height: Space.md),
                      Text(
                        '数据目录不可写，或文件被占用。外部原件不受影响。',
                        style: context.texts.bodyLarge!.copyWith(
                          color: c.inkMuted,
                          height: 1.75,
                        ),
                      ),
                      const SizedBox(height: Space.lg),
                      Container(
                        width: double.infinity,
                        padding: const EdgeInsets.all(Space.md),
                        decoration: BoxDecoration(
                          color: c.dangerTint,
                          borderRadius: BorderRadius.circular(Radii.md),
                          border: Border.all(color: c.outline),
                        ),
                        child: SelectableText(
                          '$error',
                          style: context.texts.bodySmall!.copyWith(
                            color: c.ink,
                            fontFeatures: AppNumerals.tabular,
                          ),
                        ),
                      ),
                      const SizedBox(height: Space.lg),
                      Wrap(
                        spacing: Space.sm,
                        runSpacing: Space.sm,
                        children: [
                          FilledButton.icon(
                            onPressed: () => SystemNavigator.pop(),
                            icon: const Icon(Icons.close_rounded, size: 17),
                            label: const Text('退出应用'),
                          ),
                          OutlinedButton.icon(
                            onPressed: () async {
                              await Clipboard.setData(
                                ClipboardData(text: '书库未能打开：$error'),
                              );
                              if (context.mounted) {
                                ScaffoldMessenger.of(context).showSnackBar(
                                  const SnackBar(
                                    content: Text('错误信息已复制。'),
                                  ),
                                );
                              }
                            },
                            icon: const Icon(Icons.copy_rounded, size: 16),
                            label: const Text('复制错误信息'),
                          ),
                        ],
                      ),
                    ],
                  ),
                ),
              ),
            ),
          ),
        );
      },
    ),
  );
}
