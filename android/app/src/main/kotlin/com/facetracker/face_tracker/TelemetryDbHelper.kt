package com.facetracker.face_tracker

import android.content.ContentValues
import android.content.Context
import android.database.sqlite.SQLiteDatabase
import android.database.sqlite.SQLiteOpenHelper
import org.json.JSONArray
import org.json.JSONObject

class TelemetryDbHelper(context: Context) : SQLiteOpenHelper(context, DATABASE_NAME, null, DATABASE_VERSION) {

    companion object {
        const val DATABASE_NAME = "telemetry.db"
        const val DATABASE_VERSION = 1

        const val TABLE_SESSIONS = "focus_sessions"
        const val TABLE_TELEMETRY = "telemetry_logs"
    }

    override fun onCreate(db: SQLiteDatabase) {
        db.execSQL("""
            CREATE TABLE $TABLE_SESSIONS (
                id TEXT PRIMARY KEY,
                subject_tag TEXT,
                target_exam TEXT,
                activity_type TEXT,
                chapter_name TEXT,
                lecture_number INTEGER,
                started_at TEXT,
                ended_at TEXT,
                synced INTEGER DEFAULT 0
            )
        """)

            CREATE TABLE $TABLE_TELEMETRY (
                id INTEGER PRIMARY KEY AUTOINCREMENT,
                session_id TEXT,
                timestamp TEXT,
                focus_score INTEGER,
                predicted_state TEXT,
                active_package TEXT,
                w_yaw REAL,
                w_pitch REAL,
                w_eyes REAL,
                thermal_throttled INTEGER DEFAULT 0,
                synced INTEGER DEFAULT 0
            )
        """)
    }

    override fun onUpgrade(db: SQLiteDatabase, oldVersion: Int, newVersion: Int) {
        db.execSQL("DROP TABLE IF EXISTS $TABLE_TELEMETRY")
        db.execSQL("DROP TABLE IF EXISTS $TABLE_SESSIONS")
        onCreate(db)
    }

    fun startSession(sessionId: String, subject: String, exam: String, activity: String, chapter: String, lecture: Int, startedAt: String) {
        val db = writableDatabase
        val values = ContentValues().apply {
            put("id", sessionId)
            put("subject_tag", subject)
            put("target_exam", exam)
            put("activity_type", activity)
            put("chapter_name", chapter)
            put("lecture_number", lecture)
            put("started_at", startedAt)
            put("synced", 0)
        }
        db.insertWithOnConflict(TABLE_SESSIONS, null, values, SQLiteDatabase.CONFLICT_IGNORE)
    }

    fun stopSession(sessionId: String, endedAt: String) {
        val db = writableDatabase
        val values = ContentValues().apply {
            put("ended_at", endedAt)
            put("synced", 0) // mark as unsynced so the end time gets pushed
        }
        db.update(TABLE_SESSIONS, values, "id = ?", arrayOf(sessionId))
    }

    fun insertTelemetry(sessionId: String, timestamp: String, score: Int, state: String, pkg: String, yaw: Double, pitch: Double, eyes: Double, thermalThrottled: Boolean = false) {
        val db = writableDatabase
        val values = ContentValues().apply {
            put("session_id", sessionId)
            put("timestamp", timestamp)
            put("focus_score", score)
            put("predicted_state", state)
            put("active_package", pkg)
            put("w_yaw", yaw)
            put("w_pitch", pitch)
            put("w_eyes", eyes)
            put("thermal_throttled", if (thermalThrottled) 1 else 0)
            put("synced", 0)
        }
        db.insert(TABLE_TELEMETRY, null, values)
    }

    fun getUnsyncedTelemetry(): Pair<JSONArray, List<Int>> {
        val db = readableDatabase
        val cursor = db.query(TABLE_TELEMETRY, null, "synced = 0", null, null, null, "timestamp ASC", "500") // batch of 500
        val batch = JSONArray()
        val ids = mutableListOf<Int>()

        while (cursor.moveToNext()) {
            val id = cursor.getInt(cursor.getColumnIndexOrThrow("id"))
            val sessionId = cursor.getString(cursor.getColumnIndexOrThrow("session_id"))
            
            // Need session info to enrich the payload because our current `bulk_insert_telemetry` expects session details on every row
            // We'll fetch it per row for simplicity, or we can just send it and let the RPC handle it.
            // Wait, the RPC `bulk_insert_telemetry` expects: session_id, subject_tag, target_exam, activity_type, chapter_name, lecture_number, etc.
            val sessionCursor = db.query(TABLE_SESSIONS, null, "id = ?", arrayOf(sessionId), null, null, null)
            var subject = ""
            var exam = ""
            var activity = ""
            var chapter = ""
            var lecture = 0
            var startedAt = ""
            if (sessionCursor.moveToFirst()) {
                subject = sessionCursor.getString(sessionCursor.getColumnIndexOrThrow("subject_tag")) ?: ""
                exam = sessionCursor.getString(sessionCursor.getColumnIndexOrThrow("target_exam")) ?: ""
                activity = sessionCursor.getString(sessionCursor.getColumnIndexOrThrow("activity_type")) ?: ""
                chapter = sessionCursor.getString(sessionCursor.getColumnIndexOrThrow("chapter_name")) ?: ""
                lecture = sessionCursor.getInt(sessionCursor.getColumnIndexOrThrow("lecture_number"))
                startedAt = sessionCursor.getString(sessionCursor.getColumnIndexOrThrow("started_at")) ?: ""
            }
            sessionCursor.close()

            val obj = JSONObject().apply {
                put("session_id", sessionId)
                put("subject_tag", subject)
                put("target_exam", exam)
                put("activity_type", activity)
                put("chapter_name", chapter)
                put("lecture_number", lecture)
                put("started_at", startedAt)
                put("timestamp", cursor.getString(cursor.getColumnIndexOrThrow("timestamp")))
                put("focus_score", cursor.getInt(cursor.getColumnIndexOrThrow("focus_score")))
                put("predicted_state", cursor.getString(cursor.getColumnIndexOrThrow("predicted_state")))
                put("active_package", cursor.getString(cursor.getColumnIndexOrThrow("active_package")))
                put("w_yaw", cursor.getDouble(cursor.getColumnIndexOrThrow("w_yaw")))
                put("w_pitch", cursor.getDouble(cursor.getColumnIndexOrThrow("w_pitch")))
                put("w_eyes", cursor.getDouble(cursor.getColumnIndexOrThrow("w_eyes")))
                val throttledIdx = cursor.getColumnIndex("thermal_throttled")
                val isThrottled = if (throttledIdx != -1) cursor.getInt(throttledIdx) == 1 else false
                put("thermal_throttled", isThrottled)
            }
            batch.put(obj)
            ids.add(id)
        }
        cursor.close()
        return Pair(batch, ids)
    }

    fun markTelemetrySynced(ids: List<Int>) {
        if (ids.isEmpty()) return
        val db = writableDatabase
        val idList = ids.joinToString(",")
        db.execSQL("UPDATE $TABLE_TELEMETRY SET synced = 1 WHERE id IN ($idList)")
    }

    fun getUnsyncedSessionEnds(): List<Pair<String, String>> {
        val db = readableDatabase
        val cursor = db.query(TABLE_SESSIONS, arrayOf("id", "ended_at"), "synced = 0 AND ended_at IS NOT NULL", null, null, null, null)
        val list = mutableListOf<Pair<String, String>>()
        while (cursor.moveToNext()) {
            val id = cursor.getString(0)
            val endedAt = cursor.getString(1)
            list.add(Pair(id, endedAt))
        }
        cursor.close()
        return list
    }

    fun markSessionEndSynced(ids: List<String>) {
        if (ids.isEmpty()) return
        val db = writableDatabase
        val idList = ids.joinToString(",") { "'$it'" }
        db.execSQL("UPDATE $TABLE_SESSIONS SET synced = 1 WHERE id IN ($idList)")
    }
}
