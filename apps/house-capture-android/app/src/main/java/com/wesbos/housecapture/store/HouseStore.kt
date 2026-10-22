package com.wesbos.housecapture.store

import android.content.Context
import com.wesbos.housecapture.bundle.RoomReports
import com.wesbos.housecapture.bundle.ScanBundle
import com.wesbos.housecapture.bundle.ZipShare
import com.wesbos.housecapture.capture.RoomLibrary
import com.wesbos.housecapture.capture.RoomReport
import com.wesbos.housecapture.capture.RoomSummary
import java.io.File

/** The room library: every session folder under filesDir/Houses/android/sessions/, one room each. */
class HouseStore(context: Context) : RoomLibrary {
    private val context = context.applicationContext

    override fun list(): List<RoomSummary> = ScanBundle.all(context).mapNotNull { it.summary() }

    override fun report(sessionId: String): RoomReport? {
        val bundle = bundle(sessionId)
        if (!bundle.dir.isDirectory) return null
        val summary = bundle.summary() ?: return null
        return RoomReports.read(bundle, summary)
    }

    override fun delete(sessionId: String) {
        bundle(sessionId).dir.deleteRecursively()
    }

    /**
     * An unfinished scan is completed first (its checkpointed plane layout becomes the room), so
     * every shared zip converts with the skill's scripts. Throws if there is nothing usable to share.
     */
    override fun shareZip(sessionId: String): String {
        val bundle = bundle(sessionId)
        val manifest = bundle.completeUnfinished() ?: bundle.readManifest()
        val room = manifest?.rooms?.firstOrNull()
        check(room != null) { "This scan stopped before anything was recorded, so there is nothing to share." }
        val name = room.name
        val zip = ZipShare.zip(context, bundle.dir, name)
        return ZipShare.uri(context, zip).toString()
    }

    /** Session ids come from the UI: only plain folder names inside the sessions folder. */
    private fun bundle(sessionId: String): ScanBundle {
        val root = ScanBundle.sessionsDir(context).canonicalFile
        val dir = File(root, sessionId).canonicalFile
        require(sessionId.isNotBlank() && dir.parentFile == root) { "Unknown session $sessionId" }
        return ScanBundle(dir)
    }
}
