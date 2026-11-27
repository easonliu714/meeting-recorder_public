package com.example.meeting_recorder.public_lab_v44.groq_stt_lab

import java.nio.file.Files

object LabDPtsEvidenceHostTest {
    @JvmStatic fun main(args:Array<String>) {
        val ns=100000000000L
        val a=LabDPtsEvidence.Sample(16000,14000,ns,ns+1000000)
        val b=LabDPtsEvidence.Sample(96000,94000,ns+5000000000L,ns+5001000000L)
        val valid=listOf(a,b)
        check(LabDPtsEvidence.inspect(valid)=="HARDWARE_PTS_OBSERVED_NOT_GAP_FREE")
        check(LabDPtsEvidence.inspect(emptyList())=="NOT_VERIFIED")
        check(LabDPtsEvidence.inspect(listOf(a))=="NOT_VERIFIED")
        check(LabDPtsEvidence.inspect(listOf(a,b.copy(hardwareFrames=null,hardwareNs=null)))=="NOT_VERIFIED")
        check(LabDPtsEvidence.inspect(listOf(a,b.copy(hardwareFrames=13000)))=="LAB_D_PTS_RESET_OR_STALL_HOLD")
        check(LabDPtsEvidence.inspect(listOf(a,b.copy(hardwareFrames=49000)))=="LAB_D_PTS_UNALIGNED_HOLD")
        fun rejects(v:List<LabDPtsEvidence.Sample>) {
            var failed=false
            try{LabDPtsEvidence.inspect(v)}catch(_:IllegalStateException){failed=true}
            check(failed)
        }
        rejects(listOf(a,b.copy(capturedFrames=16000)))
        rejects(listOf(a.copy(hardwareNs=null)))
        rejects(listOf(a.copy(hardwareFrames=-2)))
        rejects(listOf(a.copy(observedMonoNs=-1)))
        rejects(listOf(a.copy(hardwareNs=ns+9000000000L)))
        val folder=Files.createTempDirectory("lab-d-pts-host").toFile()
        try {
            LabDPtsEvidence.publish(folder,1,a)
            LabDPtsEvidence.publish(folder,2,b)
            check(LabDPtsEvidence.read(folder)==valid)
            var duplicate=false
            try{LabDPtsEvidence.publish(folder,2,b)}catch(_:IllegalStateException){duplicate=true}
            check(duplicate)
            run {
                val part=java.io.File(folder,"pts_000002.receipt")
                part.writeText("partial")
                var corruption=false
                try{LabDPtsEvidence.read(folder)}catch(_:IllegalStateException){corruption=true}
                check(corruption)
            }
        } finally {folder.listFiles()?.forEach{it.delete()};folder.delete()}
        println("LAB_D_HARDWARE_PTS_HOST_SUITE_PASS cases=13")
    }
}
