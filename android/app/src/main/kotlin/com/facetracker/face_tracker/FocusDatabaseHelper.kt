package com.facetracker.face_tracker

import android.content.ContentValues
import android.content.Context
import android.database.sqlite.SQLiteDatabase
import android.database.sqlite.SQLiteOpenHelper

class FocusDatabaseHelper(context: Context) : SQLiteOpenHelper(context, DATABASE_NAME, null, DATABASE_VERSION) {

    companion object {
        private const val DATABASE_NAME = "focus_telemetry.db"
        private const val DATABASE_VERSION = 1

        const val TABLE_NAME = "local_focus_telemetry"
        const val COLUMN_ID = "id"
        const val COLUMN_TIMESTAMP = "timestamp"
        const val COLUMN_SCORE = "focus_score"
        const val COLUMN_STATE = "state"
        const val COLUMN_APP = "active_app"
        const val COLUMN_SUBJECT = "subject"
    }

    override fun onCreate(db: SQLiteDatabase) {
        val createTable = ("CREATE TABLE $TABLE_NAME ("
                + "$COLUMN_ID INTEGER PRIMARY KEY AUTOINCREMENT,"
                + "$COLUMN_TIMESTAMP TEXT,"
                + "$COLUMN_SCORE INTEGER,"
                + "$COLUMN_STATE TEXT,"
                + "$COLUMN_APP TEXT,"
                + "$COLUMN_SUBJECT TEXT)")
        db.execSQL(createTable)
    }

    override fun onUpgrade(db: SQLiteDatabase, oldVersion: Int, newVersion: Int) {
        db.execSQL("DROP TABLE IF EXISTS $TABLE_NAME")
        onCreate(db)
    }

    fun insertRecord(timestamp: String, score: Int, state: String, app: String, subject: String) {
        val db = this.writableDatabase
        val values = ContentValues().apply {
            put(COLUMN_TIMESTAMP, timestamp)
            put(COLUMN_SCORE, score)
            put(COLUMN_STATE, state)
            put(COLUMN_APP, app)
            put(COLUMN_SUBJECT, subject)
        }
        db.insert(TABLE_NAME, null, values)
        db.close()
    }

    fun getAllRecords(): List<Map<String, Any>> {
        val records = mutableListOf<Map<String, Any>>()
        val db = this.readableDatabase
        val cursor = db.rawQuery("SELECT * FROM $TABLE_NAME", null)
        if (cursor.moveToFirst()) {
            do {
                val map = mutableMapOf<String, Any>()
                map[COLUMN_ID] = cursor.getInt(cursor.getColumnIndexOrThrow(COLUMN_ID))
                map[COLUMN_TIMESTAMP] = cursor.getString(cursor.getColumnIndexOrThrow(COLUMN_TIMESTAMP))
                map[COLUMN_SCORE] = cursor.getInt(cursor.getColumnIndexOrThrow(COLUMN_SCORE))
                map[COLUMN_STATE] = cursor.getString(cursor.getColumnIndexOrThrow(COLUMN_STATE))
                map[COLUMN_APP] = cursor.getString(cursor.getColumnIndexOrThrow(COLUMN_APP))
                map[COLUMN_SUBJECT] = cursor.getString(cursor.getColumnIndexOrThrow(COLUMN_SUBJECT))
                records.add(map)
            } while (cursor.moveToNext())
        }
        cursor.close()
        db.close()
        return records
    }

    fun clearTable() {
        val db = this.writableDatabase
        db.execSQL("DELETE FROM $TABLE_NAME")
        db.close()
    }
}
