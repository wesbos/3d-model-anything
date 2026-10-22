package com.wesbos.housecapture.ui.theme

import androidx.compose.material3.MaterialTheme
import androidx.compose.material3.lightColorScheme
import androidx.compose.runtime.Composable
import androidx.compose.ui.graphics.Color

private val FieldworkColors = lightColorScheme(
    primary = Fieldwork.orange,
    onPrimary = Color.White,
    primaryContainer = Fieldwork.orange,
    onPrimaryContainer = Color.White,
    secondary = Fieldwork.secondary,
    onSecondary = Color.White,
    background = Fieldwork.paper,
    onBackground = Fieldwork.ink,
    surface = Fieldwork.paper,
    onSurface = Fieldwork.ink,
    surfaceVariant = Fieldwork.paper,
    onSurfaceVariant = Fieldwork.secondary,
    surfaceContainer = Fieldwork.paper,
    surfaceContainerHigh = Fieldwork.paper,
    surfaceContainerHighest = Fieldwork.paper,
    outline = Fieldwork.rule,
    outlineVariant = Fieldwork.rule,
    error = Fieldwork.orange,
)

/** The app is always Fieldwork paper, like the iPhone app; no dark or dynamic colours. */
@Composable
fun FieldworkTheme(content: @Composable () -> Unit) {
    MaterialTheme(colorScheme = FieldworkColors, content = content)
}
