package com.bench.notes;

import java.util.List;
import org.springframework.data.jpa.repository.JpaRepository;

/**
 * Spring Data JPA repository — the ORM data-access layer. save() and the derived
 * findTop100…​ query are all Hibernate does the SQL for us.
 */
public interface NoteRepository extends JpaRepository<Note, Long> {

    List<Note> findTop100ByOrderByIdDesc();
}
