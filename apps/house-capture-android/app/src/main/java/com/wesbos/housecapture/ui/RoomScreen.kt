package com.wesbos.housecapture.ui

import android.content.ClipData
import android.content.Intent
import android.net.Uri
import android.text.format.Formatter
import androidx.compose.foundation.BorderStroke
import androidx.compose.foundation.layout.Arrangement
import androidx.compose.foundation.layout.Box
import androidx.compose.foundation.layout.Column
import androidx.compose.foundation.layout.Row
import androidx.compose.foundation.layout.Spacer
import androidx.compose.foundation.layout.aspectRatio
import androidx.compose.foundation.layout.fillMaxSize
import androidx.compose.foundation.layout.fillMaxWidth
import androidx.compose.foundation.layout.height
import androidx.compose.foundation.layout.heightIn
import androidx.compose.foundation.layout.padding
import androidx.compose.foundation.layout.systemBarsPadding
import androidx.compose.foundation.layout.width
import androidx.compose.foundation.rememberScrollState
import androidx.compose.foundation.shape.RoundedCornerShape
import androidx.compose.foundation.verticalScroll
import androidx.compose.material3.CircularProgressIndicator
import androidx.compose.material3.MaterialTheme
import androidx.compose.material3.Surface
import androidx.compose.material3.Text
import androidx.compose.runtime.Composable
import androidx.compose.runtime.getValue
import androidx.compose.runtime.mutableStateOf
import androidx.compose.runtime.produceState
import androidx.compose.runtime.remember
import androidx.compose.runtime.rememberCoroutineScope
import androidx.compose.runtime.setValue
import androidx.compose.ui.Alignment
import androidx.compose.ui.Modifier
import androidx.compose.ui.graphics.Color
import androidx.compose.ui.platform.LocalContext
import androidx.compose.ui.res.stringResource
import androidx.compose.ui.text.font.FontFamily
import androidx.compose.ui.text.font.FontWeight
import androidx.compose.ui.tooling.preview.Preview
import androidx.compose.ui.unit.dp
import androidx.compose.ui.unit.sp
import com.wesbos.housecapture.R
import com.wesbos.housecapture.capture.CoverageSnapshot
import com.wesbos.housecapture.capture.RoomLibrary
import com.wesbos.housecapture.capture.RoomReport
import com.wesbos.housecapture.ui.theme.Fieldwork
import com.wesbos.housecapture.ui.theme.FieldworkButton
import com.wesbos.housecapture.ui.theme.FieldworkEyebrow
import com.wesbos.housecapture.ui.theme.FieldworkRule
import com.wesbos.housecapture.ui.theme.FieldworkTheme
import kotlinx.coroutines.Dispatchers
import kotlinx.coroutines.launch
import kotlinx.coroutines.withContext
import java.util.Locale
import kotlin.math.roundToInt

private sealed interface Loaded {
    data object Loading : Loaded
    data object Missing : Loaded
    data class Room(val report: RoomReport) : Loaded
}

/** A saved room: what was recorded, the plan of the scan when it was just captured, and sharing. */
@Composable
fun RoomScreen(library: RoomLibrary, sessionId: String, snapshot: CoverageSnapshot?, onDone: () -> Unit) {
    val context = LocalContext.current
    val scope = rememberCoroutineScope()
    val loaded by produceState<Loaded>(Loaded.Loading, library, sessionId) {
        value = withContext(Dispatchers.IO) {
            runCatching { library.report(sessionId) }.getOrNull()
        }?.let { Loaded.Room(it) } ?: Loaded.Missing
    }
    var sharing by remember { mutableStateOf(false) }
    var shareError by remember { mutableStateOf<String?>(null) }
    val chooserTitle = stringResource(R.string.share_room)

    when (val room = loaded) {
        Loaded.Loading -> Box(Modifier.fillMaxSize(), contentAlignment = Alignment.Center) {
            CircularProgressIndicator(color = Fieldwork.orange)
        }
        Loaded.Missing -> RoomMissing(onDone)
        is Loaded.Room -> RoomContent(
            report = room.report,
            snapshot = snapshot,
            sharing = sharing,
            shareError = shareError,
            onShare = {
                sharing = true
                shareError = null
                scope.launch {
                    val result = withContext(Dispatchers.IO) { runCatching { library.shareZip(sessionId) } }
                    sharing = false
                    result
                        .onSuccess { uri ->
                            val stream = Uri.parse(uri)
                            val send = Intent(Intent.ACTION_SEND)
                                .setType("application/zip")
                                .putExtra(Intent.EXTRA_STREAM, stream)
                                .addFlags(Intent.FLAG_GRANT_READ_URI_PERMISSION)
                            send.clipData = ClipData.newRawUri(room.report.summary.name, stream)
                            context.startActivity(Intent.createChooser(send, chooserTitle))
                        }
                        .onFailure { shareError = it.message ?: it.javaClass.simpleName }
                }
            },
            onDone = onDone,
        )
    }
}

@Composable
fun RoomContent(
    report: RoomReport,
    snapshot: CoverageSnapshot?,
    sharing: Boolean,
    shareError: String?,
    onShare: () -> Unit,
    onDone: () -> Unit,
) {
    val context = LocalContext.current
    val room = report.summary
    val verdict = remember(report) { ScanQuality.assess(report) }
    val size = remember(report) { ScanQuality.roomSize(report.walls) }
    Column(
        Modifier
            .fillMaxSize()
            .systemBarsPadding()
            .verticalScroll(rememberScrollState())
            .padding(horizontal = 20.dp, vertical = 24.dp),
        verticalArrangement = Arrangement.spacedBy(12.dp),
    ) {
        FieldworkEyebrow(sessionLabel(room.sessionId))
        Text(room.name, style = MaterialTheme.typography.headlineMedium, fontWeight = FontWeight.SemiBold, color = Fieldwork.ink)

        VerdictCard(verdict, size)

        FieldworkButton(
            text = stringResource(if (sharing) R.string.preparing_zip else R.string.share_room),
            onClick = onShare,
            enabled = !sharing,
            modifier = Modifier.heightIn(min = 60.dp),
        )
        if (shareError != null) {
            Text(stringResource(R.string.share_failed, shareError), style = MaterialTheme.typography.bodySmall, color = Fieldwork.orange)
        }
        FieldworkRule()

        FieldworkEyebrow(stringResource(R.string.room_plan_title))
        Surface(
            color = Fieldwork.paper,
            shape = RoundedCornerShape(12.dp),
            border = BorderStroke(0.5.dp, Fieldwork.rule),
            modifier = Modifier.fillMaxWidth().aspectRatio(1f),
        ) {
            RoomPlanCanvas(report, Modifier.fillMaxSize())
        }
        Text(
            stringResource(if (report.synthesized) R.string.room_plan_legend_synth else R.string.room_plan_legend),
            style = MaterialTheme.typography.bodySmall,
            color = Fieldwork.secondary,
        )
        FieldworkRule()

        Fact(stringResource(R.string.fact_photos), room.photos.toString())
        Fact(stringResource(R.string.fact_depth), if (report.depthMode == "DISABLED") stringResource(R.string.not_supported) else room.depthFrames.toString())
        Fact(
            stringResource(R.string.fact_photo_detail),
            room.coverage?.let { stringResource(R.string.percent, (it * 100).roundToInt()) } ?: stringResource(R.string.not_measured),
        )
        report.seconds?.let { Fact(stringResource(R.string.fact_scan_time), duration(it)) }
        report.trackingLostSeconds?.let { Fact(stringResource(R.string.fact_tracking_lost), duration(it)) }
        Fact(stringResource(if (report.synthesized) R.string.fact_walls_synth else R.string.fact_walls), report.walls.size.toString())
        Fact(
            stringResource(R.string.fact_room_size),
            size?.let { String.format(Locale.ROOT, "%.1f × %.1f m", it.first, it.second) } ?: stringResource(R.string.not_measured),
        )
        Fact(stringResource(R.string.fact_size), Formatter.formatShortFileSize(context, room.bytes))
        if (report.depthStats.isNotEmpty()) {
            Text(
                stringResource(R.string.depth_stats, report.depthStats.entries.joinToString(", ") { "${it.key} ${it.value}" }),
                style = MaterialTheme.typography.bodySmall,
                fontFamily = FontFamily.Monospace,
                color = Fieldwork.secondary,
            )
        }

        if (snapshot != null) {
            FieldworkRule()
            FieldworkEyebrow(stringResource(R.string.coverage_plan_title))
            Surface(
                color = Fieldwork.paper,
                shape = RoundedCornerShape(12.dp),
                border = BorderStroke(0.5.dp, Fieldwork.rule),
                modifier = Modifier.fillMaxWidth().aspectRatio(1.4f),
            ) {
                PlanCanvas(snapshot, Modifier.fillMaxSize())
            }
            Text(stringResource(R.string.plan_legend), style = MaterialTheme.typography.bodySmall, color = Fieldwork.secondary)
        }

        FieldworkRule()
        FieldworkEyebrow(stringResource(R.string.next_title))
        Step(1, stringResource(R.string.next_share))
        Step(2, stringResource(R.string.next_synthesize))
        Step(3, stringResource(R.string.next_skill))

        FieldworkRule()
        FieldworkEyebrow(stringResource(R.string.fact_folder))
        Text(room.folderPath, style = MaterialTheme.typography.bodySmall, fontFamily = FontFamily.Monospace, color = Fieldwork.secondary)

        Spacer(Modifier.height(8.dp))
        FieldworkButton(text = stringResource(R.string.done), onClick = onDone, filled = false)
    }
}

/** Solid, colored by the verdict: the level, the room size and every warning. */
@Composable
private fun VerdictCard(verdict: ScanQuality.Verdict, size: Pair<Float, Float>?) {
    val color = when (verdict.level) {
        ScanQuality.Level.GOOD -> Fieldwork.photographed
        ScanQuality.Level.USABLE -> Fieldwork.orange
        ScanQuality.Level.POOR -> Fieldwork.alert
    }
    Surface(color = color, contentColor = Color.White, shape = RoundedCornerShape(12.dp), modifier = Modifier.fillMaxWidth()) {
        Column(Modifier.padding(16.dp), verticalArrangement = Arrangement.spacedBy(6.dp)) {
            Row(verticalAlignment = Alignment.CenterVertically) {
                Text(verdict.level.label, fontSize = 22.sp, fontWeight = FontWeight.Bold, modifier = Modifier.weight(1f))
                if (size != null) {
                    Text(String.format(Locale.ROOT, "%.1f × %.1f m", size.first, size.second), fontSize = 18.sp, fontFamily = FontFamily.Monospace)
                }
            }
            if (verdict.warnings.isEmpty()) {
                Text(stringResource(R.string.verdict_no_warnings), fontSize = 15.sp)
            }
            for (w in verdict.warnings) Text("• $w", fontSize = 15.sp, lineHeight = 20.sp)
        }
    }
}

@Composable
private fun Step(n: Int, text: String) {
    Row(verticalAlignment = Alignment.Top) {
        Text("$n.", style = MaterialTheme.typography.bodyMedium, fontWeight = FontWeight.Bold, color = Fieldwork.orange, modifier = Modifier.width(24.dp))
        Text(text, style = MaterialTheme.typography.bodyMedium, color = Fieldwork.ink)
    }
}

@Composable
private fun Fact(label: String, value: String) {
    Row(Modifier.fillMaxWidth(), verticalAlignment = Alignment.CenterVertically) {
        Text(label, style = MaterialTheme.typography.bodyMedium, color = Fieldwork.secondary, modifier = Modifier.weight(1f))
        Text(value, style = MaterialTheme.typography.bodyMedium, fontFamily = FontFamily.Monospace, color = Fieldwork.ink)
    }
}

private fun duration(seconds: Double): String {
    val s = seconds.roundToInt()
    return if (s < 60) "$s s" else "%d:%02d".format(s / 60, s % 60)
}

@Composable
private fun RoomMissing(onDone: () -> Unit) {
    Column(
        Modifier.fillMaxSize().systemBarsPadding().padding(24.dp),
        verticalArrangement = Arrangement.spacedBy(16.dp, Alignment.CenterVertically),
    ) {
        Text(stringResource(R.string.room_missing), style = MaterialTheme.typography.bodyMedium, color = Fieldwork.ink)
        FieldworkButton(text = stringResource(R.string.done), onClick = onDone, filled = false)
    }
}

@Preview(widthDp = 390, heightDp = 1000, showBackground = true, backgroundColor = 0xFFF6F2EB)
@Composable
private fun RoomPreview() {
    FieldworkTheme {
        RoomContent(PreviewData.report, PreviewData.snapshot, sharing = false, shareError = null, onShare = {}, onDone = {})
    }
}

@Preview(widthDp = 390, heightDp = 844, showBackground = true, backgroundColor = 0xFFF6F2EB)
@Composable
private fun RoomNoPlanPreview() {
    FieldworkTheme {
        RoomContent(PreviewData.poorReport, null, sharing = true, shareError = null, onShare = {}, onDone = {})
    }
}
