import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

import 'lab_debug_log.dart';

/// Gate D stage-1: actual AudioRecord hardware-PTS pilot, not 60/120 min.
class LabDPtsPanel extends StatefulWidget {
  const LabDPtsPanel({super.key, required this.debug});
  final LabDebugJournal debug;
  @override
  State<LabDPtsPanel> createState()=>_LabDPtsPanelState();
}

class _LabDPtsPanelState extends State<LabDPtsPanel>
    with WidgetsBindingObserver {
  static const _channel=MethodChannel('groq_stt_lab/offline_audio');
  Timer? _poll;
  bool _busy=false, _running=false, _polling=false;
  String _status='尚未執行實體硬體時間戳預檢。';
  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addObserver(this);
  }
  @override
  void dispose() {
    WidgetsBinding.instance.removeObserver(this);
    _poll?.cancel();
    super.dispose();
  }
  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    if(state==AppLifecycleState.resumed && _running) unawaited(_refresh());
  }
  Future<void> _start() async {
    if(_busy||_running)return;
    setState(()=>_busy=true);
    try {
      final p=await _channel.invokeMapMethod<String,dynamic>('labDPtsStart');
      if(p?['dMode']!=true)throw StateError('LAB_D_START_HOLD');
      widget.debug.record('LAB_D_PTS_START',{'physical':true,'max_seconds':24});
      if(!mounted)return;
      setState(() {
        _running=true;
        _status='實體麥克風預檢中，最多 24 秒；並非真正的兩小時耐久錄音。';
      });
      _poll?.cancel();
      _poll=Timer.periodic(const Duration(seconds:2),(_)=>unawaited(_refresh()));
    } catch(e) {
      final code=LabDebugJournal.failureCode(e);
      widget.debug.record('LAB_D_HOLD',{'code':code});
      if(mounted)setState(()=>_status='HOLD：$code');
    } finally {if(mounted)setState(()=>_busy=false);}
  }
  Future<void> _refresh() async {
    if(_polling)return;
    _polling=true;
    try {
      final p=await _channel.invokeMapMethod<String,dynamic>('labDPtsStatus');
      if(p?['dMode']!=true) {
        _poll?.cancel();
        if(mounted)setState((){
          _running=false;
          _status='程序已停止；請手動執行磁碟唯讀核對。不會自動續錄。';
        });
        return;
      }
      final phase=p?['phase'],frames=p?['frames'],parts=p?['committed'];
      final pts=p?['dPtsStatus'],count=p?['dPtsCount'];
      if(phase is! String || frames is! int || frames<0 || frames>384000 ||
        parts is! int || parts<0 || parts>4 || pts is! String ||
        count is! int || count<0 || count>16) throw StateError('LAB_D_STATUS_HOLD');
      final running=phase=='starting'||phase=='recording';
      if(mounted)setState((){
        _running=running;
        _status='錄音 $phase；已採集 $frames 樣本；已提交 $parts 段；'
            '硬體 PTS $pts；取樣 $count 次。真實 60／120 分鐘尚未驗證。';
      });
      if(!running)_poll?.cancel();
    } catch(e) {
      widget.debug.record('LAB_D_HOLD',{'code':LabDebugJournal.failureCode(e)});
    } finally {_polling=false;}
  }
  Future<void> _stop() async {
    if(!_running)return;
    try {
      await _channel.invokeMethod<void>('labDPtsStop');
      widget.debug.record('LAB_D_STOP_REQUESTED');
      if(mounted)setState(()=>_status='已要求正常封存，稍後核對 Part 與硬體 PTS。');
    } catch(e) {
      widget.debug.record('LAB_D_HOLD',{'code':LabDebugJournal.failureCode(e)});
    }
  }
  Future<void> _recover() async {
    if(_busy||_running)return;
    setState(()=>_busy=true);
    try {
      final p=await _channel.invokeMapMethod<String,dynamic>('labDPtsRecover');
      final parts=p?['parts'],status=p?['status'],tail=p?['tailBytes'];
      final pts=p?['dPtsStatus'],count=p?['dPtsCount'],session=p?['dSession'];
      if(p?['dMode']!=true || parts is! List || parts.length>4 ||
        status is! String || !{'completed','interrupted','uncommitted'}.contains(status) ||
        tail is! int || tail<0 || tail>768000 ||
        pts is! String || count is! int || count<0 || count>16 ||
        session is! String || !RegExp(r'^[0-9a-f-]{36}$').hasMatch(session)) {
        throw StateError('LAB_D_READBACK_HOLD');
      }
      var last=0;final lines=<String>[];
      for(final raw in parts) {
        if(raw is! Map)throw StateError('LAB_D_READBACK_HOLD');
        final idx=raw['index'],start=raw['start'],end=raw['end'];
        final bytes=raw['bytes'],sha=raw['sha12'];
        if(idx!=lines.length+1 || start!=last || end is! int ||
           end<=last || end-last>96000 || bytes!=(end-last)*2+44 ||
           sha is! String || !RegExp(r'^[0-9a-f]{12}$').hasMatch(sha)) {
          throw StateError('LAB_D_READBACK_HOLD');
        }
        lines.add('Part $idx：樣本 $start–$end；$bytes B；SHA12 $sha');
        last=end;
      }
      if(status=='completed'&&tail!=0 ||
         status=='uncommitted'&&lines.isNotEmpty ||
         pts=='HARDWARE_PTS_OBSERVED_NOT_GAP_FREE'&&count<2) {
        throw StateError('LAB_D_READBACK_HOLD');
      }
      widget.debug.record('LAB_D_READBACK_OK',{
        'parts':lines.length,'frames':last,'tail_bytes_uncommitted':tail,
        'pts_state':pts,'pts_count':count
      });
      if(mounted)setState(()=>_status=
          '最近 D 預檢 Session：$session（跨程序前後身分尚未獨立驗證）。'
          '磁碟 $status；已提交 '+lines.length.toString()+' 段；'
          '未提交 PCM $tail B。硬體 PTS：$pts；取樣 $count 次。'
          +lines.join('；')
          +'。硬體時間戳單調不等於全段無掉幀或 60／120 分鐘耐久。'
          '未提交資料不補零、重送、覆寫；不自動續錄。');
    } catch(e) {
      final code=LabDebugJournal.failureCode(e);
      widget.debug.record('LAB_D_HOLD',{'code':code});
      if(mounted)setState(()=>_status='HOLD：$code；原始 Part 保留。');
    } finally {if(mounted)setState(()=>_busy=false);}
  }
  @override
  Widget build(BuildContext context)=>Column(children:[
    const Divider(),
    const Text('LAB-REC-D｜實體 AudioRecord 硬體 PTS 24 秒預檢'),
    const Text('階段一：真實麥克風最多 24 秒／4 Part，'
      '採集 Android getTimestamp/framePosition 與 monotonic 時鐘。'
      '這不是 60／120 分鐘真實耐久、全域 PTS 或無掉幀驗收。'),
    FilledButton.tonal(
      key:const Key('lab-d-pts-start'),
      onPressed:_busy||_running?null:_start,
      child:const Text('開始 24 秒硬體 PTS 預檢'),
    ),
    OutlinedButton(
      key:const Key('lab-d-pts-status'),
      onPressed:_busy?null:_refresh,
      child:const Text('查詢硬體 PTS 預檢狀態'),
    ),
    OutlinedButton(
      key:const Key('lab-d-pts-stop'),
      onPressed:_running?_stop:null,
      child:const Text('停止預檢並封存'),
    ),
    OutlinedButton(
      key:const Key('lab-d-pts-readback'),
      onPressed:_busy||_running?null:_recover,
      child:const Text('核對硬體 PTS／已提交 Part'),
    ),
    Text(_status),
  ]);
}
