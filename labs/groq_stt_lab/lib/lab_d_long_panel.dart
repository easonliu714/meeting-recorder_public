import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

import 'lab_debug_log.dart';

/// Gate D genuine long-running Android AudioRecord, not accelerated simulation.
class LabDLongPanel extends StatefulWidget {
  const LabDLongPanel({super.key,required this.debug});
  final LabDebugJournal debug;
  @override State<LabDLongPanel> createState()=>_LabDLongPanelState();
}
class _LabDLongPanelState extends State<LabDLongPanel> with WidgetsBindingObserver {
  static const api=MethodChannel('groq_stt_lab/offline_audio');
  Timer? _timer;
  bool _busy=false,_polling=false,_running=false,_pending=false,_dialog=false,_visible=true;
  String _phase='NONE';
  String? _verifiedSession;
  final _verifiedShas=<int,String>{};
  bool _previewing=false;
  String _report='尚未開始真實 60／120 分鐘錄音。';
  @override void initState(){super.initState();WidgetsBinding.instance.addObserver(this);unawaited(_refresh());}
  @override void dispose(){WidgetsBinding.instance.removeObserver(this);_timer?.cancel();super.dispose();}
  @override void didChangeAppLifecycleState(AppLifecycleState s) {
    _visible=s==AppLifecycleState.resumed;
    if(_visible)unawaited(_refresh());
  }
  Future<void> _start()async{
    if(_busy||_running)return;
    setState((){_busy=true;_verifiedSession=null;_verifiedShas.clear();});
    try{
      final p=await api.invokeMapMethod<String,dynamic>('labDLongStart');
      if(p?['longMode']!=true)throw StateError('LAB_D_LONG_START_HOLD');
      widget.debug.record('LAB_D_LONG_START',{'max_minutes':150,'part_minutes':60});
      if(mounted)setState((){
        _running=true;_phase='ARMED';
        _report='真實錄音已開始。第 60 分鐘只查狀態，不停止錄音；'
          '第 120 分鐘提醒後可繼續，最長 150 分鐘。';
      });
      _timer?.cancel();
      _timer=Timer.periodic(const Duration(seconds:5),(_)=>unawaited(_refresh()));
    }catch(e){_failure(e);}finally{if(mounted)setState(()=>_busy=false);}
  }
  void _failure(Object e){
    final code=LabDebugJournal.failureCode(e);
    widget.debug.record('LAB_D_LONG_HOLD',{'code':code});
    if(mounted)setState(()=>_report='HOLD：$code；原始資料不得清除。');
  }
  Future<void> _refresh()async{
    if(_polling)return;
    _polling=true;
    try{
      final p=await api.invokeMapMethod<String,dynamic>('labDLongStatus');
      final phase=p?['phase'],clock=p?['longPhase'],ms=p?['longElapsedMs'];
      final frames=p?['frames'],parts=p?['committed'],hour=p?['longHourSeen'];
      final pending=p?['longPending'],hourFrames=p?['longHourFrames'];
      if(phase is! String||clock is! String||ms is! int||ms<0||ms>9500000||
         frames is! int||frames<0||frames>144000000||
         parts is! int||parts<0||parts>3||hour is! bool||pending is! bool||
         hourFrames is! int||hourFrames<0||hourFrames>144000000) {
        throw StateError('LAB_D_LONG_STATUS_HOLD');
      }
      final running=p?['longMode']==true&&(phase=='starting'||phase=='recording');
      if(mounted)setState((){
        _running=running;_pending=pending&&running;_phase=clock;
        if(p?['longMode']==true)_report=
          '實體單調時計 '+(ms/60000).toStringAsFixed(1)+' 分鐘；'
          '錄音 $phase；提醒 $clock；'
          '實體 PCM $frames 樣本；提交 $parts 段；'
          '60 分鐘門檻 '+(hour?'已達':'未達')+'，當時 $hourFrames 樣本。'
          '時間門檻不代表 WAV 已提交；需結束後核對 SHA。';
      });
      if(!running){_timer?.cancel();_timer=null;}
      if(_pending&&_visible&&!_dialog){
        WidgetsBinding.instance.addPostFrameCallback((_){
          if(mounted&&_pending&&!_dialog)unawaited(_prompt());
        });
      }
    }catch(e){_failure(e);}finally{_polling=false;}
  }
  Future<void> _prompt()async{
    if(!mounted||_dialog||!_pending)return;
    _dialog=true;
    try{
      final answer=await showDialog<String>(context:context,barrierDismissible:false,
        builder:(c)=>AlertDialog(
          title:const Text('真實錄音：已達 120 分鐘'),
          content:const Text('麥克風繼續錄音中。可選擇繼續超過兩小時，'
            '或結束並封存。最大錄音 150 分鐘。'),
          actions:[
            TextButton(onPressed:()=>Navigator.pop(c,'continue'),
              child:const Text('繼續錄音')),
            TextButton(onPressed:()=>Navigator.pop(c,'end'),
              child:const Text('結束並封存'))
          ]));
      if(answer!=null)await _choice(answer);
    }finally{_dialog=false;}
  }
  Future<void> _choice(String action)async{
    if(!_running)return;
    try{
      final method=action=='continue'?'labDLongContinue':'labDLongEnd';
      final p=await api.invokeMapMethod<String,dynamic>(method);
      if(p?['longMode']!=true)throw StateError('LAB_D_LONG_CHOICE_HOLD');
      widget.debug.record('LAB_D_LONG_CHOICE',{'action':action});
      await _refresh();
    }catch(e){_failure(e);}
  }
  Future<void> _stop()async{
    if(!_running)return;
    try{
      await api.invokeMethod<void>('labDLongStop');
      widget.debug.record('LAB_D_LONG_MANUAL_STOP');
      if(mounted)setState(()=>_report='已要求正常停止，等待安全封存後再唯讀核對。');
    }catch(e){_failure(e);}
  }
  Future<void> _recover()async{
    if(_busy||_running)return;
    setState((){
      _busy=true;
      _verifiedSession=null;_verifiedShas.clear();
      _report='正在對每段實體 WAV 重新校驗 SHA256，大檔案讀回可能較久。';
    });
    try{
      final p=await api.invokeMapMethod<String,dynamic>('labDLongRecover');
      final parts=p?['parts'],tail=p?['tailBytes'],status=p?['status'];
      final pts=p?['ptsStatus'],count=p?['ptsCount'],session=p?['session'];
      final cross=p?['crossHourHardwareObserved'];
      final intervals=p?['ptsIntervals'];
      final coverage=p?['ptsCoverage'];
      final observations=p?['ptsObservations'],provenance=p?['ptsProvenance'];
      if(p?['unaccelerated']!=true||parts is! List||parts.length>3||
         tail is! int||tail<0||tail>115200000||
         status is! String||!{'completed','interrupted','uncommitted'}.contains(status)||
         pts is! String||count is! int||count<0||count>48||
         cross is! bool||intervals is! List||coverage is! Map||
         intervals.length!=(count>0?count-1:0)||observations is! List||
         observations.length!=count||
         !{'NOT_VERIFIED','LOCAL_SESSION_RECORDER_BOUND_NOT_ATTESTED'}.contains(provenance)||
         session is! String||
         !RegExp(r'^[0-9a-f-]{36}$').hasMatch(session)) {
        throw StateError('LAB_D_LONG_READBACK_HOLD');
      }
      var last=0;final lines=<String>[];final hashes=<int,String>{};
      for(final raw in parts){
        if(raw is! Map)throw StateError('LAB_D_LONG_READBACK_HOLD');
        final i=raw['index'],a=raw['start'],b=raw['end'];
        final size=raw['bytes'],sha=raw['sha12'],full=raw['sha256'];
        if(i is! int||i!=lines.length+1||a!=last||b is! int||b<=last||
           b-last>57600000||size!=(b-last)*2+44||sha is! String||
           !RegExp(r'^[0-9a-f]{12}$').hasMatch(sha)||
           full is! String||!RegExp(r'^[0-9a-f]{64}$').hasMatch(full)||
           !full.startsWith(sha)||raw['rawMatches']!=true) {
          throw StateError('LAB_D_LONG_READBACK_HOLD');
        }
        last=b;
        hashes[i]=full;
        lines.add('Part $i：$a–$b 樣本；$size B；完整 SHA256 $full；原始 PCM 位元組一致');
      }
      if(status=='completed'&&tail!=0||
         status=='uncommitted'&&parts.isNotEmpty) {
        throw StateError('LAB_D_LONG_READBACK_HOLD');
      }
      final observationLines=<String>[];
      const observationStates={'LEGACY_TIMEBASE_NOT_VERIFIED','HARDWARE_UNAVAILABLE_NOT_VERIFIED',
        'FUTURE_TIMESTAMP_HOLD','WIDE_WINDOW_HOLD','STALE_TIMESTAMP_HOLD','BOUNDED_OBSERVATION_NOT_GAP_FREE'};
      for(final raw in observations){
        if(raw is! Map)throw StateError('LAB_D_LONG_PTS_OBSERVATION_HOLD');
        final v=raw['version'],f=raw['pcmFrame'],s=raw['state'];
        final m=raw['monoWindowNs'],el=raw['elapsedWindowNs'];
        final lo=raw['lagLowerNs'],hi=raw['lagUpperNs'];
        if(!{1,2}.contains(v)||f is! int||f<0||f>144000000||
           !observationStates.contains(s)||(v==1&&(m!=null||el!=null||lo!=null||hi!=null))||
           (v==2&&(m is! int||m<0||el is! int||el<0))||
           (lo==null)!=(hi==null)||(lo!=null&&(lo is! int||hi is! int||lo>hi))){
          throw StateError('LAB_D_LONG_PTS_OBSERVATION_HOLD');
        }
        observationLines.add('Receipt v$v；PCM $f；同時基取樣窗 ${m??"未知"} ns；'
          'elapsed 取樣窗 ${el??"未知"} ns；硬體時間戳落後範圍 ${lo??"未知"}～${hi??"未知"} ns；$s');
      }
      final evidence=<String>[];
      int? previous;
      const states={'UNKNOWN','RESET_OR_STALL','POSSIBLE_GAP','POSSIBLE_OVERLAP',
        'HARDWARE_CLOCK_UNALIGNED','WITHIN_DIAGNOSTIC_BOUND_NOT_GAP_FREE'};
      for(final raw in intervals){
        if(raw is! Map)throw StateError('LAB_D_LONG_PTS_CROSSWALK_HOLD');
        final a=raw['pcmStart'],b=raw['pcmEnd'],d=raw['pcmDelta'];
        final n=raw['hardwareDelta'],r=raw['hardwareMinusPcm'];
        final h=raw['hardwareElapsedNs'],e=raw['hardwareClockMinusFramesNs'];
        final observed=raw['observedElapsedNs'],state=raw['state'];
        final clockState=raw['clockObservationState'];
        final c60=raw['crosses60'],c120=raw['crosses120'];
        if(a is! int||b is! int||a<0||b<=a||b>144000000||d!=b-a||
           (previous!=null&&a!=previous)||observed is! int||observed<=0||
           (n!=null&&n is! int)||(h!=null&&h is! int)||
           (r!=null&&r is! int)||(e!=null&&e is! int)||
           (n==null)!=(h==null)||(n==null)!=(r==null)||
           (n is int&&r!=n-(b-a))||
           c60!=(a<57600000&&b>=57600000)||
           c120!=(a<115200000&&b>=115200000)||!states.contains(state)||
           !{'LEGACY_TIMEBASE_NOT_VERIFIED','CLOCK_SEQUENCE_HOLD','POSSIBLE_SUSPEND_HOLD',
              'CLOCK_DISCONTINUITY_HOLD','OBSERVATION_NOT_VERIFIED','BOUNDED_INTERVAL_NOT_GAP_FREE'}.contains(clockState)){
          throw StateError('LAB_D_LONG_PTS_CROSSWALK_HOLD');
        }
        previous=b;
        evidence.add('PCM $a–$b；硬體差值 ${r??"未知"} frames；'
          '硬體時計誤差 ${e??"未知"} ns；觀測間隔 $observed ns；'
          '${c60==true?"跨60min ":""}${c120==true?"跨120min ":""}$state；同時基區間 $clockState');
      }
      // Verify the native partition covers exactly the sealed ranges, without
      // promoting unobserved or uncommitted PCM into hardware evidence.
      final coverageParts=coverage['parts'],boundaries=coverage['boundaries'];
      final bounded=coverage['boundedFrames'],unknown=coverage['unknownFrames'];
      final outside=coverage['outsideCommittedSamples'];
      if(coverage['continuity']!='NOT_VERIFIED'||coverage['committedFrames']!=last||
         bounded is! int||unknown is! int||bounded<0||unknown<0||bounded+unknown!=last||
         outside is! int||outside<0||outside>count||(status=='completed'&&outside!=0)||
         coverageParts is! List||coverageParts.length!=parts.length||
         boundaries is! List||boundaries.length!=(parts.isEmpty?0:parts.length-1)){
        throw StateError('LAB_D_LONG_PTS_COVERAGE_HOLD');
      }
      const coverageStates={'BOUNDED_PAIR_NOT_GAP_FREE','PAIR_NOT_VERIFIED',
        'PAIR_DIAGNOSTIC_HOLD','PAIR_OUTSIDE_COMMITTED_NOT_VERIFIED','UNOBSERVED_NOT_VERIFIED'};
      final coverageLines=<String>[];
      var sum=0;
      for(var i=0;i<coverageParts.length;i++){
        final c=coverageParts[i],part=parts[i];
        if(c is! Map||part is! Map||c['index']!=i+1||
           c['start']!=part['start']||c['end']!=part['end']||c['segments'] is! List){
          throw StateError('LAB_D_LONG_PTS_COVERAGE_HOLD');
        }
        final start=c['start'],end=c['end'];
        if(start is! int||end is! int)throw StateError('LAB_D_LONG_PTS_COVERAGE_HOLD');
        var cursor=start,partBounded=0;
        final segments=c['segments'] as List;
        if(segments.isEmpty||segments.length>50)throw StateError('LAB_D_LONG_PTS_COVERAGE_HOLD');
        for(final s in segments){
          if(s is! Map)throw StateError('LAB_D_LONG_PTS_COVERAGE_HOLD');
          final a=s['start'],b=s['end'],state=s['state'];
          if(a is! int||b is! int||a!=cursor||b<=a||b>end||!coverageStates.contains(state)){
            throw StateError('LAB_D_LONG_PTS_COVERAGE_HOLD');
          }
          if(state=='BOUNDED_PAIR_NOT_GAP_FREE')partBounded+=b-a;
          coverageLines.add('Part ${i+1} PCM $a–$b；$state');
          cursor=b;
        }
        if(cursor!=end||c['boundedFrames']!=partBounded||
           c['unknownFrames']!=end-start-partBounded){
          throw StateError('LAB_D_LONG_PTS_COVERAGE_HOLD');
        }
        sum+=partBounded;
      }
      if(sum!=bounded)throw StateError('LAB_D_LONG_PTS_COVERAGE_HOLD');
      final boundaryLines=<String>[];
      for(var i=0;i<boundaries.length;i++){
        final b=boundaries[i];
        if(b is! Map||b['frame']!=(parts[i] as Map)['end']){
          throw StateError('LAB_D_LONG_PTS_COVERAGE_HOLD');
        }
        final f=b['frame'],a=b['pairStart'],z=b['pairEnd'],s=b['state'];
        if(f is! int||!{...coverageStates,'BOUNDARY_SAMPLE_ONLY_NOT_VERIFIED',
           'BOUNDARY_UNOBSERVED_NOT_VERIFIED'}.contains(s)||(a==null)!=(z==null)||
           (a!=null&&(a is! int||z is! int||a>=f||z<=f))){
          throw StateError('LAB_D_LONG_PTS_COVERAGE_HOLD');
        }
        boundaryLines.add('已提交 Part ${i+1}/${i+2} 邊界 $f；$s；取樣端點 ${a??"未知"}–${z??"未知"}');
      }
      widget.debug.record('LAB_D_LONG_READBACK_OK',{
        'parts':lines.length,'frames':last,'tail_bytes_uncommitted':tail,
        'pts_state':pts,'pts_count':count,'cross_hour_hardware_observed':cross,
        'pts_receipt_version':observations.isEmpty?0:observations.first['version'],
        'pts_provenance':provenance,
        'pts_bounded_pair_frames':bounded,'pts_unknown_frames':unknown,
        'pts_outside_committed_samples':outside,'pts_committed_boundaries':boundaries.length,
        'pts_continuity':'NOT_VERIFIED'
      });
      if(mounted)setState((){_verifiedSession=session;_verifiedShas.addAll(hashes);_report=
        '最新真實錄音磁碟 Session $session；'
        '跨程序來源身分：NOT_VERIFIED。錄音來源本機綁定：$provenance。'
        '狀態 $status；提交 '+lines.length.toString()+' 段；'
        '未提交 $tail B；硬體 PTS $pts；取樣 $count 次；'
        '60 分鐘兩側硬體取樣：'+(cross?'已觀察':'未證實')+'。'
        +lines.join('；')
        +'。PTS 同時基取樣證據：'
        +(observationLines.isEmpty?'NOT_VERIFIED':observationLines.join('\n'))
        +'。PTS 區間證據（取樣有限，非無掉幀證明）：'
        + (evidence.isEmpty?'NOT_VERIFIED':evidence.join('\n'))
        +'。已提交 PCM 證據覆蓋（非連續性證明）：有界端點區間 $bounded 樣本；'
        '未驗證 $unknown 樣本；提交範圍外取樣 $outside 次；全程連續性 NOT_VERIFIED。'
        +coverageLines.join('\n')
        +'。實體已提交 Part 邊界：'
        +(boundaryLines.isEmpty?'無內部邊界':boundaryLines.join('\n'))
        +'。硬體時計與 elapsedRealtime 觀測間隔分開呈現。'
        'PTS 單調與 Part 連續不證明聲學無掉幀。'
        '未提交資料不補零、重送、覆寫；不自動續錄。';});
    }catch(e){_failure(e);}finally{if(mounted)setState(()=>_busy=false);}
  }
  Future<void> _preview(int index)async{
    final session=_verifiedSession,sha=_verifiedShas[index];
    if(_busy||_running||session==null||sha==null)return;
    setState((){_busy=true;_previewing=true;});
    try{
      final p=await api.invokeMapMethod<String,dynamic>('labDLongPreview',
        {'session':session,'index':index,'sha256':sha});
      final ms=p?['positionMs'],stopped=p?['stopped'];
      if(p?['index']!=index||ms is! int||ms<0||stopped is! bool){
        throw StateError('LAB_D_LONG_PLAYBACK_HOLD');
      }
      widget.debug.record('LAB_D_LONG_PREVIEW_RESULT',{'index':index,'position_ms':ms,'stopped':stopped});
      if(mounted)setState(()=>_report+='\nPart $index 預聽：$ms ms；'
        +(stopped?'已停止':'已結束')+'。實際聽感須由使用者確認。');
    }catch(e){_failure(e);}finally{if(mounted)setState((){_busy=false;_previewing=false;});}
  }
  Future<void> _stopPreview()async{
    try{await api.invokeMethod<void>('labDLongPreviewStop');}catch(e){_failure(e);}
  }
  @override Widget build(BuildContext context)=>Column(children:[
    const Divider(),
    const Text('LAB-REC-D｜真實 60／120 分鐘耐久與提醒'),
    const Text('真實麥克風、真實單調時鐘。每 60 分鐘封存一段 WAV，'
      '120 分鐘提醒，最長 150 分鐘。'
      '需至少 1.25 GB 可用空間；PCM 與 WAV 雙份保留。'
      '不可清除資料或為測試刻意填滿手機儲存空間。'),
    FilledButton.tonal(
      key:const Key('lab-d-long-start'),
      onPressed:_busy||_running?null:_start,
      child:const Text('開始真實最長 150 分鐘錄音')),
    OutlinedButton(
      key:const Key('lab-d-long-status'),
      onPressed:_busy?null:_refresh,
      child:const Text('查詢真實錄音與 60 分鐘檢查點')),
    OutlinedButton(
      key:const Key('lab-d-long-continue'),
      onPressed:_running&&_pending?()=>_choice('continue'):null,
      child:const Text('繼續錄音')),
    OutlinedButton(
      key:const Key('lab-d-long-end'),
      onPressed:_running&&(_pending||_phase=='CONTINUED')
        ?()=>_choice('end'):null,
      child:const Text('結束並封存')),
    OutlinedButton(
      key:const Key('lab-d-long-stop'),
      onPressed:_running?_stop:null,
      child:const Text('提前停止並封存（中斷測試）')),
    OutlinedButton(
      key:const Key('lab-d-long-readback'),
      onPressed:_busy||_running?null:_recover,
      child:const Text('核對真實錄音 Part／硬體 PTS／SHA')),
    for(final index in _verifiedShas.keys)
      OutlinedButton(onPressed:_busy||_running?null:()=>_preview(index),
        child:Text('唯讀預聽 Part $index（最多 10 秒）')),
    if(_previewing) OutlinedButton(onPressed:_stopPreview,child:const Text('停止預聽')),
    Text(_report),
  ]);
}
