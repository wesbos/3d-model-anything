package com.wesbos.housecapture.bundle

import android.content.Context
import android.content.Intent
import android.net.Uri
import androidx.core.content.FileProvider
import java.io.File
import java.util.UUID
import java.util.zip.CRC32
import java.util.zip.ZipEntry
import java.util.zip.ZipOutputStream

/** Zips a session folder into cacheDir/share/ (manifest.json at the zip root) for the share sheet. */
object ZipShare {
    private const val DAY_MS = 86_400_000L
    /** already-compressed files are stored, everything else deflated */
    private val STORED = setOf("jpg", "f16z")

    fun zip(context: Context, folder: File, name: String): File {
        val root = File(context.cacheDir, "share")
        root.mkdirs()
        // Unique directories keep two exports from deleting each other's files;
        // anything older than a day is an abandoned share.
        val cutoff = System.currentTimeMillis() - DAY_MS
        root.listFiles().orEmpty().filter { it.lastModified() < cutoff }.forEach { it.deleteRecursively() }
        val dir = File(root, UUID.randomUUID().toString())
        dir.mkdirs()
        val safe = name.replace('/', '-').replace(':', '-').ifBlank { "Room" }
        val dest = File(dir, "$safe.zip")
        try {
            ZipOutputStream(dest.outputStream().buffered()).use { zip ->
                folder.walkTopDown().filter { it.isFile && !it.name.endsWith(".tmp") }.sortedBy { it.path }.forEach { file ->
                    val entry = ZipEntry(file.relativeTo(folder).invariantSeparatorsPath)
                    if (file.extension.lowercase() in STORED) {
                        entry.method = ZipEntry.STORED
                        entry.size = file.length()
                        entry.compressedSize = file.length()
                        entry.crc = crc32(file)
                    }
                    zip.putNextEntry(entry)
                    file.inputStream().use { it.copyTo(zip) }
                    zip.closeEntry()
                }
            }
        } catch (e: Exception) {
            dir.deleteRecursively()
            throw e
        }
        return dest
    }

    fun uri(context: Context, file: File): Uri =
        FileProvider.getUriForFile(context, "${context.packageName}.files", file)

    /** ACTION_SEND for a zip Uri from [uri]; wrap it in Intent.createChooser to show the share sheet. */
    fun sendIntent(uri: Uri): Intent = Intent(Intent.ACTION_SEND)
        .setType("application/zip")
        .putExtra(Intent.EXTRA_STREAM, uri)
        .addFlags(Intent.FLAG_GRANT_READ_URI_PERMISSION)

    private fun crc32(file: File): Long {
        val crc = CRC32()
        val buffer = ByteArray(64 * 1024)
        file.inputStream().use { input ->
            while (true) {
                val n = input.read(buffer)
                if (n < 0) break
                crc.update(buffer, 0, n)
            }
        }
        return crc.value
    }
}
