import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:instantgram/core/theme.dart';
import 'package:instantgram/models/app_user.dart';
import 'package:instantgram/models/call.dart';
import 'package:instantgram/models/chat.dart';
import 'package:instantgram/screens/call/call_screen.dart';
import 'package:instantgram/screens/call/incoming_call_screen.dart';
import 'package:instantgram/services/call_engine.dart';
import 'package:instantgram/services/call_service.dart';
import 'package:instantgram/widgets/message_bubble.dart';
import 'package:instantgram/widgets/recipient_sheet.dart';
import 'package:instantgram/widgets/reel_touch.dart';

class _FakeEngine extends CallEngine {
  String? channel;
  bool? video;
  bool left = false;
  bool? muted;
  bool? speaker;
  bool? camera;
  int flips = 0;

  @override
  Future<void> join({required String channel, required bool video}) async {
    this.channel = channel;
    this.video = video;
    joined.value = true;
  }

  @override
  Future<void> setMuted(bool m) async => muted = m;
  @override
  Future<void> setSpeaker(bool on) async => speaker = on;
  @override
  Future<void> setCameraOn(bool on) async => camera = on;
  @override
  Future<void> switchCamera() async => flips++;
  @override
  Widget remoteView() => const SizedBox(key: ValueKey('fakeRemote'));
  @override
  Widget localView() => const SizedBox(key: ValueKey('fakeLocal'));
  @override
  Future<void> leave() async => left = true;
}

class _FakeBackend implements CallBackend {
  final Map<String, StreamController<CallInfo?>> _c = {};
  final Map<String, String> status = {};
  CallInfo? placed;

  StreamController<CallInfo?> _ctl(String id) =>
      _c.putIfAbsent(id, StreamController<CallInfo?>.broadcast);

  void emit(CallInfo c) => _ctl(c.id).add(c);

  @override
  Future<CallInfo> place(String callerId, String calleeUid, bool video) async {
    placed = CallInfo(
      id: 'call1',
      callerId: callerId,
      calleeId: calleeUid,
      video: video,
      status: CallStatus.ringing,
    );
    status['call1'] = CallStatus.ringing;
    return placed!;
  }

  @override
  Stream<CallInfo?> watch(String id) => _ctl(id).stream;

  @override
  Future<void> setStatus(String id, String s) async => status[id] = s;

  @override
  Stream<List<CallInfo>> watchRinging(String myUid) => const Stream.empty();
}

class _Log {
  _Log(this.peer, this.video, this.status, this.seconds);
  final String peer;
  final bool video;
  final String status;
  final int seconds;
}

String get _me => 'me';

ChatMessage _callMsg({
  bool video = false,
  String status = 'ended',
  int seconds = 0,
}) => ChatMessage(
  id: 'm1',
  senderId: _me,
  text: '',
  createdAt: DateTime(2026, 10, 5, 10),
  type: MsgType.call,
  callVideo: video,
  callStatus: status,
  duration: seconds,
);

void main() {
  late _FakeEngine engine;
  late _FakeBackend backend;
  late List<_Log> logs;
  late bool permissionOk;

  setUp(() {
    engine = _FakeEngine();
    backend = _FakeBackend();
    logs = [];
    permissionOk = true;
    CallService.instance.backend = backend;
    CallService.instance.myUid = () => 'me';
    CallService.instance.busy = false;
    CallDeps.engine = () => engine;
    CallDeps.tones = false;
    CallDeps.keepAwake = false;
    CallDeps.configured = () => true;
    CallDeps.permissions = (_) async => permissionOk;
    CallDeps.writeLog = (peer, video, status, secs) async {
      logs.add(_Log(peer, video, status, secs));
    };
  });

  group('call model', () {
    test('labels', () {
      expect(callLabel(video: false, status: 'ended'), 'Voice call');
      expect(callLabel(video: true, status: 'ended'), 'Video call');
      expect(callLabel(video: true, status: 'missed'), 'Missed video call');
      expect(callLabel(video: false, status: 'missed'), 'Missed voice call');
      expect(
        callLabel(video: false, status: 'declined'),
        'Voice call declined',
      );
    });

    test('call time', () {
      expect(formatCallTime(0), '0:00');
      expect(formatCallTime(75), '1:15');
      expect(formatCallTime(3700), '1:01:40');
      expect(formatCallTime(-4), '0:00');
    });

    test('status helpers and freshness', () {
      expect(CallStatus.isOver('ringing'), isFalse);
      expect(CallStatus.isOver('accepted'), isFalse);
      expect(CallStatus.isOver('declined'), isTrue);
      expect(CallStatus.isOver('missed'), isTrue);
      final now = DateTime(2026, 10, 5, 10);
      CallInfo at(DateTime? t) => CallInfo(
        id: 'c',
        callerId: 'a',
        calleeId: 'b',
        video: false,
        status: 'ringing',
        createdAt: t,
      );
      expect(
        at(now.subtract(const Duration(seconds: 20))).isFresh(now),
        isTrue,
      );
      expect(
        at(now.subtract(const Duration(minutes: 5))).isFresh(now),
        isFalse,
      );
      expect(at(null).isFresh(now), isTrue);
      expect(at(null).other('a'), 'b');
      expect(at(null).channel, 'c');
    });

    test('chat preview of a call', () {
      expect(MsgType.all, contains(MsgType.call));
      expect(
        messagePreview(MsgType.call, '', callVideo: true, callStatus: 'missed'),
        contains('Missed video call'),
      );
      expect(_callMsg(status: 'ended').preview, contains('Voice call'));
    });
  });

  group('call line in the chat', () {
    Widget host(Widget w) => MaterialApp(
      theme: AppTheme.dark,
      home: Scaffold(body: Center(child: w)),
    );

    testWidgets('shows the label and the length', (tester) async {
      await tester.pumpWidget(
        host(
          MessageBubble(
            mine: true,
            time: '10:00',
            message: _callMsg(video: true, seconds: 151),
          ),
        ),
      );
      expect(find.byKey(const ValueKey('callMessage')), findsOneWidget);
      expect(find.text('Video call'), findsOneWidget);
      expect(find.text('2:31'), findsOneWidget);
    });

    testWidgets('a missed call says tap to call back and taps through', (
      tester,
    ) async {
      var opened = 0;
      await tester.pumpWidget(
        host(
          MessageBubble(
            mine: false,
            time: '10:00',
            message: _callMsg(status: 'missed'),
            onOpen: () => opened++,
          ),
        ),
      );
      expect(find.text('Missed voice call'), findsOneWidget);
      expect(find.text('Tap to call back'), findsOneWidget);
      await tester.tap(find.byKey(const ValueKey('callMessage')));
      expect(opened, 1);
    });
  });

  group('one share screen', () {
    testWidgets('people and Share link sit together', (tester) async {
      var linkTaps = 0;
      const users = [
        AppUser(uid: 'u1', username: 'asha'),
        AppUser(uid: 'u2', username: 'ravi'),
      ];
      await tester.pumpWidget(
        MaterialApp(
          theme: AppTheme.dark,
          home: Scaffold(
            body: RecipientSheet(
              title: 'Send this clip',
              actionLabel: 'Send',
              withNote: true,
              loadSuggestions: () async => users,
              search: (q) async => const [],
              onShareLink: () => linkTaps++,
            ),
          ),
        ),
      );
      await tester.pumpAndSettle();
      expect(find.byKey(const ValueKey('shareLink')), findsOneWidget);
      expect(find.text('asha'), findsOneWidget);
      expect(find.byKey(const ValueKey('recipientSend')), findsOneWidget);
      await tester.tap(find.byKey(const ValueKey('shareLink')));
      await tester.pump();
      expect(linkTaps, 1);
      // the people list is still there
      expect(find.text('ravi'), findsOneWidget);
    });

    testWidgets('no Share link row when it is not asked for', (tester) async {
      await tester.pumpWidget(
        MaterialApp(
          theme: AppTheme.dark,
          home: Scaffold(
            body: RecipientSheet(
              title: 'Send',
              actionLabel: 'Send',
              withNote: false,
              loadSuggestions: () async => const [],
              search: (q) async => const [],
            ),
          ),
        ),
      );
      await tester.pumpAndSettle();
      expect(find.byKey(const ValueKey('shareLink')), findsNothing);
    });
  });

  group('clip volume percentage', () {
    testWidgets('shows near the top of the screen with the percentage', (
      tester,
    ) async {
      ReelAudio.muted.value = false;
      ReelAudio.volume.value = 0.5;
      await tester.pumpWidget(
        MaterialApp(
          home: SizedBox(
            width: 400,
            height: 800,
            child: ReelTouch(
              onTap: () {},
              child: const ColoredBox(color: Colors.black),
            ),
          ),
        ),
      );
      final g = await tester.startGesture(const Offset(200, 450));
      await tester.pump(const Duration(milliseconds: 600));
      await g.moveBy(const Offset(0, -80));
      await tester.pump(const Duration(milliseconds: 50));
      await g.moveBy(const Offset(0, -60));
      await tester.pump(const Duration(milliseconds: 50));
      final bar = find.byKey(const ValueKey('volumeBar'));
      expect(bar, findsOneWidget);
      expect(tester.getTopLeft(bar).dy, lessThan(160));
      final shown = (ReelAudio.volume.value * 100).round();
      expect(find.text('$shown%'), findsOneWidget);
      await g.up();
      await tester.pump(const Duration(seconds: 2));
    });
  });

  group('calls', () {
    Future<void> open(
      WidgetTester tester,
      Widget Function(BuildContext) screen,
    ) async {
      await tester.pumpWidget(
        MaterialApp(
          theme: AppTheme.dark,
          home: Builder(
            builder: (c) => Scaffold(
              body: Center(
                child: ElevatedButton(
                  onPressed: () => Navigator.of(
                    c,
                  ).push<void>(MaterialPageRoute<void>(builder: screen)),
                  child: const Text('open'),
                ),
              ),
            ),
          ),
        ),
      );
      await tester.tap(find.text('open'));
      await tester.pumpAndSettle();
    }

    testWidgets('voice call: ring, connect, timer, hang up writes the line', (
      tester,
    ) async {
      await open(
        tester,
        (_) => const CallScreen(peerUid: 'u2', peerName: 'ravi', video: false),
      );
      await tester.pump();
      expect(backend.placed?.calleeId, 'u2');
      expect(backend.placed?.video, isFalse);
      expect(engine.channel, 'call1');
      expect(find.text('Ringing...'), findsOneWidget);
      expect(find.byKey(const ValueKey('callCamera')), findsNothing);

      engine.remoteJoined.value = true;
      await tester.pump();
      await tester.pump(const Duration(seconds: 3));
      expect(find.text('0:03'), findsOneWidget);

      await tester.tap(find.byKey(const ValueKey('callMute')));
      await tester.pump();
      expect(engine.muted, isTrue);
      await tester.tap(find.byKey(const ValueKey('callSpeaker')));
      await tester.pump();
      expect(engine.speaker, isTrue);

      await tester.tap(find.byKey(const ValueKey('callEnd')));
      await tester.pumpAndSettle();
      expect(backend.status['call1'], CallStatus.ended);
      expect(engine.left, isTrue);
      expect(logs, hasLength(1));
      expect(logs.first.status, CallStatus.ended);
      expect(logs.first.seconds, 3);
      expect(logs.first.video, isFalse);
      expect(find.byType(CallScreen), findsNothing);
      expect(CallService.instance.busy, isFalse);
    });

    testWidgets('video call shows the picture buttons', (tester) async {
      await open(
        tester,
        (_) => const CallScreen(peerUid: 'u2', peerName: 'ravi', video: true),
      );
      await tester.pump();
      expect(engine.video, isTrue);
      expect(find.byKey(const ValueKey('localVideo')), findsOneWidget);
      engine.remoteJoined.value = true;
      engine.remoteVideoOn.value = true;
      await tester.pump();
      expect(find.byKey(const ValueKey('fakeRemote')), findsOneWidget);
      await tester.tap(find.byKey(const ValueKey('callFlip')));
      expect(engine.flips, 1);
      await tester.tap(find.byKey(const ValueKey('callCamera')));
      await tester.pump();
      expect(engine.camera, isFalse);
      expect(find.byKey(const ValueKey('localVideo')), findsNothing);
      await tester.tap(find.byKey(const ValueKey('callEnd')));
      await tester.pumpAndSettle();
      expect(find.byType(CallScreen), findsNothing);
    });

    testWidgets('nobody answers: missed after the ring time', (tester) async {
      await open(
        tester,
        (_) => const CallScreen(peerUid: 'u2', peerName: 'ravi', video: true),
      );
      await tester.pump();
      await tester.pump(kRingTimeout + const Duration(seconds: 1));
      await tester.pumpAndSettle();
      expect(backend.status['call1'], CallStatus.missed);
      expect(logs.single.status, CallStatus.missed);
      expect(logs.single.video, isTrue);
      expect(logs.single.seconds, 0);
      expect(find.byType(CallScreen), findsNothing);
    });

    testWidgets('cancelling while it rings counts as missed', (tester) async {
      await open(
        tester,
        (_) => const CallScreen(peerUid: 'u2', peerName: 'ravi', video: false),
      );
      await tester.pump();
      await tester.tap(find.byKey(const ValueKey('callEnd')));
      await tester.pumpAndSettle();
      expect(backend.status['call1'], CallStatus.missed);
      expect(logs.single.status, CallStatus.missed);
    });

    testWidgets('the other person declines', (tester) async {
      await open(
        tester,
        (_) => const CallScreen(peerUid: 'u2', peerName: 'ravi', video: false),
      );
      await tester.pump();
      backend.emit(backend.placed!.copyWithStatus(CallStatus.declined));
      await tester.pumpAndSettle();
      expect(logs.single.status, CallStatus.declined);
      expect(find.byType(CallScreen), findsNothing);
    });

    testWidgets('the other person hangs up after connecting', (tester) async {
      await open(
        tester,
        (_) => const CallScreen(peerUid: 'u2', peerName: 'ravi', video: false),
      );
      await tester.pump();
      engine.remoteJoined.value = true;
      await tester.pump();
      await tester.pump(const Duration(seconds: 5));
      backend.emit(backend.placed!.copyWithStatus(CallStatus.ended));
      await tester.pumpAndSettle();
      expect(logs.single.status, CallStatus.ended);
      expect(logs.single.seconds, 5);
    });

    testWidgets('no microphone permission: says so and closes', (tester) async {
      permissionOk = false;
      await open(
        tester,
        (_) => const CallScreen(peerUid: 'u2', peerName: 'ravi', video: false),
      );
      await tester.pump();
      expect(find.textContaining('Allow the microphone'), findsOneWidget);
      expect(backend.placed, isNull);
      await tester.pump(const Duration(seconds: 3));
      await tester.pumpAndSettle();
      expect(find.byType(CallScreen), findsNothing);
      expect(logs, isEmpty);
    });

    testWidgets('incoming: decline', (tester) async {
      const call = CallInfo(
        id: 'in1',
        callerId: 'u2',
        calleeId: 'me',
        video: false,
        status: CallStatus.ringing,
      );
      await open(
        tester,
        (_) => const IncomingCallScreen(
          call: call,
          caller: AppUser(uid: 'u2', username: 'ravi'),
        ),
      );
      expect(find.text('ravi'), findsOneWidget);
      expect(find.text('Incoming voice call'), findsOneWidget);
      await tester.tap(find.byKey(const ValueKey('declineCall')));
      await tester.pumpAndSettle();
      expect(backend.status['in1'], CallStatus.declined);
      expect(find.byType(IncomingCallScreen), findsNothing);
    });

    testWidgets('incoming: accept joins the same room', (tester) async {
      const call = CallInfo(
        id: 'in2',
        callerId: 'u2',
        calleeId: 'me',
        video: true,
        status: CallStatus.ringing,
      );
      await open(
        tester,
        (_) => const IncomingCallScreen(
          call: call,
          caller: AppUser(uid: 'u2', username: 'ravi'),
        ),
      );
      expect(find.text('Incoming video call'), findsOneWidget);
      await tester.tap(find.byKey(const ValueKey('acceptCall')));
      await tester.pumpAndSettle();
      expect(find.byType(CallScreen), findsOneWidget);
      expect(backend.status['in2'], CallStatus.accepted);
      expect(engine.channel, 'in2');
      expect(engine.video, isTrue);
      engine.remoteJoined.value = true;
      await tester.pump();
      await tester.tap(find.byKey(const ValueKey('callEnd')));
      await tester.pumpAndSettle();
      expect(backend.status['in2'], CallStatus.ended);
      // only the caller writes the chat line
      expect(logs, isEmpty);
    });

    testWidgets('incoming: the caller gives up, the screen closes', (
      tester,
    ) async {
      const call = CallInfo(
        id: 'in3',
        callerId: 'u2',
        calleeId: 'me',
        video: false,
        status: CallStatus.ringing,
      );
      await open(
        tester,
        (_) => const IncomingCallScreen(
          call: call,
          caller: AppUser(uid: 'u2', username: 'ravi'),
        ),
      );
      backend.emit(
        const CallInfo(
          id: 'in3',
          callerId: 'u2',
          calleeId: 'me',
          video: false,
          status: CallStatus.missed,
        ),
      );
      await tester.pumpAndSettle();
      expect(find.byType(IncomingCallScreen), findsNothing);
    });

    testWidgets('calls off until an App ID is saved', (tester) async {
      CallDeps.configured = () => false;
      await tester.pumpWidget(
        MaterialApp(
          home: Scaffold(
            body: Builder(
              builder: (c) => TextButton(
                onPressed: () =>
                    startCall(c, peerUid: 'u2', peerName: 'ravi', video: false),
                child: const Text('call'),
              ),
            ),
          ),
        ),
      );
      await tester.tap(find.text('call'));
      await tester.pump();
      expect(find.textContaining('set_agora_id'), findsOneWidget);
      expect(find.byType(CallScreen), findsNothing);
    });
  });
}

extension on CallInfo {
  CallInfo copyWithStatus(String s) => CallInfo(
    id: id,
    callerId: callerId,
    calleeId: calleeId,
    video: video,
    status: s,
    createdAt: createdAt,
  );
}
