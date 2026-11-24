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
  String _report='尚未開始真實 60／120 分鐘錄音。';
  @override void initState(){super.initState();WidgetsBinding.instance.addObserver(this);unawaited(_refresh());}
  @override void dispose(){WidgetsBinding.instance.removeObserver(this);_timer?.cancel();super.dispose();}
  @override void didChangeAppLifecycleState(AppLifecycleState s) {
    _visible=s==AppLifecycleState.resumed;
    if(_visible)unawaited(_refresh());
  }
  Future<void> _start()async{
    if(_busy||_running)return;
    setState(()=>_busy=true);
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
      _report='正在對每段實體 WAV 重新校驗 SHA256，大檔案讀回可能較久。';
    });
    try{
      final p=await api.invokeMapMethod<String,dynamic>('labDLongRecover');
      final parts=p?['parts'],tail=p?['tailBytes'],status=p?['status'];
      final pts=p?['ptsStatus'],count=p?['ptsCount'],session=p?['session'];
      final cross=p?['crossHourHardwareObserved'];
      final intervals=p?['ptsIntervals'];
      if(p?['unaccelerated']!=true||parts is! List||parts.length>3||
         tail is! int||tail<0||tail>115200000||
         status is! String||!{'completed','interrupted','uncommitted'}.contains(status)||
         pts is! String||count is! int||count<0||count>48||
         cross is! bool||intervals is! List||
         intervals.length!=(count>0?count-1:0)||session is! String||
         !RegExp(r'^[0-9a-f-]{36}$').hasMatch(session)) {
        throw StateError('LAB_D_LONG_READBACK_HOLD');
      }
      var last=0;final lines=<String>[];
      for(final raw in parts){
        if(raw is! Map)throw StateError('LAB_D_LONG_READBACK_HOLD');
        final i=raw['index'],a=raw['start'],b=raw['end'];
        final size=raw['bytes'],sha=raw['sha12'];
        if(i!=lines.length+1||a!=last||b is! int||b<=last||
           b-last>57600000||size!=(b-last)*2+44||sha is! String||
           !RegExp(r'^[0-9a-f]{12}$').hasMatch(sha)) {
          throw StateError('LAB_D_LONG_READBACK_HOLD');
        }
        last=b;
        lines.add('Part $i：$a–$b 樣本；$size B；SHA12 $sha');
      }
      if(status=='completed'&&tail!=0||
         status=='uncommitted'&&parts.isNotEmpty) {
        throw StateError('LAB_D_LONG_READBACK_HOLD');
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
        final c60=raw['crosses60'],c120=raw['crosses120'];
        if(a is! int||b is! int||a<0||b<=a||b>144000000||d!=b-a||
           (previous!=null&&a!=previous)||observed is! int||observed<=0||
           (n!=null&&n is! int)||(h!=null&&h is! int)||
           (r!=null&&r is! int)||(e!=null&&e is! int)||
           (n==null)!=(h==null)||(n==null)!=(r==null)||
           (n is int&&r!=n-(b-a))||
           c60!=(a<57600000&&b>=57600000)||
           c120!=(a<115200000&&b>=115200000)||!states.contains(state)){
          throw StateError('LAB_D_LONG_PTS_CROSSWALK_HOLD');
        }
        previous=b;
        evidence.add('PCM $a–$b；硬體差值 ${r??"未知"} frames；'
          '硬體時計誤差 ${e??"未知"} ns；觀測間隔 $observed ns；'
          '${c60==true?"跨60min ":""}${c120==true?"跨120min ":""}$state');
      }
      widget.debug.record('LAB_D_LONG_READBACK_OK',{
        'parts':lines.length,'frames':last,'tail_bytes_uncommitted':tail,
        'pts_state':pts,'pts_count':count,'cross_hour_hardware_observed':cross
      });
      if(mounted)setState(()=>_report=
        '最新真實錄音磁碟 Session $session；'
        '跨程序來源身分：NOT_VERIFIED。'
        '狀態 $status；提交 '+lines.length.toString()+' 段；'
        '未提交 $tail B；硬體 PTS $pts；取樣 $count 次；'
        '60 分鐘兩側硬體取樣：'+(cross?'已觀察':'未證實')+'。'
        +lines.join('；')
        +'。PTS 區間證據（取樣有限，非無掉幀證明）：'
        + (evidence.isEmpty?'NOT_VERIFIED':evidence.join('\n'))
        +'。硬體時計與 elapsedRealtime 觀測間隔分開呈現。'
        'PTS 單調與 Part 連續不證明聲學無掉幀。'
        '未提交資料不補零、重送、覆寫；不自動續錄。');
    }catch(e){_failure(e);}finally{if(mounted)setState(()=>_busy=false);}
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
    Text(_report),
  ]);
}
