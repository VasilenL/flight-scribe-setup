package com.bench.notes;

import jakarta.annotation.PostConstruct;
import org.springframework.jdbc.core.JdbcTemplate;
import org.springframework.stereotype.Component;

/**
 * Version-history writer, mirroring scribe's `<component>_history` table.
 *
 * WHY THIS EXISTS: scribe-bun does TWO inserts per create — the row, then a history row
 * (see scribe-bun src/db.ts createSingle). A single-INSERT endpoint here would be doing
 * half the database work, so the cross-runtime numbers wouldn't mean anything.
 *
 * Raw JDBC rather than JPA on purpose: scribe's history insert is also a raw parameterized
 * statement (pg-promise), and FastAPI's is raw asyncpg. Matching that keeps the second
 * write identical across all three runtimes — the ORM-vs-raw difference stays confined to
 * the PRIMARY insert, which is what we actually want to measure.
 *
 * The JSON is hand-built rather than via Jackson: Spring Boot 4 moved to Jackson 3
 * (`tools.jackson.databind`), and the payload here is a fixed four-field shape, so a tiny
 * writer removes a dependency question from the hot path entirely.
 *
 * NOT replicated: scribe's diff_match_patch patch computation — runtime CPU, not DB work.
 * We store the serialized row, keeping the written payload a comparable size.
 */
@Component
public class NoteHistory {

    private final JdbcTemplate jdbc;

    NoteHistory(JdbcTemplate jdbc) {
        this.jdbc = jdbc;
    }

    /**
     * Hibernate's ddl-auto creates bench_notes but knows nothing about this table, so
     * create it here. Runs after the datasource is up and Hibernate has run its DDL, so
     * the foreign key has something to point at. Idempotent.
     */
    @PostConstruct
    void ensureTable() {
        jdbc.execute(
                "CREATE TABLE IF NOT EXISTS bench_notes_history ("
                        + " id serial PRIMARY KEY,"
                        + " foreign_key integer REFERENCES bench_notes (id) ON DELETE CASCADE,"
                        + " patches json)");
    }

    /** The second write. CAST(? AS JSON) matches scribe's own history insert exactly. */
    void record(Note note) {
        // Matches scribe's shape: a JSON array holding the serialized row as ONE string.
        String row = "{\"id\":" + note.getId()
                + ",\"title\":" + quote(note.getTitle())
                + ",\"body\":" + quote(note.getBody())
                + ",\"createdAt\":" + quote(String.valueOf(note.getCreatedAt()))
                + "}";
        String patches = "[" + quote(row) + "]";
        jdbc.update(
                "INSERT INTO bench_notes_history(foreign_key, patches) VALUES(?, CAST(? AS JSON))",
                note.getId(), patches);
    }

    /** Minimal JSON string literal: escape what would otherwise break the document. */
    private static String quote(String s) {
        if (s == null) {
            return "null";
        }
        StringBuilder sb = new StringBuilder(s.length() + 16).append('"');
        for (int i = 0; i < s.length(); i++) {
            char c = s.charAt(i);
            switch (c) {
                case '"' -> sb.append("\\\"");
                case '\\' -> sb.append("\\\\");
                case '\n' -> sb.append("\\n");
                case '\r' -> sb.append("\\r");
                case '\t' -> sb.append("\\t");
                default -> {
                    if (c < 0x20) {
                        sb.append(String.format("\\u%04x", (int) c));
                    } else {
                        sb.append(c);
                    }
                }
            }
        }
        return sb.append('"').toString();
    }
}
