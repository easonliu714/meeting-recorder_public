package com.example.meeting_recorder.public_lab_v45.groq_stt_lab

import java.io.File
import java.io.FileOutputStream
import java.nio.ByteBuffer
import java.nio.ByteOrder
import java.nio.file.Files
import java.util.UUID

private fun wav(dir: File, n: Int, frames: Int, marker: Byte): File {
    val size = frames * 2
    val b = ByteBuffer.allocate(44 + size).order(ByteOrder.LITTLE_ENDIAN)
    fun tag(s: String) { b.put(s.toByteArray(Charsets.US_ASCII)) }
    tag("RIFF"); b.putInt(36 + size); tag("WAVE"); tag("fmt "); b.putInt(16)
    b.putShort(1); b.putShort(1); b.putInt(16000); b.putInt(32000); b.putShort(2); b.putShort(16)
    tag("data"); b.putInt(size); repeat(size) { b.put(marker) }
    return File(dir, "part_%06d.wav".format(n)).apply { writeBytes(b.array()) }
}
private fun reject(block: () -> Unit) { check(runCatching(block).isFailure) }
fun main() {
    val base = Files.createTempDirectory("lab-multipart-host-").toFile()
    var count = 0
    fun case(name: String, body: (File, UUID, LabMultiPartProof) -> Unit) {
        val id = UUID.randomUUID(); val folder = File(base, id.toString()); check(folder.mkdir())
        body(folder, id, LabMultiPartProof(folder,id)); count++; println("PASS $name")
    }
    try {
        case("no committed receipt fails closed") { d,_,j ->
            reject{j.recover()}; wav(d,1,48000,1); reject{j.recover()}; check(j.commit(1).end==48000L)
        }
        case("three physical parts / cumulative frames / restart") { d,id,j ->
            (1..3).forEach { wav(d,it,48000,it.toByte()); j.commit(it) }
            val r=LabMultiPartProof(d,id).recover(); check(r.map{it.start}==listOf(0L,48000L,96000L)); check(r.last().end==144000L); check(r.map{it.sha}.toSet().size==3)
        }
        case("uncommitted WAV and raw tail not promoted") { d,id,j ->
            wav(d,1,48000,1); j.commit(1); wav(d,2,48000,2); val tail=File(d,"part_000003_inflight.pcm").apply{writeBytes(byteArrayOf(1,2,3))}; check(LabMultiPartProof(d,id).recover().size==1); check(tail.length()==3L)
        }
        case("no overwrite / out-of-order commit") { d,_,j ->
            val f=wav(d,1,48000,1); val raw=f.readBytes(); j.commit(1); val c=File(d,"part_000001.commit"); val receipt=c.readBytes(); reject{j.commit(1)}; reject{j.commit(3)}; check(f.readBytes().contentEquals(raw) && c.readBytes().contentEquals(receipt))
        }
        case("same-size WAV mutation rejected") { d,_,j ->
            val f=wav(d,1,48000,1); j.commit(1); val raw=f.readBytes(); raw[50]=5; f.writeBytes(raw); reject{j.recover()}; check(f.readBytes().contentEquals(raw))
        }
        case("missing committed source rejected") { d,_,j ->
            val f=wav(d,1,48000,1); j.commit(1); check(f.renameTo(File(d,"fixture-moved.wav"))); reject{j.recover()}
        }
        case("missing prefix receipt rejected") { d,_,j ->
            wav(d,1,48000,1);j.commit(1);wav(d,2,48000,2);j.commit(2);check(File(d,"part_000001.commit").renameTo(File(d,"fixture-moved.txt")));reject{j.recover()}
        }
        case("forged receipt rejected") { d,_,j ->
            wav(d,1,48000,1);j.commit(1);val f=File(d,"part_000001.commit");f.writeText(f.readText().replace("\t48000\t","\t48001\t"));reject{j.recover()}
        }
        case("unsealed RIFF rejected") { d,_,j ->
            val f=wav(d,1,48000,1);val raw=f.readBytes();raw[4]=0;f.writeBytes(raw);reject{j.commit(1)};check(!File(d,"part_000001.commit").exists())
        }
        case("symlink source rejected") { d,_,j ->
            val f=wav(d,1,48000,1);val other=File(d,"fixture.wav");check(f.renameTo(other));Files.createSymbolicLink(f.toPath(),other.toPath());reject{j.commit(1)}
        }
        case("normal terminal is immutable and binds final extent") { d,id,j ->
            (1..3).forEach { wav(d,it,48000,it.toByte()); j.commit(it) }
            check(!j.recoverSnapshot().finished)
            reject { j.finish(2) }; check(!File(d,"finished_v1.txt").exists())
            check(j.finish(3).finished)
            val r=LabMultiPartProof(d,id).recoverSnapshot(); check(r.finished && r.receipts.size==3)
            reject{j.finish(3)}; wav(d,4,48000,4); reject{j.commit(4)}
            check(File(d,"part_000004.wav").exists())
        }
        case("missing final committed receipt after terminal rejected") { d,id,j ->
            (1..3).forEach { wav(d,it,48000,it.toByte()); j.commit(it) };j.finish(3)
            check(File(d,"part_000003.commit").renameTo(File(d,"fixture-missing.txt")))
            reject { LabMultiPartProof(d,id).recoverSnapshot() }
            check(File(d,"part_000003.wav").exists())
        }
        case("malformed terminal cannot become complete") { d,_,j ->
            wav(d,1,48000,1);j.commit(1);j.finish(1)
            File(d,"finished_v1.txt").writeText("forged")
            reject{j.recoverSnapshot()};reject{j.commit(2)}
        }
        case("stream writer seals four chunks across read boundaries") { d,id,_ ->
            val counts=mutableListOf<Int>()
            LabMultiPartSink(d,id,12,4,{true},{counts.add(it)}).use { s ->
                s.accept(ByteArray(10){1});s.accept(ByteArray(18){2});s.accept(ByteArray(20){3});s.finish(true)
            }
            val r=LabMultiPartProof(d,id).recoverSnapshot()
            check(r.finished && r.receipts.size==4 && r.receipts.last().end==24L)
            check(counts==listOf(1,2,3,4))
        }
        case("later interruption keeps raw tail") { d,id,_ ->
            LabMultiPartSink(d,id,12,4,{true}).use { s ->s.accept(ByteArray(32){7});s.finish(false)}
            val r=LabMultiPartProof(d,id).recoverSnapshot()
            check(!r.finished && r.receipts.size==2 && r.receipts.last().end==12L)
            check(File(d,"part_000003_inflight.pcm").length()==8L)
            check(!File(d,"part_000003.wav").exists())
        }
        case("normal finish seals short last part") { d,id,_ ->
            LabMultiPartSink(d,id,12,4,{true}).use { s ->s.accept(ByteArray(16){4});s.finish(true)}
            val r=LabMultiPartProof(d,id).recoverSnapshot()
            check(r.finished && r.receipts.map {it.bytes}==listOf(56L,48L))
        }
        case("early interruption never promotes first raw tail") { d,id,_ ->
            LabMultiPartSink(d,id,12,4,{true}).use { s ->s.accept(ByteArray(4){3});s.finish(false)}
            check(File(d,"part_000001_inflight.pcm").length()==4L)
            reject {LabMultiPartProof(d,id).recover()}
        }
        case("controlled storage failure preserves prior receipt") { d,id,_ ->
            var space=true
            LabMultiPartSink(d,id,12,4,{space}).use { s ->
                s.accept(ByteArray(12){2});s.accept(ByteArray(4){3})
                space=false;reject{s.accept(ByteArray(8){1})}
            }
            val r=LabMultiPartProof(d,id).recoverSnapshot()
            check(!r.finished && r.receipts.size==1)
            check(File(d,"part_000002_inflight.pcm").length()==4L)
        }
        case("receipt writer IO rejected without touching WAV") { d,id,_ ->
            val f=wav(d,1,48000,1)
            val prior=f.readBytes()
            val j=LabMultiPartProof(d,id,{_,_->throw java.io.IOException("sensitive sandbox path")})
            val e=runCatching { j.commit(1) }.exceptionOrNull()
            check(e?.message=="LAB_MULTI_RECEIPT_WRITE_HOLD")
            check(f.readBytes().contentEquals(prior))
            check(!File(d,"part_000001.commit").exists())
            reject { LabMultiPartProof(d,id).recover() }
        }
        case("receipt writer unsupported rejected without touching WAV") { d,id,_ ->
            val f=wav(d,1,48000,1)
            val j=LabMultiPartProof(d,id,{_,_->throw UnsupportedOperationException("unsupported")})
            val e=runCatching { j.commit(1) }.exceptionOrNull()
            check(e?.message=="LAB_MULTI_RECEIPT_UNSUPPORTED_HOLD")
            check(f.exists() && !File(d,"part_000001.commit").exists())
        }
        case("partially written committed receipt fails closed and source survives") { d,id,_ ->
            val f=wav(d,1,48000,1)
            val original=f.readBytes()
            val j=LabMultiPartProof(d,id,{dest, bytes->
                check(dest.createNewFile())
                FileOutputStream(dest).use { out ->
                    out.write(bytes,0,bytes.size/2)
                    out.fd.sync()
                }
                throw java.io.IOException("simulated crash during metadata receipt write")
            })
            check(runCatching { j.commit(1) }.exceptionOrNull()?.message=="LAB_MULTI_RECEIPT_WRITE_HOLD")
            check(f.readBytes().contentEquals(original))
            check(File(d,"part_000001.commit").exists())
            reject { LabMultiPartProof(d,id).recover() }
            reject { LabMultiPartProof(d,id).commit(1) }
        }
        case("exclusive receipt already existing cannot be replaced") { d,id,j ->
            val source=wav(d,1,48000,1)
            val original=source.readBytes()
            val receipt=j.commit(1)
            val f=File(d,"part_000001.commit")
            val bytes=f.readBytes()
            reject { j.commit(1) }
            check(f.readBytes().contentEquals(bytes) && source.readBytes().contentEquals(original))
            check(LabMultiPartProof(d,id).recover().single()==receipt)
        }
        case("verified playback requires full committed SHA and exact raw payload") { d,id,_ ->
            LabMultiPartSink(d,id,12,3,{true}).use { s ->
                s.accept(ByteArray(28){(it+1).toByte()});s.finish(false)
            }
            val j=LabMultiPartProof(d,id)
            val r=j.recoverSnapshot()
            check(r.receipts.size==2 && !r.finished)
            val first=r.receipts.first()
            val f=j.verifiedWav(1,first.sha)
            val old=f.readBytes()
            check(f.name=="part_000001.wav" && first.sha.length==64)
            reject { j.verifiedWav(1,"0".repeat(64)) }
            reject { j.verifiedWav(3,first.sha) }
            File(d,"part_000001_inflight.pcm").writeBytes(ByteArray(12){0})
            reject { j.verifiedWav(1,first.sha) }
            check(f.readBytes().contentEquals(old))
            check(File(d,"part_000003_inflight.pcm").length()==4L)
        }
        case("two committed prefix plus storage fault and restart preserves bytes") { d,id,_ ->
            var space=true
            lateinit var prior:List<LabMultiPartProof.Receipt>
            val original=mutableMapOf<String,ByteArray>()
            LabMultiPartSink(d,id,12,3,{space}).use { s ->
                s.accept(ByteArray(28){(it+1).toByte()})
                prior=LabMultiPartProof(d,id).recover()
                d.listFiles()!!.forEach{original[it.name]=it.readBytes()}
                space=false;reject{s.accept(ByteArray(4){7})}
            }
            val recovered=LabMultiPartProof(d,id).recoverSnapshot()
            check(recovered.receipts==prior && prior.size==2 && !recovered.finished)
            original.forEach{(name,bytes)->check(File(d,name).readBytes().contentEquals(bytes))}
            prior.forEach{LabMultiPartProof(d,id).verifiedWav(it.index,it.sha)}
            check(!File(d,"part_000003.commit").exists())
        }
        case("third receipt IO failure preserves two verified committed parts") { d,id,_ ->
            LabMultiPartSink(d,id,12,3,{true}).use { s ->
                s.accept(ByteArray(24){(it+1).toByte()});s.finish(false)
            }
            val prior=LabMultiPartProof(d,id).recoverSnapshot()
            check(prior.receipts.size==2 && !prior.finished)
            val third=wav(d,3,6,7)
            File(d,"part_000003_inflight.pcm").writeBytes(ByteArray(12){7})
            val original=d.listFiles()!!.associate { it.name to it.readBytes() }
            val failed=LabMultiPartProof(d,id,{_,_->throw java.io.IOException("injected third receipt failure")})
            check(runCatching{failed.commit(3)}.exceptionOrNull()?.message=="LAB_MULTI_RECEIPT_WRITE_HOLD")
            val reopened=LabMultiPartProof(d,id)
            check(reopened.recoverSnapshot()==prior)
            prior.receipts.forEach{reopened.verifiedWav(it.index,it.sha)}
            reject{reopened.verifiedWav(3,prior.receipts.last().sha)}
            check(!File(d,"part_000003.commit").exists() && !File(d,"finished_v1.txt").exists())
            original.forEach{(name,bytes)->check(File(d,name).readBytes().contentEquals(bytes))}
            check(third.exists())
            val torn=LabMultiPartProof(d,id,{dest,bytes->
                check(dest.createNewFile())
                FileOutputStream(dest).use{out->out.write(bytes,0,bytes.size/2);out.fd.sync()}
                throw java.io.IOException("injected torn third receipt")
            })
            check(runCatching{torn.commit(3)}.exceptionOrNull()?.message=="LAB_MULTI_RECEIPT_WRITE_HOLD")
            val afterTorn=LabMultiPartProof(d,id)
            reject{afterTorn.recoverSnapshot()}
            reject{afterTorn.commit(3)}
            original.forEach{(name,bytes)->check(File(d,name).readBytes().contentEquals(bytes))}
            check(File(d,"part_000003.commit").exists() && !File(d,"finished_v1.txt").exists())
        }
        case("local manifest binds real sealed Part bytes and PTS receipts across reopen") { d,id,_ ->
            val lifetime=UUID.randomUUID().toString()
            fun sample(frame:Long,recorder:String=lifetime):LabDLongPts.Sample {
                val ns=100000000000L+frame*62500L
                return LabDLongPts.Sample(frame,frame,ns-100000L,ns,
                    LabDLongPts.Observation(id.toString(),recorder,ns,ns+1000L,ns,ns+2000L))
            }
            check(LabDLongPts.manifestState(d,emptyList(),emptyList(),false)=="LOCAL_MANIFEST_ABSENT_NOT_VERIFIED")
            LabDLongPts.beginManifest(d,lifetime)
            reject{LabDLongPts.beginManifest(d,lifetime)}
            check(LabDLongPts.manifestState(d,emptyList(),emptyList(),false)=="LOCAL_MANIFEST_UNSEALED_NOT_VERIFIED")
            LabMultiPartSink(d,id,12,3,{true}).use { sink ->
                sink.accept(ByteArray(28){(it+1).toByte()});sink.finish(true)
            }
            val proof=LabMultiPartProof(d,id)
            val parts=proof.recoverSnapshot()
            check(parts.finished&&parts.receipts.size==3)
            parts.receipts.forEach{proof.verifyRaw(it)}
            fun records()=LabMultiPartProof(d,id).recoverSnapshot().receipts.map{
                "${it.index}:${it.start}:${it.end}:${it.bytes}:${it.sha}"
            }
            LabDLongPts.publish(d,1,sample(1L))
            LabDLongPts.publish(d,2,sample(14L))
            val pts=LabDLongPts.read(d)
            check(LabDLongPts.manifestState(d,pts,records(),true)=="LOCAL_MANIFEST_MISSING_NOT_VERIFIED")
            check(LabDLongPts.manifestState(d,pts,records(),true,true)=="LOCAL_MANIFEST_MATCH_NOT_ATTESTED")
            val files=d.listFiles()!!.associate{it.name to it.readBytes()}
            check(LabDLongPts.manifestState(d,LabDLongPts.read(d),records(),true)=="LOCAL_MANIFEST_MATCH_NOT_ATTESTED")
            reject{LabDLongPts.manifestState(d,pts,records(),true,true)}
            reject{LabDLongPts.manifestState(d,listOf(sample(1L,UUID.randomUUID().toString())),records(),true)}
            reject{LabDLongPts.manifestState(d,pts.take(1),records(),true)}
            reject{LabDLongPts.manifestState(d,pts,records().reversed(),true)}
            reject{LabDLongPts.manifestState(d,pts,records(),false)}
            files.forEach{(n,b)->check(File(d,n).readBytes().contentEquals(b))}
            // A syntactically valid changed PTS receipt is caught by the final digest.
            val receipt=File(d,"longpts_000002.receipt")
            val original=receipt.readBytes()
            val changed=receipt.readText().replace("v2\t14\t14\t","v2\t14\t15\t")
            check(changed!=receipt.readText());receipt.writeText(changed)
            reject{LabDLongPts.manifestState(d,LabDLongPts.read(d),records(),true)}
            check(receipt.readText()==changed)
            receipt.writeBytes(original) // fixture only
            val start=File(d,"capture_session_v1.txt")
            check(start.renameTo(File(d,"fixture-start.txt")))
            reject{LabDLongPts.manifestState(d,pts,records(),true)}
        }
        case("interrupted multi-Part prefix retains unsealed manifest state and raw tail") { d,id,_ ->
            val lifetime=UUID.randomUUID().toString()
            LabDLongPts.beginManifest(d,lifetime)
            var space=true
            LabMultiPartSink(d,id,12,3,{space}).use { sink ->
                sink.accept(ByteArray(28){it.toByte()})
                space=false;reject{sink.accept(ByteArray(4){7})}
            }
            val proof=LabMultiPartProof(d,id)
            val prefix=proof.recoverSnapshot()
            check(!prefix.finished&&prefix.receipts.size==2)
            prefix.receipts.forEach{proof.verifyRaw(it)}
            val records=prefix.receipts.map{"${it.index}:${it.start}:${it.end}:${it.bytes}:${it.sha}"}
            val original=d.listFiles()!!.associate{it.name to it.readBytes()}
            check(LabDLongPts.manifestState(d,emptyList(),records,false)=="LOCAL_MANIFEST_UNSEALED_NOT_VERIFIED")
            reject{LabDLongPts.manifestState(d,emptyList(),records,false,true)}
            check(!File(d,"capture_manifest_v1.txt").exists())
            check(File(d,"part_000003_inflight.pcm").length()==4L)
            original.forEach{(n,b)->check(File(d,n).readBytes().contentEquals(b))}
        }
        println("LAB_D_LONG_LOCAL_MANIFEST_HOST_PASS")
        println("HOST_REGRESSION=$count/$count PASS")
    } finally { base.deleteRecursively() }
}
