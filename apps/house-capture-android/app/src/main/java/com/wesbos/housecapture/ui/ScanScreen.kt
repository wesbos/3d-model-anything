package com.wesbos.housecapture.ui

import android.view.HapticFeedbackConstants
import androidx.activity.compose.BackHandler
import androidx.compose.foundation.BorderStroke
import androidx.compose.foundation.background
import androidx.compose.foundation.border
import androidx.compose.foundation.layout.Arrangement
import androidx.compose.foundation.layout.Box
import androidx.compose.foundation.layout.Column
import androidx.compose.foundation.layout.Row
import androidx.compose.foundation.layout.Spacer
import androidx.compose.foundation.layout.fillMaxSize
import androidx.compose.foundation.layout.fillMaxWidth
import androidx.compose.foundation.layout.padding
import androidx.compose.foundation.layout.size
import androidx.compose.foundation.layout.systemBarsPadding
import androidx.compose.foundation.layout.width
import androidx.compose.foundation.shape.CircleShape
import androidx.compose.foundation.shape.RoundedCornerShape
import androidx.compose.material.icons.Icons
import androidx.compose.material.icons.automirrored.filled.ArrowBack
import androidx.compose.material.icons.filled.CameraAlt
import androidx.compose.material3.AlertDialog
import androidx.compose.material3.CircularProgressIndicator
import androidx.compose.material3.FilledIconButton
import androidx.compose.material3.Icon
import androidx.compose.material3.IconButton
import androidx.compose.material3.IconButtonDefaults
import androidx.compose.material3.MaterialTheme
import androidx.compose.material3.Surface
import androidx.compose.material3.Text
import androidx.compose.material3.TextButton
import androidx.compose.runtime.Composable
import androidx.compose.runtime.DisposableEffect
import androidx.compose.runtime.LaunchedEffect
import androidx.compose.runtime.getValue
import androidx.compose.runtime.mutableIntStateOf
import androidx.compose.runtime.mutableStateOf
import androidx.compose.runtime.remember
import androidx.compose.runtime.setValue
import androidx.compose.ui.Alignment
import androidx.compose.ui.Modifier
import androidx.compose.ui.graphics.Color
import androidx.compose.ui.platform.LocalContext
import androidx.compose.ui.platform.LocalView
import androidx.compose.ui.res.stringResource
import androidx.compose.ui.text.font.FontFamily
import androidx.compose.ui.text.font.FontWeight
import androidx.compose.ui.text.style.TextAlign
import androidx.compose.ui.tooling.preview.Preview
import androidx.compose.ui.unit.dp
import androidx.compose.ui.unit.sp
import androidx.compose.ui.viewinterop.AndroidView
import androidx.lifecycle.Lifecycle
import androidx.lifecycle.LifecycleEventObserver
import androidx.lifecycle.compose.LocalLifecycleOwner
import androidx.lifecycle.compose.collectAsStateWithLifecycle
import androidx.lifecycle.viewmodel.compose.viewModel
import com.wesbos.housecapture.R
import com.wesbos.housecapture.capture.CaptureFactory
import com.wesbos.housecapture.capture.CaptureState
import com.wesbos.housecapture.capture.CoverageSnapshot
import com.wesbos.housecapture.capture.Phase
import com.wesbos.housecapture.capture.RoomSummary
import com.wesbos.housecapture.ui.theme.Fieldwork
import com.wesbos.housecapture.ui.theme.FieldworkButton
import com.wesbos.housecapture.ui.theme.FieldworkTheme
import kotlinx.coroutines.delay
import kotlin.math.roundToInt

/**
 * Records one room called [name]. The controller lives in a [ScanViewModel] scoped to this back-stack
 * entry, so it survives Activity recreation and is released only when the entry is popped.
 */
@Composable
fun ScanScreen(name: String, onSaved: (RoomSummary, CoverageSnapshot?) -> Unit, onExit: () -> Unit) {
    val app = LocalContext.current.applicationContext
    val model = viewModel { ScanViewModel(CaptureFactory.newController(app)) }
    ScanScreen(model, name, onSaved, onExit)
}

@Composable
fun ScanScreen(
    model: ScanViewModel,
    name: String,
    onSaved: (RoomSummary, CoverageSnapshot?) -> Unit,
    onExit: () -> Unit,
) {
    val controller = model.controller
    val captured by controller.state.collectAsStateWithLifecycle()
    val resumeError by model.resumeError.collectAsStateWithLifecycle()
    val state = resumeError?.let { captured.copy(phase = Phase.FAILED, error = it) } ?: captured
    val lifecycleOwner = LocalLifecycleOwner.current

    // A new GLSurfaceView per composition (i.e. per Activity), created before the first resume: ARCore's
    // install/update prompt needs the Activity, which the controller finds through this view's context.
    val context = LocalContext.current
    val previewView = remember(controller, context) { controller.createPreviewView(context) }

    // Resume/pause the AR session with this destination. Releasing is the ViewModel's job (onCleared).
    DisposableEffect(model, lifecycleOwner) {
        var resumed = false
        val observer = LifecycleEventObserver { _, event ->
            when (event) {
                Lifecycle.Event.ON_RESUME -> {
                    model.resume(name)
                    resumed = true
                }
                Lifecycle.Event.ON_PAUSE -> {
                    if (resumed) model.pause()
                    resumed = false
                }
                else -> {}
            }
        }
        lifecycleOwner.lifecycle.addObserver(observer)
        onDispose {
            lifecycleOwner.lifecycle.removeObserver(observer)
            if (resumed) model.pause()
        }
    }

    val view = LocalView.current
    DisposableEffect(view) {
        view.keepScreenOn = true
        onDispose { view.keepScreenOn = false }
    }

    LaunchedEffect(captured.phase, captured.lastSaved) {
        model.takeSaved(captured.phase, captured.lastSaved)?.let { onSaved(it, captured.snapshot) }
    }

    var confirmLeave by remember { mutableStateOf(false) }
    BackHandler(enabled = state.phase != Phase.FAILED) {
        if (state.phase == Phase.SCANNING) confirmLeave = true
        else if (state.phase != Phase.FINISHING) onExit()
    }

    ScanContent(
        state = state,
        name = name,
        preview = {
            AndroidView(factory = { previewView }, modifier = Modifier.fillMaxSize())
        },
        onPhoto = controller::takePhoto,
        onFinish = controller::finishRoom,
        onBack = { if (state.phase == Phase.SCANNING) confirmLeave = true else onExit() },
    )

    if (confirmLeave) {
        AlertDialog(
            onDismissRequest = { confirmLeave = false },
            title = { Text(stringResource(R.string.leave_title)) },
            text = { Text(stringResource(R.string.leave_body)) },
            confirmButton = {
                TextButton(onClick = { confirmLeave = false; controller.finishRoom() }) {
                    Text(stringResource(R.string.finish_room), color = Fieldwork.orange)
                }
            },
            dismissButton = {
                Row {
                    TextButton(onClick = { confirmLeave = false; onExit() }) {
                        Text(stringResource(R.string.leave_discard), color = Fieldwork.ink)
                    }
                    TextButton(onClick = { confirmLeave = false }) {
                        Text(stringResource(R.string.keep_scanning), color = Fieldwork.ink)
                    }
                }
            },
            containerColor = Fieldwork.paper,
        )
    }
}

@Composable
fun ScanContent(
    state: CaptureState,
    name: String,
    preview: @Composable () -> Unit,
    onPhoto: () -> Unit,
    onFinish: () -> Unit,
    onBack: () -> Unit,
) {
    val scanning = state.phase == Phase.SCANNING

    // A tick and a flash of the photo counter for every saved photo.
    val view = LocalView.current
    var flash by remember { mutableStateOf(false) }
    var lastPhotos by remember { mutableIntStateOf(state.photos) }
    LaunchedEffect(state.photos) {
        if (state.photos > lastPhotos) {
            view.performHapticFeedback(HapticFeedbackConstants.CLOCK_TICK)
            flash = true
            delay(300)
            flash = false
        }
        lastPhotos = state.photos
    }

    Box(Modifier.fillMaxSize().background(Color.Black)) {
        preview()

        Column(
            Modifier.fillMaxSize().systemBarsPadding().padding(12.dp),
            verticalArrangement = Arrangement.spacedBy(8.dp),
        ) {
            Row(verticalAlignment = Alignment.Top) {
                IconButton(
                    onClick = onBack,
                    colors = IconButtonDefaults.iconButtonColors(containerColor = Fieldwork.panel, contentColor = Fieldwork.onPanel),
                ) {
                    Icon(Icons.AutoMirrored.Filled.ArrowBack, contentDescription = stringResource(R.string.back))
                }
                Spacer(Modifier.width(8.dp))
                StatusPanel(state, name, Modifier.weight(1f))
            }
            if (state.phase == Phase.SCANNING || state.phase == Phase.STARTING) {
                Counters(state, flash)
                DepthWarning(state)
            }

            Spacer(Modifier.weight(1f))

            Row(verticalAlignment = Alignment.Bottom) {
                Surface(
                    color = Fieldwork.paper,
                    shape = RoundedCornerShape(12.dp),
                    border = BorderStroke(2.dp, Fieldwork.panel),
                    modifier = Modifier.size(176.dp),
                ) {
                    PlanCanvas(state.snapshot, Modifier.fillMaxSize())
                }
                Column(
                    Modifier.weight(1f),
                    horizontalAlignment = Alignment.CenterHorizontally,
                    verticalArrangement = Arrangement.spacedBy(12.dp),
                ) {
                    Shutter(enabled = scanning && state.tracking == "normal", onClick = onPhoto)
                    FieldworkButton(
                        text = stringResource(R.string.finish_room),
                        onClick = onFinish,
                        enabled = scanning,
                        modifier = Modifier.padding(start = 12.dp),
                    )
                }
            }
        }

        // An error before recording starts (ARCore missing or declined, camera unavailable) ends this scan.
        val startFailed = state.error != null && (state.phase == Phase.IDLE || state.phase == Phase.STARTING)
        when {
            state.phase == Phase.FAILED || startFailed -> Overlay(
                text = state.error ?: stringResource(R.string.scan_failed),
                progress = false,
                title = stringResource(R.string.scan_failed_title),
                action = stringResource(R.string.back),
                onAction = onBack,
            )
            state.phase == Phase.FINISHING || state.phase == Phase.SAVED -> Overlay(stringResource(R.string.saving_room), progress = true)
        }
    }
}

/** Solid ink panel: tracking state in large type, then the one thing to do next. */
@Composable
private fun StatusPanel(state: CaptureState, name: String, modifier: Modifier = Modifier) {
    val starting = state.phase == Phase.IDLE || state.phase == Phase.STARTING
    val ok = !starting && state.tracking == "normal"
    val hint = ScanGuide.hint(state)
    val (label, dot) = when {
        starting -> stringResource(R.string.status_starting) to Fieldwork.onPanelMuted
        ok -> stringResource(R.string.status_tracking) to Fieldwork.good
        state.tracking == "notAvailable" -> stringResource(R.string.status_lost) to Fieldwork.alert
        else -> stringResource(R.string.status_limited) to Fieldwork.orange
    }
    Surface(color = Fieldwork.panel, contentColor = Fieldwork.onPanel, shape = RoundedCornerShape(12.dp), modifier = modifier) {
        Column(Modifier.padding(horizontal = 14.dp, vertical = 10.dp), verticalArrangement = Arrangement.spacedBy(6.dp)) {
            Row(verticalAlignment = Alignment.CenterVertically) {
                Box(Modifier.size(14.dp).background(dot, CircleShape))
                Spacer(Modifier.width(8.dp))
                Text(label, fontSize = 20.sp, fontWeight = FontWeight.Bold, modifier = Modifier.weight(1f))
                Text(elapsed(state.elapsedSeconds), fontSize = 18.sp, fontFamily = FontFamily.Monospace, color = Fieldwork.onPanelMuted)
            }
            Text(
                hint.text,
                fontSize = 18.sp,
                lineHeight = 23.sp,
                fontWeight = if (hint.urgent) FontWeight.Bold else FontWeight.Medium,
                color = if (hint.urgent) Color(0xFFFFB59A) else Fieldwork.onPanel,
            )
            Text(name, fontSize = 13.sp, color = Fieldwork.onPanelMuted)
        }
    }
}

/** Photos, depth frames and photo detail as large numbers; depth turns red when it is stalled. */
@Composable
private fun Counters(state: CaptureState, flash: Boolean) {
    Row(horizontalArrangement = Arrangement.spacedBy(8.dp), modifier = Modifier.fillMaxWidth()) {
        Counter(
            stringResource(R.string.counter_photos),
            state.photos.toString(),
            Modifier.weight(1f),
            background = if (flash) Fieldwork.good else Fieldwork.panel,
        )
        Counter(
            stringResource(R.string.counter_depth),
            if (state.depthAvailable) state.depthFrames.toString() else "—",
            Modifier.weight(1f),
            background = if (state.depthStalled || (state.phase == Phase.SCANNING && !state.depthAvailable)) Fieldwork.alert else Fieldwork.panel,
        )
        Counter(
            stringResource(R.string.counter_coverage),
            state.coverage?.let { stringResource(R.string.percent, (it * 100).roundToInt()) } ?: "—",
            Modifier.weight(1f),
        )
    }
}

@Composable
private fun Counter(label: String, value: String, modifier: Modifier = Modifier, background: Color = Fieldwork.panel) {
    Surface(color = background, contentColor = Fieldwork.onPanel, shape = RoundedCornerShape(12.dp), modifier = modifier) {
        Column(Modifier.padding(horizontal = 10.dp, vertical = 6.dp), horizontalAlignment = Alignment.CenterHorizontally) {
            Text(value, fontSize = 28.sp, fontWeight = FontWeight.Bold, fontFamily = FontFamily.Monospace, maxLines = 1)
            Text(label.uppercase(), fontSize = 11.sp, letterSpacing = 1.5.sp, color = Fieldwork.onPanel.copy(alpha = 0.8f), maxLines = 1)
        }
    }
}

/** Red banner while depth is missing, with ARCore's most frequent reason in plain words. */
@Composable
private fun DepthWarning(state: CaptureState) {
    val text = when {
        state.phase != Phase.SCANNING -> null
        !state.depthAvailable -> stringResource(R.string.depth_unavailable)
        state.depthStalled && state.depthFrames == 0 -> stringResource(R.string.depth_none_yet)
        state.depthStalled -> stringResource(R.string.depth_stalled)
        else -> null
    } ?: return
    Surface(color = Fieldwork.alert, contentColor = Color.White, shape = RoundedCornerShape(12.dp), modifier = Modifier.fillMaxWidth()) {
        Column(Modifier.padding(horizontal = 14.dp, vertical = 8.dp)) {
            Text(text, fontSize = 16.sp, fontWeight = FontWeight.Bold)
            state.depthProblem?.let { Text(it, fontSize = 14.sp) }
        }
    }
}

@Composable
private fun Shutter(enabled: Boolean, onClick: () -> Unit) {
    Box(
        Modifier.size(76.dp).border(4.dp, Color.White.copy(alpha = if (enabled) 1f else 0.4f), CircleShape),
        contentAlignment = Alignment.Center,
    ) {
        FilledIconButton(
            onClick = onClick,
            enabled = enabled,
            modifier = Modifier.size(60.dp),
            colors = IconButtonDefaults.filledIconButtonColors(
                containerColor = Color.White,
                contentColor = Fieldwork.ink,
                disabledContainerColor = Color.White.copy(alpha = 0.4f),
                disabledContentColor = Fieldwork.ink.copy(alpha = 0.4f),
            ),
        ) {
            Icon(Icons.Filled.CameraAlt, contentDescription = stringResource(R.string.take_photo))
        }
    }
}

@Composable
private fun Overlay(
    text: String,
    progress: Boolean,
    title: String? = null,
    action: String? = null,
    onAction: () -> Unit = {},
) {
    Box(Modifier.fillMaxSize().background(Color.Black.copy(alpha = 0.55f)), contentAlignment = Alignment.Center) {
        Surface(color = Fieldwork.paper, shape = RoundedCornerShape(16.dp), modifier = Modifier.padding(32.dp)) {
            Column(
                Modifier.padding(24.dp),
                horizontalAlignment = Alignment.CenterHorizontally,
                verticalArrangement = Arrangement.spacedBy(12.dp),
            ) {
                if (progress) CircularProgressIndicator(color = Fieldwork.orange)
                if (title != null) Text(title, style = MaterialTheme.typography.titleMedium, color = Fieldwork.ink)
                Text(text, style = MaterialTheme.typography.bodyMedium, color = Fieldwork.ink, textAlign = TextAlign.Center)
                if (action != null) FieldworkButton(action, onAction, modifier = Modifier.fillMaxWidth())
            }
        }
    }
}

private fun elapsed(seconds: Int) = "%d:%02d".format(seconds / 60, seconds % 60)

@Preview(widthDp = 390, heightDp = 844)
@Composable
private fun ScanPreview() {
    FieldworkTheme { ScanScreen(ScanViewModel(PreviewCapture()), "Living room", onSaved = { _, _ -> }, onExit = {}) }
}

@Preview(widthDp = 390, heightDp = 844)
@Composable
private fun ScanLimitedPreview() {
    FieldworkTheme {
        ScanContent(PreviewData.limited, "Kitchen", preview = { Box(Modifier.fillMaxSize().background(Color.DarkGray)) }, onPhoto = {}, onFinish = {}, onBack = {})
    }
}

@Preview(widthDp = 390, heightDp = 844)
@Composable
private fun ScanDepthStalledPreview() {
    FieldworkTheme {
        ScanContent(PreviewData.depthStalled, "Office", preview = { Box(Modifier.fillMaxSize().background(Color.DarkGray)) }, onPhoto = {}, onFinish = {}, onBack = {})
    }
}

@Preview(widthDp = 390, heightDp = 844)
@Composable
private fun ScanFailedPreview() {
    FieldworkTheme {
        ScanContent(
            PreviewData.scanning.copy(phase = Phase.FAILED, error = "This device does not support ARCore."),
            "Kitchen",
            preview = {},
            onPhoto = {},
            onFinish = {},
            onBack = {},
        )
    }
}
