import 'dart:async';
import 'dart:io';

import 'package:file_picker/file_picker.dart';
import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:url_launcher/url_launcher.dart';

import 'api.dart';
import 'appearance_dialog.dart';
import 'desktop_pairing.dart';
import 'device_peer.dart';
import 'history_files.dart';
import 'local_engine.dart';
import 'player_host.dart';

Future<void> showLocalSettings(BuildContext context, PlayerHost host) =>
    showDialog<void>(
      context: context,
      builder: (_) => _LocalSettings(host: host),
    );

class _LocalSettings extends StatefulWidget {
  const _LocalSettings({required this.host});
  final PlayerHost host;

  @override
  State<_LocalSettings> createState() => _LocalSettingsState();
}

class _LocalSettingsState extends State<_LocalSettings>
    with WidgetsBindingObserver {
  bool busy = false, tidalPending = false;
  String? status, tidalRedirect;
  static const firefoxReady =
      kDebugMode || bool.fromEnvironment('RADIO_FIREFOX_READY');
  PlayerHost get host => widget.host;
  RadioApi get api => host.radio.api!;

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addObserver(this);
    unawaited(_takeRedirect());
  }

  @override
  void dispose() {
    WidgetsBinding.instance.removeObserver(this);
    super.dispose();
  }

  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    if (state == AppLifecycleState.resumed) unawaited(_takeRedirect());
  }

  Future<void> _takeRedirect() async {
    if (!Platform.isAndroid) return;
    final redirect = await LocalEngine.channel.invokeMethod<String>(
      'takeTidalRedirect',
    );
    if (redirect != null && mounted) {
      setState(() {
        tidalRedirect = redirect;
        tidalPending = true;
      });
    }
  }

  Future<void> run(Future<void> Function() operation) async {
    if (busy) return;
    setState(() {
      busy = true;
      status = null;
    });
    try {
      await operation();
    } catch (failure) {
      if (mounted) {
        setState(
          () => status = failure is ApiFailure
              ? failure.message
              : failure is FormatException
              ? failure.message
              : 'Setup could not complete. Check the connection and try again.',
        );
      }
    } finally {
      if (mounted) setState(() => busy = false);
    }
  }

  Future<void> _youtube(String? text) async {
    if (text == null || text.trim().isEmpty) {
      throw ApiFailure(
        0,
        'Copy YouTube Music request headers or a browser-auth JSON file first.',
      );
    }
    await host.radio.pause();
    await api.call('/api/local/accounts/youtube', body: {'text': text});
    await host.radio.refreshLocalAccounts();
    if (mounted) setState(() => status = 'YouTube Music connected.');
  }

  Future<void> _pasteYoutube() async =>
      _youtube((await Clipboard.getData(Clipboard.kTextPlain))?.text);

  Future<void> _openYoutubeFile() async {
    final file = await FilePicker.pickFile(
      type: FileType.custom,
      allowedExtensions: ['json'],
    );
    if (file == null) return;
    if (file.path == null || await File(file.path!).length() > 200000) {
      throw ApiFailure(0, 'Choose a supported browser-auth JSON file.');
    }
    await _youtube(await File(file.path!).readAsString());
  }

  Future<void> _firefox() async {
    final result = await api.call('/api/local/accounts/browser', body: {});
    final url = Uri.parse('${api.origin}${result['path']}');
    final opened = Platform.isAndroid
        ? (await LocalEngine.channel.invokeMethod<bool>(
                'openFirefox',
                url.toString(),
              ) ??
              false)
        : await launchUrl(url, mode: LaunchMode.externalApplication);
    if (!opened) {
      throw ApiFailure(
        0,
        'Install Firefox and the Personal Radio add-on first.',
      );
    }
    if (mounted) {
      setState(
        () =>
            status = 'Finish in Firefox, then return here and check accounts.',
      );
    }
  }

  Future<void> _startTidal() async {
    final result = await api.call('/api/local/accounts/tidal/start', body: {});
    if (!await launchUrl(
      Uri.parse(result['login_url']),
      mode: LaunchMode.externalApplication,
    )) {
      throw ApiFailure(0, 'Could not open Tidal sign-in.');
    }
    if (mounted) {
      setState(() {
        tidalPending = true;
        tidalRedirect = null;
        status = 'After signing in, share the final page to Personal Radio or copy its URL.';
      });
    }
  }

  Future<void> _finishTidal() async {
    final text =
        tidalRedirect ?? (await Clipboard.getData(Clipboard.kTextPlain))?.text;
    if (text == null || text.isEmpty) {
      throw ApiFailure(0, 'Copy the final Tidal redirect first.');
    }
    await host.radio.pause();
    await api.call('/api/local/accounts/tidal/finish', body: {'text': text});
    await host.radio.refreshLocalAccounts();
    if (mounted) {
      setState(() {
        tidalRedirect = null;
        tidalPending = false;
        status = 'Tidal connected.';
      });
    }
  }

  Future<void> _disconnect(String provider) async {
    await host.radio.pause();
    await api.call('/api/local/accounts/$provider', method: 'DELETE');
    await host.radio.refreshLocalAccounts();
  }

  Future<void> _pair(PairPurpose purpose) async {
    if (Platform.isWindows) {
      final paired = await showDesktopPairing(context, host.peer, purpose);
      if (mounted && paired) {
        setState(
          () => status = purpose == PairPurpose.youtube
              ? 'Session sent. Finish connecting on your phone.'
              : 'History paired. Open Personal Radio on both devices to sync.',
        );
      }
    } else {
      final code = await receiveDesktopCode(context, purpose);
      if (code == null || !mounted) return;
      setState(() => status = 'Waiting for approval on Windows...');
      if (purpose == PairPurpose.youtube) await host.radio.pause();
      await host.peer.accept(code, purpose);
      if (purpose == PairPurpose.youtube) {
        await host.radio.refreshLocalAccounts();
      }
      if (mounted) {
        setState(
          () => status = purpose == PairPurpose.youtube
              ? 'YouTube Music connected.'
              : 'History paired with Windows.',
        );
      }
    }
  }

  Future<String?> _passphrase({required bool creating}) => showDialog<String>(
    context: context,
    builder: (_) => _HistoryPassphrase(creating: creating),
  );

  Future<void> _exportHistory() async {
    final password = await _passphrase(creating: true);
    if (password == null || !mounted) return;
    final archive = await collectHistory(api);
    final bytes = await encryptHistory(archive, password);
    final saved = await FilePicker.saveFile(
      fileName: 'personal-radio-history.prh',
      bytes: bytes,
    );
    if (saved != null && mounted) {
      setState(() => status = 'Encrypted history saved.');
    }
  }

  Future<void> _importHistory() async {
    final picked = await FilePicker.pickFile();
    if (picked?.path == null || !mounted) return;
    final file = File(picked!.path!);
    if (await file.length() > historyFileLimit) {
      throw const FormatException('This history file exceeds 64 MiB.');
    }
    if (!mounted) return;
    final password = await _passphrase(creating: false);
    if (password == null || !mounted) return;
    final archive = await decryptHistory(await file.readAsBytes(), password);
    final result = await api.call(historyPath, body: archive);
    if (mounted) {
      setState(
        () => status = "Imported ${result['inserted']} listening events.",
      );
    }
  }

  @override
  Widget build(BuildContext context) => ListenableBuilder(
    listenable: Listenable.merge([host.radio, host.peer]),
    builder: (context, _) {
      final radio = host.radio;
      final available = radio.ready && !busy;
      return AlertDialog(
        title: const Text('On this device'),
        scrollable: true,
        content: SizedBox(
          width: 450,
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.stretch,
            mainAxisSize: MainAxisSize.min,
            children: [
              ListTile(
                title: const Text('Appearance'),
                subtitle: Text(radio.appearance.palette.label),
                leading: const Icon(Icons.palette_outlined),
                onTap: () => showAppearanceDialog(context, radio),
              ),
              if (!radio.ready)
                TextButton(
                  onPressed: busy ? null : () => run(host.recover),
                  child: const Text('Retry local engine'),
                ),
              const Divider(),
              Text(
                'YouTube Music',
                style: Theme.of(context).textTheme.titleLarge,
              ),
              Text(
                radio.localAccounts?['youtube']?['label'] as String? ??
                    'Connect your account',
              ),
              if (radio.accountLinked('youtube') &&
                  radio.localAccounts?['youtube']?['reporting'] == false)
                const Text(
                  'Listening reports are paused until the channel can be verified.',
                ),
              Wrap(
                spacing: 6,
                children: [
                  TextButton(
                    onPressed: available && firefoxReady
                        ? () => run(_firefox)
                        : null,
                    child: const Text('Connect with Firefox'),
                  ),
                  TextButton(
                    onPressed: available ? () => run(_pasteYoutube) : null,
                    child: const Text('Paste request headers'),
                  ),
                  TextButton(
                    onPressed: available ? () => run(_openYoutubeFile) : null,
                    child: const Text('Import browser-auth JSON'),
                  ),
                  TextButton(
                    onPressed:
                        available &&
                            (!Platform.isWindows ||
                                radio.accountLinked('youtube'))
                        ? () => run(() => _pair(PairPurpose.youtube))
                        : null,
                    child: Text(
                      Platform.isWindows
                          ? 'Pair Android for YouTube'
                          : 'Connect from Windows',
                    ),
                  ),
                  if (radio.accountLinked('youtube'))
                    TextButton(
                      onPressed: available
                          ? () => run(() => _disconnect('youtube'))
                          : null,
                      child: const Text('Disconnect YouTube'),
                    ),
                ],
              ),
              if (!firefoxReady)
                const Text('The Firefox add-on is pending browser review.'),
              const Divider(),
              Text('Tidal', style: Theme.of(context).textTheme.titleLarge),
              Text(
                radio.accountLinked('tidal')
                    ? 'Connected'
                    : 'Connect your subscription',
              ),
              Wrap(
                spacing: 6,
                children: [
                  TextButton(
                    onPressed: available ? () => run(_startTidal) : null,
                    child: const Text('Open Tidal sign-in'),
                  ),
                  if (tidalPending)
                    TextButton(
                      onPressed: available ? () => run(_finishTidal) : null,
                      child: Text(
                        tidalRedirect != null
                            ? 'Finish Tidal sign-in'
                            : 'Paste Tidal redirect',
                      ),
                    ),
                  if (radio.accountLinked('tidal'))
                    TextButton(
                      onPressed: available
                          ? () => run(() => _disconnect('tidal'))
                          : null,
                      child: const Text('Disconnect Tidal'),
                    ),
                ],
              ),
              const Divider(),
              Text(
                'Listening history',
                style: Theme.of(context).textTheme.titleLarge,
              ),
              Text(
                host.peer.paired
                    ? (Platform.isWindows
                          ? (host.peer.serving
                                ? 'Available to your paired phone while the app is open.'
                                : 'The saved Wi-Fi address is unavailable. Unpair and pair again.')
                          : 'Paired with Windows. Sync runs while the app is open.')
                    : 'Share history over private Wi-Fi or save a passphrase-protected file.',
              ),
              Wrap(
                spacing: 6,
                children: [
                  if (host.peer.paired) ...[
                    if (Platform.isAndroid)
                      TextButton(
                        onPressed: available && !host.peer.syncing
                            ? () => run(() async {
                                await host.peer.sync();
                                if (mounted) {
                                  setState(
                                    () => status = 'Listening history synced.',
                                  );
                                }
                              })
                            : null,
                        child: const Text('Sync history now'),
                      ),
                    TextButton(
                      onPressed: available ? () => run(host.peer.unpair) : null,
                      child: const Text('Unpair history'),
                    ),
                  ] else
                    TextButton(
                      onPressed: available
                          ? () => run(() => _pair(PairPurpose.history))
                          : null,
                      child: const Text('Pair Wi-Fi history'),
                    ),
                  TextButton(
                    onPressed: available ? () => run(_exportHistory) : null,
                    child: const Text('Export encrypted history'),
                  ),
                  TextButton(
                    onPressed: available ? () => run(_importHistory) : null,
                    child: const Text('Import encrypted history'),
                  ),
                ],
              ),
              if (status != null)
                Padding(padding: const EdgeInsets.all(8), child: Text(status!)),
              if (busy) const LinearProgressIndicator(),
              const Divider(),
              TextButton.icon(
                onPressed: busy
                    ? null
                    : () {
                        Navigator.pop(context);
                        unawaited(host.switchMode(false));
                      },
                icon: const Icon(Icons.dns_outlined),
                label: const Text('Connect to a server'),
              ),
            ],
          ),
        ),
        actions: [
          TextButton(
            onPressed: available
                ? () => run(host.radio.refreshLocalAccounts)
                : null,
            child: const Text('Check accounts'),
          ),
          FilledButton(
            onPressed: busy ? null : () => Navigator.pop(context),
            child: const Text('Done'),
          ),
        ],
      );
    },
  );
}

class _HistoryPassphrase extends StatefulWidget {
  const _HistoryPassphrase({required this.creating});
  final bool creating;

  @override
  State<_HistoryPassphrase> createState() => _HistoryPassphraseState();
}

class _HistoryPassphraseState extends State<_HistoryPassphrase> {
  final password = TextEditingController();
  final repeat = TextEditingController();

  @override
  void dispose() {
    password.dispose();
    repeat.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final ready = widget.creating
        ? password.text.length >= 12 && password.text == repeat.text
        : password.text.isNotEmpty;
    return AlertDialog(
      title: Text(
        widget.creating ? 'Protect history export' : 'Unlock history',
      ),
      content: Column(
        mainAxisSize: MainAxisSize.min,
        children: [
          if (widget.creating)
            const Text(
              'Choose a passphrase of at least 12 characters. You will need it to import this file.',
            ),
          TextField(
            controller: password,
            obscureText: true,
            autofocus: true,
            enableSuggestions: false,
            autocorrect: false,
            onChanged: (_) => setState(() {}),
            decoration: const InputDecoration(labelText: 'Passphrase'),
          ),
          if (widget.creating)
            TextField(
              controller: repeat,
              obscureText: true,
              enableSuggestions: false,
              autocorrect: false,
              onChanged: (_) => setState(() {}),
              decoration: const InputDecoration(labelText: 'Repeat passphrase'),
            ),
        ],
      ),
      actions: [
        TextButton(
          onPressed: () => Navigator.pop(context),
          child: const Text('Cancel'),
        ),
        FilledButton(
          onPressed: ready ? () => Navigator.pop(context, password.text) : null,
          child: Text(widget.creating ? 'Continue' : 'Unlock'),
        ),
      ],
    );
  }
}
