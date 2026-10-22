package com.wesbos.housecapture.ui

import android.Manifest
import android.content.Intent
import android.content.pm.PackageManager
import android.net.Uri
import android.provider.Settings
import androidx.activity.compose.rememberLauncherForActivityResult
import androidx.activity.result.contract.ActivityResultContracts
import androidx.compose.material3.AlertDialog
import androidx.compose.material3.Text
import androidx.compose.material3.TextButton
import androidx.compose.runtime.Composable
import androidx.compose.runtime.getValue
import androidx.compose.runtime.mutableStateMapOf
import androidx.compose.runtime.mutableStateOf
import androidx.compose.runtime.remember
import androidx.compose.runtime.saveable.rememberSaveable
import androidx.compose.runtime.setValue
import androidx.compose.ui.platform.LocalContext
import androidx.compose.ui.res.stringResource
import androidx.core.content.ContextCompat
import androidx.navigation.NavType
import androidx.navigation.compose.NavHost
import androidx.navigation.compose.composable
import androidx.navigation.compose.rememberNavController
import androidx.navigation.navArgument
import com.wesbos.housecapture.R
import com.wesbos.housecapture.capture.CaptureFactory
import com.wesbos.housecapture.capture.CoverageSnapshot
import com.wesbos.housecapture.ui.theme.Fieldwork

private const val HOME = "home"
private const val SCAN = "scan/{name}"
private const val ROOM = "room/{session}"

/**
 * Home ⇄ scan ⇄ room. The camera permission is asked for when a scan starts, not at launch, so the
 * library and sharing work without it. ARCore install/support problems surface in the scan screen.
 */
@Composable
fun AppNavHost() {
    val nav = rememberNavController()
    val context = LocalContext.current
    val library = remember { CaptureFactory.library(context.applicationContext) }
    // The coverage plan of a room scanned in this run, shown on its room screen. Not persisted.
    val snapshots = remember { mutableStateMapOf<String, CoverageSnapshot>() }

    var pendingName by rememberSaveable { mutableStateOf<String?>(null) }
    var cameraDenied by remember { mutableStateOf(false) }
    val openScan = { name: String -> nav.navigate("scan/${Uri.encode(name)}") }
    val cameraPermission = rememberLauncherForActivityResult(ActivityResultContracts.RequestPermission()) { granted ->
        val name = pendingName
        pendingName = null
        if (!granted) cameraDenied = true
        else if (name != null) openScan(name)
    }

    NavHost(nav, startDestination = HOME) {
        composable(HOME) {
            HomeScreen(
                library = library,
                onScan = { name ->
                    if (ContextCompat.checkSelfPermission(context, Manifest.permission.CAMERA) == PackageManager.PERMISSION_GRANTED) {
                        openScan(name)
                    } else {
                        pendingName = name
                        cameraPermission.launch(Manifest.permission.CAMERA)
                    }
                },
                onOpen = { sessionId -> nav.navigate("room/${Uri.encode(sessionId)}") },
            )
        }
        composable(SCAN, arguments = listOf(navArgument("name") { type = NavType.StringType })) { entry ->
            ScanScreen(
                name = entry.arguments?.getString("name").orEmpty(),
                onSaved = { summary, snapshot ->
                    if (snapshot != null) snapshots[summary.sessionId] = snapshot
                    nav.navigate("room/${Uri.encode(summary.sessionId)}") { popUpTo(HOME) }
                },
                onExit = { nav.popBackStack(HOME, inclusive = false) },
            )
        }
        composable(ROOM, arguments = listOf(navArgument("session") { type = NavType.StringType })) { entry ->
            val sessionId = entry.arguments?.getString("session").orEmpty()
            RoomScreen(
                library = library,
                sessionId = sessionId,
                snapshot = snapshots[sessionId],
                onDone = { nav.popBackStack(HOME, inclusive = false) },
            )
        }
    }

    if (cameraDenied) {
        AlertDialog(
            onDismissRequest = { cameraDenied = false },
            title = { Text(stringResource(R.string.camera_title)) },
            text = { Text(stringResource(R.string.camera_body)) },
            confirmButton = {
                TextButton(onClick = {
                    cameraDenied = false
                    context.startActivity(
                        Intent(Settings.ACTION_APPLICATION_DETAILS_SETTINGS, Uri.fromParts("package", context.packageName, null)),
                    )
                }) { Text(stringResource(R.string.open_settings), color = Fieldwork.orange) }
            },
            dismissButton = {
                TextButton(onClick = { cameraDenied = false }) { Text(stringResource(R.string.cancel), color = Fieldwork.ink) }
            },
            containerColor = Fieldwork.paper,
        )
    }
}
