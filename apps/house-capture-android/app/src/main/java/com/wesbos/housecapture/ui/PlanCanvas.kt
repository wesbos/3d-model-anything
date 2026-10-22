package com.wesbos.housecapture.ui

import androidx.compose.foundation.Canvas
import androidx.compose.foundation.layout.Box
import androidx.compose.foundation.layout.fillMaxSize
import androidx.compose.foundation.layout.padding
import androidx.compose.material3.MaterialTheme
import androidx.compose.material3.Text
import androidx.compose.runtime.Composable
import androidx.compose.ui.Alignment
import androidx.compose.ui.Modifier
import androidx.compose.ui.geometry.CornerRadius
import androidx.compose.ui.geometry.Offset
import androidx.compose.ui.geometry.Size
import androidx.compose.ui.graphics.Color
import androidx.compose.ui.graphics.Path
import androidx.compose.ui.graphics.PointMode
import androidx.compose.ui.graphics.StrokeCap
import androidx.compose.ui.graphics.drawscope.DrawScope
import androidx.compose.ui.graphics.drawscope.Fill
import androidx.compose.ui.graphics.drawscope.Stroke
import androidx.compose.ui.res.stringResource
import androidx.compose.ui.text.TextMeasurer
import androidx.compose.ui.text.TextStyle
import androidx.compose.ui.text.drawText
import androidx.compose.ui.text.font.FontFamily
import androidx.compose.ui.text.font.FontWeight
import androidx.compose.ui.text.rememberTextMeasurer
import androidx.compose.ui.text.style.TextAlign
import androidx.compose.ui.tooling.preview.Preview
import androidx.compose.ui.unit.dp
import androidx.compose.ui.unit.sp
import com.wesbos.housecapture.R
import com.wesbos.housecapture.capture.CoverageSnapshot
import com.wesbos.housecapture.capture.RoomReport
import com.wesbos.housecapture.ui.theme.Fieldwork
import com.wesbos.housecapture.ui.theme.FieldworkTheme
import java.util.Locale
import kotlin.math.cos
import kotlin.math.max
import kotlin.math.min
import kotlin.math.sin

/** Coverage cells are 10 cm voxels (CoverageGrid). */
private const val CELL_METERS = 0.1f

/** Smallest area shown, so the first few cells don't fill the card. */
private const val MIN_SPAN_METERS = 3f

/**
 * Top-down plan of a scan in progress: world x to the right, world z down (looking at the floor from
 * above). Seen cells are grey, photographed cells green, walls (vertical ARCore planes) thick blue,
 * floors light blue outlines, the camera path a thin ink trail, photos pink, and the camera an orange
 * dot with an arrow along its heading. Scales to fit whatever has been seen so far; the bar is 1 m.
 */
@Composable
fun PlanCanvas(snapshot: CoverageSnapshot?, modifier: Modifier = Modifier) {
    val measurer = rememberTextMeasurer()
    Box(modifier, contentAlignment = Alignment.Center) {
        if (snapshot == null) {
            Text(
                stringResource(R.string.plan_empty),
                modifier = Modifier.padding(8.dp),
                color = Fieldwork.secondary,
                style = MaterialTheme.typography.labelMedium,
                textAlign = TextAlign.Center,
            )
        } else {
            Canvas(Modifier.fillMaxSize().padding(8.dp)) { drawPlan(snapshot, measurer) }
        }
    }
}

/**
 * The saved room from its room JSON: floor outline, walls with their lengths in meters, and the
 * position of every photo. Same axes as [PlanCanvas].
 */
@Composable
fun RoomPlanCanvas(report: RoomReport, modifier: Modifier = Modifier) {
    val measurer = rememberTextMeasurer()
    Box(modifier, contentAlignment = Alignment.Center) {
        if (report.walls.isEmpty() && report.photoPositions.isEmpty()) {
            Text(
                stringResource(R.string.plan_no_walls),
                modifier = Modifier.padding(8.dp),
                color = Fieldwork.secondary,
                style = MaterialTheme.typography.labelMedium,
                textAlign = TextAlign.Center,
            )
        } else {
            Canvas(Modifier.fillMaxSize().padding(12.dp)) { drawRoom(report, measurer) }
        }
    }
}

private class PlanBounds(minSpan: Float) {
    var minX = Float.MAX_VALUE
    var maxX = -Float.MAX_VALUE
    var minZ = Float.MAX_VALUE
    var maxZ = -Float.MAX_VALUE
    private val span = minSpan

    fun include(xz: FloatArray) {
        var i = 0
        while (i + 1 < xz.size) {
            minX = min(minX, xz[i]); maxX = max(maxX, xz[i])
            minZ = min(minZ, xz[i + 1]); maxZ = max(maxZ, xz[i + 1])
            i += 2
        }
    }

    /** Pads to at least the minimum span; call after every include. */
    fun finish() {
        if (minX > maxX) { minX = 0f; maxX = 0f; minZ = 0f; maxZ = 0f }
        val padX = max(0f, span - (maxX - minX)) / 2
        val padZ = max(0f, span - (maxZ - minZ)) / 2
        minX -= padX; maxX += padX
        minZ -= padZ; maxZ += padZ
    }
}

/** World x/z → canvas pixels, fitting [bounds] centered with [margin] pixels to spare. */
private class PlanProjection(bounds: PlanBounds, width: Float, height: Float, margin: Float) {
    val scale: Float
    private val originX: Float
    private val originZ: Float

    init {
        val spanX = bounds.maxX - bounds.minX + CELL_METERS
        val spanZ = bounds.maxZ - bounds.minZ + CELL_METERS
        scale = min((width - 2 * margin) / spanX, (height - 2 * margin) / spanZ)
        originX = (width - (bounds.maxX - bounds.minX) * scale) / 2 - bounds.minX * scale
        originZ = (height - (bounds.maxZ - bounds.minZ) * scale) / 2 - bounds.minZ * scale
    }

    fun at(x: Float, z: Float) = Offset(originX + x * scale, originZ + z * scale)
    fun points(xz: FloatArray) = List(xz.size / 2) { at(xz[2 * it], xz[2 * it + 1]) }
}

private fun DrawScope.drawPlan(snapshot: CoverageSnapshot, measurer: TextMeasurer) {
    val bounds = PlanBounds(MIN_SPAN_METERS)
    bounds.include(floatArrayOf(snapshot.cameraX, snapshot.cameraZ))
    bounds.include(snapshot.seen)
    bounds.include(snapshot.photographed)
    bounds.include(snapshot.photoPositions)
    bounds.include(snapshot.path)
    snapshot.planes.forEach { bounds.include(it) }
    bounds.finish()
    val proj = PlanProjection(bounds, size.width, size.height, margin = 4.dp.toPx())

    val cell = max(2f, CELL_METERS * proj.scale)
    drawPoints(proj.points(snapshot.seen), PointMode.Points, Fieldwork.seen, strokeWidth = cell, cap = StrokeCap.Square)
    drawPoints(proj.points(snapshot.photographed), PointMode.Points, Fieldwork.photographed, strokeWidth = cell, cap = StrokeCap.Square)

    // floors: thin outlines; walls (2-point segments): thick
    for (polygon in snapshot.planes) {
        if (polygon.size < 4) continue
        if (polygon.size == 4) {
            drawLine(Fieldwork.plane, proj.at(polygon[0], polygon[1]), proj.at(polygon[2], polygon[3]), strokeWidth = 4.dp.toPx(), cap = StrokeCap.Round)
        } else {
            drawPath(polygonPath(proj, polygon), Fieldwork.plane.copy(alpha = 0.5f), style = Stroke(width = 1.dp.toPx()))
        }
    }

    if (snapshot.path.size >= 4) {
        val trail = Path()
        val first = proj.at(snapshot.path[0], snapshot.path[1])
        trail.moveTo(first.x, first.y)
        for (i in 2 until snapshot.path.size - 1 step 2) {
            val p = proj.at(snapshot.path[i], snapshot.path[i + 1])
            trail.lineTo(p.x, p.y)
        }
        drawPath(trail, Fieldwork.ink.copy(alpha = 0.55f), style = Stroke(width = 1.5.dp.toPx(), cap = StrokeCap.Round))
    }

    val photoRadius = 3.dp.toPx()
    for (p in proj.points(snapshot.photoPositions)) drawCircle(Fieldwork.photo, photoRadius, p)

    drawCamera(proj.at(snapshot.cameraX, snapshot.cameraZ), snapshot.headingRadians)
    drawScaleBar(proj.scale, measurer)
}

private fun DrawScope.drawRoom(report: RoomReport, measurer: TextMeasurer) {
    val bounds = PlanBounds(2f)
    report.walls.forEach { bounds.include(it) }
    bounds.include(report.floor)
    bounds.include(report.photoPositions)
    bounds.finish()
    val proj = PlanProjection(bounds, size.width, size.height, margin = 20.dp.toPx())

    if (report.floor.size >= 6) {
        val floor = polygonPath(proj, report.floor)
        drawPath(floor, Fieldwork.seen.copy(alpha = 0.25f), style = Fill)
    }
    for (p in proj.points(report.photoPositions)) drawCircle(Fieldwork.photo, 3.5.dp.toPx(), p)

    val label = TextStyle(fontSize = 13.sp, fontFamily = FontFamily.Monospace, fontWeight = FontWeight.SemiBold, color = Fieldwork.ink)
    report.walls.forEachIndexed { i, w ->
        val a = proj.at(w[0], w[1])
        val b = proj.at(w[2], w[3])
        val low = report.wallConfidence.getOrNull(i) == "low"
        drawLine(if (low) Fieldwork.plane.copy(alpha = 0.55f) else Fieldwork.plane, a, b, strokeWidth = 5.dp.toPx(), cap = StrokeCap.Round)
    }
    // lengths after all walls so no wall covers a label
    report.walls.forEach { w ->
        val a = proj.at(w[0], w[1])
        val b = proj.at(w[2], w[3])
        val text = measurer.measure(String.format(Locale.ROOT, "%.2f m", ScanQuality.length(w)), label)
        val mid = Offset((a.x + b.x) / 2, (a.y + b.y) / 2)
        val topLeft = Offset(
            (mid.x - text.size.width / 2f).coerceIn(0f, max(0f, size.width - text.size.width)),
            (mid.y - text.size.height / 2f).coerceIn(0f, max(0f, size.height - text.size.height)),
        )
        val pad = 3.dp.toPx()
        drawRoundRect(
            Fieldwork.paper,
            topLeft = Offset(topLeft.x - pad, topLeft.y - pad / 2),
            size = Size(text.size.width + 2 * pad, text.size.height + pad),
            cornerRadius = CornerRadius(pad, pad),
        )
        drawText(text, topLeft = topLeft)
    }
    drawScaleBar(proj.scale, measurer)
}

private fun polygonPath(proj: PlanProjection, polygon: FloatArray): Path {
    val path = Path()
    val first = proj.at(polygon[0], polygon[1])
    path.moveTo(first.x, first.y)
    for (i in 2 until polygon.size - 1 step 2) {
        val p = proj.at(polygon[i], polygon[i + 1])
        path.lineTo(p.x, p.y)
    }
    path.close()
    return path
}

/** Orange dot with a white rim and an arrow along the heading. */
private fun DrawScope.drawCamera(camera: Offset, heading: Float) {
    val tick = 18.dp.toPx()
    val tip = Offset(camera.x + cos(heading) * tick, camera.y + sin(heading) * tick)
    drawLine(Color.White, camera, tip, strokeWidth = 6.dp.toPx(), cap = StrokeCap.Round)
    drawLine(Fieldwork.orange, camera, tip, strokeWidth = 3.dp.toPx(), cap = StrokeCap.Round)
    drawCircle(Color.White, 8.dp.toPx(), camera)
    drawCircle(Fieldwork.orange, 6.dp.toPx(), camera)
}

/** A 1 m bar in the bottom-left corner. */
private fun DrawScope.drawScaleBar(scale: Float, measurer: TextMeasurer) {
    val meter = scale
    if (meter < 8f || meter > size.width * 0.8f) return
    val y = size.height - 2.dp.toPx()
    val x = 2.dp.toPx()
    drawLine(Fieldwork.ink, Offset(x, y), Offset(x + meter, y), strokeWidth = 2.dp.toPx(), cap = StrokeCap.Square)
    val text = measurer.measure("1 m", TextStyle(fontSize = 10.sp, fontFamily = FontFamily.Monospace, color = Fieldwork.ink))
    drawText(text, topLeft = Offset(x, y - 3.dp.toPx() - text.size.height))
}

@Preview(widthDp = 240, heightDp = 240, showBackground = true, backgroundColor = 0xFFF6F2EB)
@Composable
private fun PlanCanvasPreview() {
    FieldworkTheme { PlanCanvas(PreviewData.snapshot, Modifier.fillMaxSize()) }
}

@Preview(widthDp = 360, heightDp = 360, showBackground = true, backgroundColor = 0xFFF6F2EB)
@Composable
private fun RoomPlanCanvasPreview() {
    FieldworkTheme { RoomPlanCanvas(PreviewData.report, Modifier.fillMaxSize()) }
}
