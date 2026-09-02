package com.bench.notes;

import jakarta.persistence.Column;
import jakarta.persistence.Entity;
import jakarta.persistence.GeneratedValue;
import jakarta.persistence.GenerationType;
import jakarta.persistence.Id;
import jakarta.persistence.Table;
import java.time.OffsetDateTime;
import org.hibernate.annotations.CreationTimestamp;

/**
 * The ORM model. Maps to bench_notes — a table dedicated to the cross-runtime benchmark
 * (kept separate from scribe's schemaless `notes`). Hibernate manages it; ddl-auto creates
 * it on first run.
 */
@Entity
@Table(name = "bench_notes")
public class Note {

    @Id
    @GeneratedValue(strategy = GenerationType.IDENTITY) // maps to Postgres serial/identity
    private Long id;

    @Column(columnDefinition = "text")
    private String title;

    @Column(columnDefinition = "text")
    private String body;

    @CreationTimestamp
    @Column(name = "created_at", updatable = false)
    private OffsetDateTime createdAt;

    protected Note() {
        // required by JPA
    }

    public Note(String title, String body) {
        this.title = title;
        this.body = body;
    }

    public Long getId() {
        return id;
    }

    public String getTitle() {
        return title;
    }

    public String getBody() {
        return body;
    }

    public OffsetDateTime getCreatedAt() {
        return createdAt;
    }
}
