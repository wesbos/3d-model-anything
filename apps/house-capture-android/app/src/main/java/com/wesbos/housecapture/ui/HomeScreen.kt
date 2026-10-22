package com.wesbos.housecapture.ui

import androidx.compose.foundation.clickable
import androidx.compose.foundation.layout.Arrangement
import androidx.compose.foundation.layout.Box
import androidx.compose.foundation.layout.Column
import androidx.compose.foundation.layout.PaddingValues
import androidx.compose.foundation.layout.Row
import androidx.compose.foundation.layout.Spacer
import androidx.compose.foundation.layout.fillMaxSize
import androidx.compose.foundation.layout.fillMaxWidth
import androidx.compose.foundation.layout.height
import androidx.compose.foundation.layout.padding
import androidx.compose.foundation.lazy.LazyColumn
import androidx.compose.foundation.lazy.LazyRow
import androidx.compose.foundation.lazy.items
import androidx.compose.foundation.text.KeyboardOptions
import androidx.compose.material.icons.Icons
import androidx.compose.material.icons.filled.Add
import androidx.compose.material.icons.outlined.Delete
import androidx.compose.material3.AlertDialog
import androidx.compose.material3.CircularProgressIndicator
import androidx.compose.material3.ExtendedFloatingActionButton
import androidx.compose.material3.Icon
import androidx.compose.material3.IconButton
import androidx.compose.material3.MaterialTheme
import androidx.compose.material3.OutlinedTextField
import androidx.compose.material3.Scaffold
import androidx.compose.material3.SuggestionChip
import androidx.compose.material3.Text
import androidx.compose.material3.TextButton
import androidx.compose.runtime.Composable
import androidx.compose.runtime.getValue
import androidx.compose.runtime.mutableIntStateOf
import androidx.compose.runtime.mutableStateOf
import androidx.compose.runtime.produceState
import androidx.compose.runtime.remember
import androidx.compose.runtime.rememberCoroutineScope
import androidx.compose.runtime.saveable.rememberSaveable
import androidx.compose.runtime.setValue
import androidx.compose.ui.Alignment
import androidx.compose.ui.Modifier
import androidx.compose.ui.res.stringArrayResource
import androidx.compose.ui.res.stringResource
import androidx.compose.ui.text.font.FontFamily
import androidx.compose.ui.text.font.FontWeight
import androidx.compose.ui.text.input.ImeAction
import androidx.compose.ui.text.input.KeyboardCapitalization
import androidx.compose.ui.tooling.preview.Preview
import androidx.compose.ui.unit.dp
import com.wesbos.housecapture.R
import com.wesbos.housecapture.capture.RoomLibrary
import com.wesbos.housecapture.capture.RoomSummary
import com.wesbos.housecapture.ui.theme.Fieldwork
import com.wesbos.housecapture.ui.theme.FieldworkEyebrow
import com.wesbos.housecapture.ui.theme.FieldworkRule
import com.wesbos.housecapture.ui.theme.FieldworkTheme
import kotlinx.coroutines.Dispatchers
import kotlinx.coroutines.launch
import kotlinx.coroutines.withContext
import java.time.LocalDateTime
import java.time.format.DateTimeFormatter
import java.time.format.FormatStyle
import kotlin.math.roundToInt

/** Room library on disk plus "Scan a room". Loads off the main thread; reloads after a delete. */
@Composable
fun HomeScreen(library: RoomLibrary, onScan: (String) -> Unit, onOpen: (String) -> Unit) {
    var generation by remember { mutableIntStateOf(0) }
    val rooms by produceState<List<RoomSummary>?>(null, library, generation) {
        value = withContext(Dispatchers.IO) { runCatching { library.list() }.getOrDefault(emptyList()) }
    }
    val scope = rememberCoroutineScope()
    HomeContent(
        rooms = rooms,
        onScan = onScan,
        onOpen = onOpen,
        onDelete = { sessionId ->
            scope.launch {
                withContext(Dispatchers.IO) { runCatching { library.delete(sessionId) } }
                generation++
            }
        },
    )
}

@Composable
fun HomeContent(
    rooms: List<RoomSummary>?,
    onScan: (String) -> Unit,
    onOpen: (String) -> Unit,
    onDelete: (String) -> Unit,
) {
    var naming by rememberSaveable { mutableStateOf(false) }
    var deleting by remember { mutableStateOf<RoomSummary?>(null) }

    Scaffold(
        containerColor = Fieldwork.paper,
        floatingActionButton = {
            ExtendedFloatingActionButton(
                text = { Text(stringResource(R.string.scan_a_room)) },
                icon = { Icon(Icons.Filled.Add, contentDescription = null) },
                onClick = { naming = true },
                containerColor = Fieldwork.orange,
                contentColor = Fieldwork.paper,
            )
        },
    ) { padding ->
        LazyColumn(
            Modifier.fillMaxSize(),
            contentPadding = PaddingValues(
                start = 20.dp,
                end = 20.dp,
                top = padding.calculateTopPadding() + 24.dp,
                bottom = padding.calculateBottomPadding() + 96.dp,
            ),
        ) {
            item {
                FieldworkEyebrow(stringResource(R.string.home_eyebrow))
                Text(
                    stringResource(R.string.app_title),
                    style = MaterialTheme.typography.headlineMedium,
                    fontWeight = FontWeight.SemiBold,
                    color = Fieldwork.ink,
                    modifier = Modifier.padding(top = 4.dp, bottom = 20.dp),
                )
                FieldworkRule()
            }
            when {
                rooms == null -> item {
                    Box(Modifier.fillMaxWidth().padding(32.dp), contentAlignment = Alignment.Center) {
                        CircularProgressIndicator(color = Fieldwork.orange)
                    }
                }
                rooms.isEmpty() -> item {
                    Column(Modifier.padding(vertical = 24.dp)) {
                        Text(stringResource(R.string.home_empty_title), style = MaterialTheme.typography.titleMedium, color = Fieldwork.ink)
                        Spacer(Modifier.height(6.dp))
                        Text(stringResource(R.string.home_empty_body), style = MaterialTheme.typography.bodyMedium, color = Fieldwork.secondary)
                    }
                }
                else -> items(rooms, key = { it.sessionId }) { room ->
                    RoomRow(room, onOpen = { onOpen(room.sessionId) }, onDelete = { deleting = room })
                    FieldworkRule()
                }
            }
        }
    }

    if (naming) {
        NameRoomDialog(
            existing = rooms.orEmpty().size,
            onDismiss = { naming = false },
            onStart = { name -> naming = false; onScan(name) },
        )
    }

    deleting?.let { room ->
        AlertDialog(
            onDismissRequest = { deleting = null },
            title = { Text(stringResource(R.string.delete_title, room.name)) },
            text = { Text(stringResource(R.string.delete_body)) },
            confirmButton = {
                TextButton(onClick = { deleting = null; onDelete(room.sessionId) }) {
                    Text(stringResource(R.string.delete), color = Fieldwork.orange)
                }
            },
            dismissButton = {
                TextButton(onClick = { deleting = null }) { Text(stringResource(R.string.cancel), color = Fieldwork.ink) }
            },
            containerColor = Fieldwork.paper,
        )
    }
}

@Composable
private fun RoomRow(room: RoomSummary, onOpen: () -> Unit, onDelete: () -> Unit) {
    Row(
        Modifier.fillMaxWidth().clickable(onClick = onOpen).padding(vertical = 14.dp),
        verticalAlignment = Alignment.CenterVertically,
    ) {
        Column(Modifier.weight(1f), verticalArrangement = Arrangement.spacedBy(2.dp)) {
            Text(room.name, style = MaterialTheme.typography.titleMedium, color = Fieldwork.ink)
            Text(sessionLabel(room.sessionId), style = MaterialTheme.typography.bodySmall, color = Fieldwork.secondary)
            Text(
                roomCounts(room),
                style = MaterialTheme.typography.labelSmall,
                fontFamily = FontFamily.Monospace,
                color = Fieldwork.secondary,
            )
        }
        IconButton(onClick = onDelete) {
            Icon(Icons.Outlined.Delete, contentDescription = stringResource(R.string.delete_room, room.name), tint = Fieldwork.secondary)
        }
    }
}

@Composable
private fun NameRoomDialog(existing: Int, onDismiss: () -> Unit, onStart: (String) -> Unit) {
    val suggestions = stringArrayResource(R.array.room_name_suggestions)
    val fallback = stringResource(R.string.room_n, existing + 1)
    var name by rememberSaveable { mutableStateOf(suggestions.getOrElse(existing) { fallback }) }
    AlertDialog(
        onDismissRequest = onDismiss,
        title = { Text(stringResource(R.string.name_title)) },
        text = {
            Column(verticalArrangement = Arrangement.spacedBy(12.dp)) {
                OutlinedTextField(
                    value = name,
                    onValueChange = { name = it },
                    singleLine = true,
                    label = { Text(stringResource(R.string.room_name)) },
                    keyboardOptions = KeyboardOptions(capitalization = KeyboardCapitalization.Sentences, imeAction = ImeAction.Done),
                    modifier = Modifier.fillMaxWidth(),
                )
                LazyRow(horizontalArrangement = Arrangement.spacedBy(8.dp)) {
                    items(suggestions.toList()) { suggestion ->
                        SuggestionChip(onClick = { name = suggestion }, label = { Text(suggestion) })
                    }
                }
            }
        },
        confirmButton = {
            TextButton(onClick = { onStart(name.trim()) }, enabled = name.isNotBlank()) {
                Text(stringResource(R.string.start_scan), color = if (name.isNotBlank()) Fieldwork.orange else Fieldwork.rule)
            }
        },
        dismissButton = {
            TextButton(onClick = onDismiss) { Text(stringResource(R.string.cancel), color = Fieldwork.ink) }
        },
        containerColor = Fieldwork.paper,
    )
}

/** Session folders are named "yyyy-MM-dd HH.mm.ss"; show them as a local date, or as-is if that ever changes. */
private val sessionFormat = DateTimeFormatter.ofPattern("yyyy-MM-dd HH.mm.ss")

internal fun sessionLabel(sessionId: String): String =
    runCatching {
        LocalDateTime.parse(sessionId, sessionFormat)
            .format(DateTimeFormatter.ofLocalizedDateTime(FormatStyle.MEDIUM, FormatStyle.SHORT))
    }.getOrDefault(sessionId)

@Composable
internal fun roomCounts(room: RoomSummary): String {
    val counts = stringResource(R.string.room_counts, room.photos, room.depthFrames, room.walls)
    val coverage = room.coverage ?: return counts
    return counts + " · " + stringResource(R.string.photo_detail_percent, (coverage * 100).roundToInt())
}

@Preview(showBackground = true, backgroundColor = 0xFFF6F2EB)
@Composable
private fun HomePreview() {
    FieldworkTheme { HomeContent(PreviewData.rooms, onScan = {}, onOpen = {}, onDelete = {}) }
}

@Preview(showBackground = true, backgroundColor = 0xFFF6F2EB)
@Composable
private fun HomeEmptyPreview() {
    FieldworkTheme { HomeContent(emptyList(), onScan = {}, onOpen = {}, onDelete = {}) }
}
