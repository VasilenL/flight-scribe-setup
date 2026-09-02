package com.bench.notes;

import java.util.List;
import org.springframework.http.HttpStatus;
import org.springframework.web.bind.annotation.GetMapping;
import org.springframework.web.bind.annotation.PostMapping;
import org.springframework.web.bind.annotation.RequestBody;
import org.springframework.web.bind.annotation.RequestMapping;
import org.springframework.web.bind.annotation.ResponseStatus;
import org.springframework.web.bind.annotation.RestController;

/**
 * The canonical benchmark contract, matching the other runtimes:
 *   POST /api/notes {title, body}  -> 201 {id, title, body, createdAt}
 *   GET  /api/notes                -> most recent 100 rows
 *
 * Path + port (3000, via the Service) are chosen so this drops straight into the existing
 * ab.sh harness: `sh deploy/k8s/loadtest/ab.sh spring-notes`.
 */
@RestController
@RequestMapping("/api/notes")
public class NoteController {

    private final NoteRepository repo;
    private final NoteHistory history;

    NoteController(NoteRepository repo, NoteHistory history) {
        this.repo = repo;
        this.history = history;
    }

    public record NoteRequest(String title, String body) {
    }

    @PostMapping
    @ResponseStatus(HttpStatus.CREATED)
    public Note create(@RequestBody NoteRequest req) {
        // Two writes per create — the row, then its history row. See NoteHistory for why:
        // scribe-bun does the same, and matching it is what makes the comparison honest.
        Note saved = repo.save(new Note(req.title(), req.body()));
        history.record(saved);
        return saved;
    }

    @GetMapping
    public List<Note> list() {
        return repo.findTop100ByOrderByIdDesc();
    }
}
