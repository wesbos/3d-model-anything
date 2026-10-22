package com.wesbos.housecapture.ui.theme

import androidx.compose.foundation.BorderStroke
import androidx.compose.foundation.background
import androidx.compose.foundation.layout.Box
import androidx.compose.foundation.layout.PaddingValues
import androidx.compose.foundation.layout.fillMaxWidth
import androidx.compose.foundation.layout.height
import androidx.compose.foundation.layout.heightIn
import androidx.compose.foundation.shape.RoundedCornerShape
import androidx.compose.material3.Button
import androidx.compose.material3.ButtonDefaults
import androidx.compose.material3.MaterialTheme
import androidx.compose.material3.OutlinedButton
import androidx.compose.material3.Text
import androidx.compose.runtime.Composable
import androidx.compose.ui.Modifier
import androidx.compose.ui.graphics.Color
import androidx.compose.ui.text.TextStyle
import androidx.compose.ui.text.font.FontFamily
import androidx.compose.ui.text.font.FontWeight
import androidx.compose.ui.unit.dp
import androidx.compose.ui.unit.sp

/** Fieldwork: paper, ink, ruled sections and one purposeful accent (mirrors FieldworkDesign.swift). */
object Fieldwork {
    val paper = Color(0xFFF6F2EB)
    val ink = Color(0xFF1F211F)
    val secondary = Color(0xFF63635C)
    val orange = Color(0xFFC2471F)
    val rule = Color(0xFFCFC9BF)

    // Scan overlays: solid ink panels with white text stay legible over any camera image.
    val panel = ink
    val onPanel = Color.White
    val onPanelMuted = Color(0xFFBDB8AE)
    val good = Color(0xFF4CAF5E)
    val alert = Color(0xFFD32F2F)

    // Plan canvas colours, matching the meaning of the iPhone preview.
    val seen = Color(0xFFB4ADA1)
    val photographed = Color(0xFF3F8F4E)
    val plane = Color(0xFF3B6FB6)
    val photo = Color(0xFFD9468F)

    val buttonShape = RoundedCornerShape(12.dp)
}

@Composable
fun FieldworkButton(
    text: String,
    onClick: () -> Unit,
    modifier: Modifier = Modifier,
    filled: Boolean = true,
    enabled: Boolean = true,
) {
    val content: @Composable () -> Unit = { Text(text, fontWeight = FontWeight.SemiBold) }
    val sized = modifier.fillMaxWidth().heightIn(min = 52.dp)
    val padding = PaddingValues(horizontal = 12.dp)
    if (filled) {
        Button(
            onClick = onClick,
            modifier = sized,
            enabled = enabled,
            shape = Fieldwork.buttonShape,
            contentPadding = padding,
            colors = ButtonDefaults.buttonColors(
                containerColor = Fieldwork.orange,
                contentColor = Color.White,
                disabledContainerColor = Fieldwork.orange.copy(alpha = 0.4f),
                disabledContentColor = Color.White,
            ),
        ) { content() }
    } else {
        OutlinedButton(
            onClick = onClick,
            modifier = sized,
            enabled = enabled,
            shape = Fieldwork.buttonShape,
            contentPadding = padding,
            border = BorderStroke(1.dp, Fieldwork.orange.copy(alpha = if (enabled) 1f else 0.4f)),
            colors = ButtonDefaults.outlinedButtonColors(
                contentColor = Fieldwork.orange,
                disabledContentColor = Fieldwork.orange.copy(alpha = 0.4f),
            ),
        ) { content() }
    }
}

@Composable
fun FieldworkEyebrow(text: String, modifier: Modifier = Modifier, color: Color = Fieldwork.secondary) {
    Text(
        text.uppercase(),
        modifier = modifier,
        color = color,
        style = MaterialTheme.typography.labelSmall.merge(
            TextStyle(fontFamily = FontFamily.Monospace, letterSpacing = 2.sp),
        ),
    )
}

@Composable
fun FieldworkRule(modifier: Modifier = Modifier) {
    Box(modifier.fillMaxWidth().height(0.5.dp).background(Fieldwork.rule))
}
