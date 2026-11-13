/// Schema version 1, the v0.1.0 baseline.
///
/// This DDL is kept verbatim so a new database is created through the same
/// ordered migrations as an existing library.
const String schemaVersion1 = '''
CREATE TABLE IF NOT EXISTS documents (
  id TEXT PRIMARY KEY,
  content_hash TEXT NOT NULL,
  kind TEXT NOT NULL,
  last_opened_at INTEGER NOT NULL,
  data TEXT NOT NULL
);
CREATE TABLE IF NOT EXISTS pages (
  document_id TEXT NOT NULL REFERENCES documents(id) ON DELETE CASCADE,
  page INTEGER NOT NULL CHECK(page > 0),
  status TEXT NOT NULL,
  data TEXT NOT NULL,
  PRIMARY KEY(document_id, page)
);
CREATE TABLE IF NOT EXISTS evidence (
  rowid INTEGER PRIMARY KEY AUTOINCREMENT,
  evidence_id TEXT NOT NULL UNIQUE,
  document_id TEXT NOT NULL REFERENCES documents(id) ON DELETE CASCADE,
  document_hash TEXT NOT NULL,
  page INTEGER NOT NULL CHECK(page > 0),
  origin TEXT NOT NULL,
  data TEXT NOT NULL
);
CREATE INDEX IF NOT EXISTS evidence_document_page ON evidence(document_id, page);
CREATE VIRTUAL TABLE IF NOT EXISTS evidence_fts USING fts5(terms);
CREATE TRIGGER IF NOT EXISTS evidence_delete_fts AFTER DELETE ON evidence
BEGIN
  DELETE FROM evidence_fts WHERE rowid = old.rowid;
END;
CREATE TABLE IF NOT EXISTS notes (
  id TEXT PRIMARY KEY,
  document_id TEXT NOT NULL REFERENCES documents(id) ON DELETE CASCADE,
  page INTEGER NOT NULL CHECK(page > 0),
  created_at INTEGER NOT NULL,
  data TEXT NOT NULL
);
CREATE INDEX IF NOT EXISTS notes_document ON notes(document_id, created_at);
CREATE TABLE IF NOT EXISTS sessions (
  id TEXT PRIMARY KEY,
  document_id TEXT NOT NULL REFERENCES documents(id) ON DELETE CASCADE,
  updated_at INTEGER NOT NULL,
  data TEXT NOT NULL
);
CREATE INDEX IF NOT EXISTS sessions_document ON sessions(document_id, updated_at);
CREATE TABLE IF NOT EXISTS settings (key TEXT PRIMARY KEY, value TEXT NOT NULL);
''';

/// Schema version 2 adds the schedule.
///
/// Queryable fields live in their own columns; versioned content (materials,
/// series rules, diagnostics) stays in JSON. Blocks reference tasks and plans
/// with foreign keys so deleting a plan cannot leave clickable ghosts.
const String schemaVersion2 = '''
CREATE TABLE study_plans (
  id TEXT PRIMARY KEY,
  title TEXT NOT NULL,
  status TEXT NOT NULL,
  start_date TEXT NOT NULL,
  exam_date TEXT,
  revision INTEGER NOT NULL,
  updated_at INTEGER NOT NULL,
  data TEXT NOT NULL
);
CREATE INDEX study_plans_status ON study_plans(status, updated_at);

CREATE TABLE study_tasks (
  id TEXT PRIMARY KEY,
  plan_id TEXT REFERENCES study_plans(id) ON DELETE CASCADE,
  status TEXT NOT NULL,
  minutes INTEGER NOT NULL CHECK(minutes > 0),
  priority INTEGER NOT NULL,
  material_document_id TEXT,
  material_hash TEXT,
  updated_at INTEGER NOT NULL,
  data TEXT NOT NULL
);
CREATE INDEX study_tasks_plan ON study_tasks(plan_id, status);
CREATE INDEX study_tasks_material ON study_tasks(material_document_id);

CREATE TABLE calendar_blocks (
  id TEXT PRIMARY KEY,
  plan_id TEXT REFERENCES study_plans(id) ON DELETE CASCADE,
  task_id TEXT REFERENCES study_tasks(id) ON DELETE CASCADE,
  date TEXT NOT NULL,
  start_minute INTEGER NOT NULL CHECK(start_minute >= 0 AND start_minute < 1440),
  end_minute INTEGER NOT NULL CHECK(end_minute > start_minute AND end_minute <= 1440),
  kind TEXT NOT NULL,
  state TEXT NOT NULL,
  locked INTEGER NOT NULL DEFAULT 0,
  series_id TEXT,
  instance_key TEXT UNIQUE,
  revision INTEGER NOT NULL,
  updated_at INTEGER NOT NULL,
  data TEXT NOT NULL
);
CREATE INDEX calendar_blocks_date ON calendar_blocks(date, start_minute);
CREATE INDEX calendar_blocks_plan ON calendar_blocks(plan_id, date);
CREATE INDEX calendar_blocks_task ON calendar_blocks(task_id);
CREATE INDEX calendar_blocks_series ON calendar_blocks(series_id, date);

CREATE TABLE schedule_availability (
  plan_id TEXT PRIMARY KEY REFERENCES study_plans(id) ON DELETE CASCADE,
  data TEXT NOT NULL
);

CREATE TABLE schedule_revisions (
  id TEXT PRIMARY KEY,
  plan_id TEXT NOT NULL REFERENCES study_plans(id) ON DELETE CASCADE,
  applied_at INTEGER NOT NULL,
  undone_at INTEGER,
  data TEXT NOT NULL
);
CREATE INDEX schedule_revisions_plan ON schedule_revisions(plan_id, applied_at);

CREATE TABLE learning_records (
  id TEXT PRIMARY KEY,
  block_id TEXT,
  task_id TEXT,
  kind TEXT NOT NULL,
  occurred_at INTEGER NOT NULL,
  operation_id TEXT UNIQUE,
  data TEXT NOT NULL
);
CREATE INDEX learning_records_block ON learning_records(block_id, occurred_at);
CREATE INDEX learning_records_task ON learning_records(task_id, occurred_at);
''';

/// Schema version 3 adds persisted planning conversations.
///
/// Messages are stored separately from the schedule so a conversation can be
/// reviewed or cleared without touching the formal calendar. Deleting a plan
/// removes its conversations; messages cascade with the conversation.
const String schemaVersion3 = '''
CREATE TABLE planning_conversations (
  id TEXT PRIMARY KEY,
  plan_id TEXT REFERENCES study_plans(id) ON DELETE CASCADE,
  created_at INTEGER NOT NULL,
  updated_at INTEGER NOT NULL,
  data TEXT NOT NULL
);
CREATE INDEX planning_conversations_plan ON planning_conversations(plan_id, updated_at);

CREATE TABLE planning_messages (
  id TEXT PRIMARY KEY,
  conversation_id TEXT NOT NULL REFERENCES planning_conversations(id) ON DELETE CASCADE,
  sequence INTEGER NOT NULL CHECK(sequence >= 0),
  role TEXT NOT NULL,
  kind TEXT NOT NULL,
  created_at INTEGER NOT NULL,
  request_id TEXT,
  data TEXT NOT NULL,
  UNIQUE(conversation_id, sequence)
);
CREATE INDEX planning_messages_conversation ON planning_messages(conversation_id, sequence);
''';

/// Schema version 4 adds plan material sources.
///
/// A plan can cite a textbook, syllabus or past paper by document version and
/// physical page range. The source keeps a title snapshot so the link can be
/// explained even after the document is removed; the foreign key still
/// cascades when the document or plan is deleted.
const String schemaVersion4 = '''
CREATE TABLE plan_sources (
  id TEXT PRIMARY KEY,
  plan_id TEXT NOT NULL REFERENCES study_plans(id) ON DELETE CASCADE,
  document_id TEXT NOT NULL REFERENCES documents(id) ON DELETE CASCADE,
  document_hash TEXT NOT NULL,
  purpose TEXT NOT NULL,
  start_page INTEGER NOT NULL CHECK(start_page > 0),
  end_page INTEGER NOT NULL CHECK(end_page >= start_page),
  revision INTEGER NOT NULL,
  created_at INTEGER NOT NULL,
  updated_at INTEGER NOT NULL,
  data TEXT NOT NULL
);
CREATE INDEX plan_sources_plan ON plan_sources(plan_id, purpose, start_page);
CREATE INDEX plan_sources_document ON plan_sources(document_id);
CREATE UNIQUE INDEX plan_sources_unique_range
  ON plan_sources(plan_id, document_id, purpose, start_page, end_page);
''';

/// Schema version 5 adds plan knowledge items.
const String schemaVersion5 = '''
CREATE TABLE knowledge_items (
  id TEXT PRIMARY KEY,
  plan_id TEXT NOT NULL REFERENCES study_plans(id) ON DELETE CASCADE,
  title TEXT NOT NULL,
  priority INTEGER NOT NULL,
  minutes INTEGER NOT NULL,
  source_id TEXT REFERENCES plan_sources(id) ON DELETE SET NULL,
  task_id TEXT REFERENCES study_tasks(id) ON DELETE SET NULL,
  revision INTEGER NOT NULL,
  updated_at INTEGER NOT NULL,
  data TEXT NOT NULL
);
CREATE INDEX knowledge_items_plan ON knowledge_items(plan_id, priority, updated_at);
CREATE INDEX knowledge_items_source ON knowledge_items(source_id);
CREATE INDEX knowledge_items_task ON knowledge_items(task_id);
''';

/// Schema version 6 adds generated daily lessons.
const String schemaVersion6 = '''
CREATE TABLE daily_lessons (
  id TEXT PRIMARY KEY,
  task_id TEXT NOT NULL REFERENCES study_tasks(id) ON DELETE CASCADE,
  plan_id TEXT NOT NULL REFERENCES study_plans(id) ON DELETE CASCADE,
  status TEXT NOT NULL,
  version INTEGER NOT NULL,
  updated_at INTEGER NOT NULL,
  data TEXT NOT NULL
);
CREATE INDEX daily_lessons_task ON daily_lessons(task_id, version);
CREATE INDEX daily_lessons_plan ON daily_lessons(plan_id, updated_at);
''';

/// Schema version 7 adds whole-book understanding, textbook conversations and a
/// local cache of pages actually fetched from the web.
///
/// Every book table cascades from `documents`, so deleting a textbook removes
/// its chapters, chunk insights, knowledge points and conversations together.
/// The web cache is deliberately global: it stores only pages the user already
/// chose to read, and can be pruned without touching any book.
const String schemaVersion7 = '''
CREATE TABLE book_understanding_jobs (
  document_id TEXT PRIMARY KEY REFERENCES documents(id) ON DELETE CASCADE,
  document_hash TEXT NOT NULL,
  status TEXT NOT NULL,
  revision INTEGER NOT NULL,
  updated_at INTEGER NOT NULL,
  data TEXT NOT NULL
);

CREATE TABLE book_chapters (
  id TEXT PRIMARY KEY,
  document_id TEXT NOT NULL REFERENCES documents(id) ON DELETE CASCADE,
  document_hash TEXT NOT NULL,
  ordinal INTEGER NOT NULL CHECK(ordinal >= 0),
  start_page INTEGER NOT NULL CHECK(start_page > 0),
  end_page INTEGER NOT NULL CHECK(end_page >= start_page),
  title TEXT NOT NULL,
  revision INTEGER NOT NULL,
  updated_at INTEGER NOT NULL,
  data TEXT NOT NULL
);
CREATE INDEX book_chapters_document
  ON book_chapters(document_id, ordinal);

CREATE TABLE book_chunks (
  id TEXT PRIMARY KEY,
  document_id TEXT NOT NULL REFERENCES documents(id) ON DELETE CASCADE,
  chapter_id TEXT REFERENCES book_chapters(id) ON DELETE SET NULL,
  document_hash TEXT NOT NULL,
  ordinal INTEGER NOT NULL CHECK(ordinal >= 0),
  start_page INTEGER NOT NULL CHECK(start_page > 0),
  end_page INTEGER NOT NULL CHECK(end_page >= start_page),
  status TEXT NOT NULL,
  revision INTEGER NOT NULL,
  updated_at INTEGER NOT NULL,
  data TEXT NOT NULL
);
CREATE INDEX book_chunks_document ON book_chunks(document_id, ordinal);
CREATE INDEX book_chunks_chapter ON book_chunks(chapter_id);

CREATE TABLE book_knowledge_points (
  id TEXT PRIMARY KEY,
  document_id TEXT NOT NULL REFERENCES documents(id) ON DELETE CASCADE,
  chapter_id TEXT REFERENCES book_chapters(id) ON DELETE SET NULL,
  document_hash TEXT NOT NULL,
  term TEXT NOT NULL,
  term_norm TEXT NOT NULL,
  start_page INTEGER NOT NULL CHECK(start_page > 0),
  end_page INTEGER NOT NULL CHECK(end_page >= start_page),
  revision INTEGER NOT NULL,
  updated_at INTEGER NOT NULL,
  data TEXT NOT NULL
);
CREATE INDEX book_knowledge_points_document
  ON book_knowledge_points(document_id, term_norm);
CREATE INDEX book_knowledge_points_chapter
  ON book_knowledge_points(chapter_id);

CREATE TABLE book_qa_conversations (
  id TEXT PRIMARY KEY,
  document_id TEXT NOT NULL REFERENCES documents(id) ON DELETE CASCADE,
  document_hash TEXT NOT NULL,
  created_at INTEGER NOT NULL,
  updated_at INTEGER NOT NULL,
  data TEXT NOT NULL
);
CREATE INDEX book_qa_conversations_document
  ON book_qa_conversations(document_id, updated_at);

CREATE TABLE book_qa_messages (
  id TEXT PRIMARY KEY,
  conversation_id TEXT NOT NULL
    REFERENCES book_qa_conversations(id) ON DELETE CASCADE,
  sequence INTEGER NOT NULL CHECK(sequence >= 0),
  role TEXT NOT NULL,
  created_at INTEGER NOT NULL,
  data TEXT NOT NULL,
  UNIQUE(conversation_id, sequence)
);
CREATE INDEX book_qa_messages_conversation
  ON book_qa_messages(conversation_id, sequence);

CREATE TABLE web_source_cache (
  url_hash TEXT PRIMARY KEY,
  url TEXT NOT NULL,
  title TEXT NOT NULL,
  fetched_at INTEGER NOT NULL,
  data TEXT NOT NULL
);
CREATE INDEX web_source_cache_fetched ON web_source_cache(fetched_at);
''';

/// Schema version 8 adds the local library: folders, document entries
/// (one primary location plus shortcuts), tags, soft deletion and the import
/// queue journal.
///
/// Folders never move the managed original: an entry is only a placement record
/// and keeps the stable document id that notes, Q&A, courses and plans already
/// reference. Documents gain identity metadata (original name, format, size),
/// a lifecycle state and a learning-mode preference. The name and colour of a
/// folder never determine how a document can be studied.
const String schemaVersion8 = '''
ALTER TABLE documents ADD COLUMN original_name TEXT NOT NULL DEFAULT '';
ALTER TABLE documents ADD COLUMN format TEXT NOT NULL DEFAULT '';
ALTER TABLE documents ADD COLUMN size_bytes INTEGER NOT NULL DEFAULT 0;
ALTER TABLE documents ADD COLUMN lifecycle TEXT NOT NULL DEFAULT 'active';
ALTER TABLE documents ADD COLUMN lifecycle_version INTEGER NOT NULL DEFAULT 1;
ALTER TABLE documents ADD COLUMN starred INTEGER NOT NULL DEFAULT 0;
ALTER TABLE documents ADD COLUMN learning_mode TEXT NOT NULL DEFAULT 'unspecified';
ALTER TABLE documents ADD COLUMN added_at INTEGER NOT NULL DEFAULT 0;
ALTER TABLE documents ADD COLUMN deleted_batch TEXT;
ALTER TABLE documents ADD COLUMN trashed_at INTEGER;

CREATE INDEX documents_content_hash ON documents(content_hash);
CREATE INDEX documents_lifecycle ON documents(lifecycle, added_at);
CREATE INDEX documents_starred ON documents(starred, lifecycle);

CREATE TABLE library_folders (
  id TEXT PRIMARY KEY,
  parent_id TEXT REFERENCES library_folders(id) ON DELETE RESTRICT,
  name TEXT NOT NULL,
  name_norm TEXT NOT NULL,
  sort_key INTEGER NOT NULL,
  color_mode TEXT NOT NULL DEFAULT 'inherit',
  color_value INTEGER,
  icon TEXT,
  description TEXT NOT NULL DEFAULT '',
  revision INTEGER NOT NULL DEFAULT 1,
  created_at INTEGER NOT NULL,
  updated_at INTEGER NOT NULL,
  deleted_batch TEXT,
  deleted_at INTEGER,
  data TEXT NOT NULL
);
CREATE INDEX library_folders_parent
  ON library_folders(parent_id, deleted_at, sort_key);
CREATE UNIQUE INDEX library_folders_unique_name
  ON library_folders(COALESCE(parent_id, ''), name_norm)
  WHERE deleted_at IS NULL;

CREATE TABLE document_entries (
  id TEXT PRIMARY KEY,
  folder_id TEXT REFERENCES library_folders(id) ON DELETE RESTRICT,
  document_id TEXT NOT NULL REFERENCES documents(id) ON DELETE CASCADE,
  is_shortcut INTEGER NOT NULL DEFAULT 0,
  alias TEXT,
  sort_key INTEGER NOT NULL,
  created_at INTEGER NOT NULL,
  deleted_batch TEXT,
  deleted_at INTEGER,
  data TEXT NOT NULL
);
CREATE INDEX document_entries_folder
  ON document_entries(folder_id, deleted_at, sort_key);
CREATE INDEX document_entries_document ON document_entries(document_id);
CREATE UNIQUE INDEX document_entries_one_primary
  ON document_entries(document_id)
  WHERE is_shortcut = 0 AND deleted_at IS NULL;
CREATE UNIQUE INDEX document_entries_one_per_folder
  ON document_entries(COALESCE(folder_id, ''), document_id)
  WHERE deleted_at IS NULL;

CREATE TABLE library_tags (
  id TEXT PRIMARY KEY,
  name TEXT NOT NULL,
  name_norm TEXT NOT NULL UNIQUE,
  color_value INTEGER,
  created_at INTEGER NOT NULL,
  data TEXT NOT NULL
);

CREATE TABLE document_tags (
  document_id TEXT NOT NULL REFERENCES documents(id) ON DELETE CASCADE,
  tag_id TEXT NOT NULL REFERENCES library_tags(id) ON DELETE CASCADE,
  created_at INTEGER NOT NULL,
  PRIMARY KEY(document_id, tag_id)
);
CREATE INDEX document_tags_tag ON document_tags(tag_id);

CREATE TABLE deletion_batches (
  id TEXT PRIMARY KEY,
  kind TEXT NOT NULL,
  label TEXT NOT NULL,
  root_id TEXT,
  created_at INTEGER NOT NULL,
  item_count INTEGER NOT NULL,
  document_count INTEGER NOT NULL,
  data TEXT NOT NULL
);
CREATE INDEX deletion_batches_created ON deletion_batches(created_at);

CREATE TABLE import_batches (
  id TEXT PRIMARY KEY,
  target_folder_id TEXT,
  created_at INTEGER NOT NULL,
  updated_at INTEGER NOT NULL,
  data TEXT NOT NULL
);

CREATE TABLE import_items (
  id TEXT PRIMARY KEY,
  batch_id TEXT NOT NULL REFERENCES import_batches(id) ON DELETE CASCADE,
  source_path TEXT NOT NULL,
  target_folder_id TEXT,
  status TEXT NOT NULL,
  document_id TEXT,
  error TEXT,
  bytes_total INTEGER NOT NULL DEFAULT 0,
  bytes_done INTEGER NOT NULL DEFAULT 0,
  created_at INTEGER NOT NULL,
  updated_at INTEGER NOT NULL,
  data TEXT NOT NULL
);
CREATE INDEX import_items_batch ON import_items(batch_id, created_at);
''';

/// Schema v9 turns notes into independent study outputs. A note no longer
/// requires a document row and survives permanent deletion of its source; the
/// original document id/hash/page/region stay in note_sources as history.
/// Body JSON stays the source of truth; plain text, Markdown and search text
/// are derived. The old notes table is intentionally left in place so a
/// pre-v9 snapshot remains readable.
const String schemaVersion9 = '''
CREATE TABLE note_documents (
  id TEXT PRIMARY KEY,
  title TEXT NOT NULL DEFAULT '',
  body TEXT NOT NULL DEFAULT '',
  body_format TEXT NOT NULL DEFAULT 'markdown',
  body_schema_version INTEGER NOT NULL DEFAULT 1,
  revision INTEGER NOT NULL DEFAULT 1,
  starred INTEGER NOT NULL DEFAULT 0,
  lifecycle TEXT NOT NULL DEFAULT 'active',
  deleted_batch TEXT,
  trashed_at INTEGER,
  created_at INTEGER NOT NULL,
  updated_at INTEGER NOT NULL,
  last_opened_at INTEGER NOT NULL DEFAULT 0,
  data TEXT NOT NULL
);
CREATE INDEX note_documents_lifecycle ON note_documents(lifecycle, updated_at);
CREATE INDEX note_documents_updated ON note_documents(updated_at);
CREATE TABLE note_entries (
  id TEXT PRIMARY KEY,
  note_id TEXT NOT NULL REFERENCES note_documents(id) ON DELETE CASCADE,
  folder_id TEXT REFERENCES library_folders(id) ON DELETE SET NULL,
  is_shortcut INTEGER NOT NULL DEFAULT 0,
  alias TEXT,
  sort_key INTEGER NOT NULL DEFAULT 0,
  created_at INTEGER NOT NULL,
  data TEXT NOT NULL
);
CREATE UNIQUE INDEX note_entries_primary ON note_entries(note_id) WHERE is_shortcut = 0;
CREATE INDEX note_entries_folder ON note_entries(folder_id, sort_key);
CREATE TABLE note_sources (
  id TEXT PRIMARY KEY,
  note_id TEXT NOT NULL REFERENCES note_documents(id) ON DELETE CASCADE,
  document_id TEXT,
  document_hash TEXT NOT NULL DEFAULT '',
  page INTEGER CHECK(page IS NULL OR page > 0),
  region TEXT NOT NULL DEFAULT '{}',
  excerpt TEXT NOT NULL DEFAULT '',
  source_type TEXT NOT NULL DEFAULT 'document',
  title TEXT NOT NULL DEFAULT '',
  created_at INTEGER NOT NULL,
  data TEXT NOT NULL
);
CREATE INDEX note_sources_note ON note_sources(note_id, created_at);
CREATE INDEX note_sources_document ON note_sources(document_id);
CREATE TABLE note_questions (
  id TEXT PRIMARY KEY,
  note_id TEXT NOT NULL REFERENCES note_documents(id) ON DELETE CASCADE,
  text TEXT NOT NULL,
  status TEXT NOT NULL DEFAULT 'open',
  created_at INTEGER NOT NULL,
  resolved_at INTEGER,
  data TEXT NOT NULL
);
CREATE INDEX note_questions_note ON note_questions(note_id, created_at);
CREATE TABLE note_tags (
  note_id TEXT NOT NULL REFERENCES note_documents(id) ON DELETE CASCADE,
  tag_id TEXT NOT NULL REFERENCES library_tags(id) ON DELETE CASCADE,
  PRIMARY KEY (note_id, tag_id)
);
CREATE INDEX note_tags_tag ON note_tags(tag_id);
CREATE TABLE note_revisions (
  id TEXT PRIMARY KEY,
  note_id TEXT NOT NULL REFERENCES note_documents(id) ON DELETE CASCADE,
  revision INTEGER NOT NULL,
  title TEXT NOT NULL,
  body TEXT NOT NULL,
  reason TEXT NOT NULL DEFAULT 'auto',
  created_at INTEGER NOT NULL,
  manual INTEGER NOT NULL DEFAULT 0,
  data TEXT NOT NULL
);
CREATE INDEX note_revisions_note ON note_revisions(note_id, created_at);
''';

/// Schema v10 adds the standalone review system: item definitions and revisions,
/// immutable source snapshots, separate feedback/content checks, FSRS & training
/// schedules, idempotent attempt & event logs, resumable sessions, plan/tag
/// memberships, schedule batch links, and managed image references.
const String schemaVersion10 = '''
CREATE TABLE review_items (
  id TEXT PRIMARY KEY,
  kind TEXT NOT NULL DEFAULT 'concept',
  schedule_mode TEXT NOT NULL DEFAULT 'fsrs',
  objective TEXT NOT NULL DEFAULT '',
  prompt TEXT NOT NULL DEFAULT '',
  answer TEXT NOT NULL DEFAULT '',
  steps_json TEXT NOT NULL DEFAULT '[]',
  hint TEXT NOT NULL DEFAULT '',
  explanation TEXT NOT NULL DEFAULT '',
  lifecycle TEXT NOT NULL DEFAULT 'active',
  starred INTEGER NOT NULL DEFAULT 0,
  revision INTEGER NOT NULL DEFAULT 1,
  estimated_seconds INTEGER NOT NULL DEFAULT 30,
  wrong_streak INTEGER NOT NULL DEFAULT 0,
  correct_streak INTEGER NOT NULL DEFAULT 0,
  error_reason TEXT NOT NULL DEFAULT '',
  correction_note TEXT NOT NULL DEFAULT '',
  deleted_batch TEXT,
  trashed_at INTEGER,
  created_at INTEGER NOT NULL,
  updated_at INTEGER NOT NULL,
  data TEXT NOT NULL
);
CREATE INDEX review_items_lifecycle ON review_items(lifecycle, updated_at);
CREATE INDEX review_items_kind ON review_items(kind, schedule_mode);

CREATE TABLE review_item_revisions (
  id TEXT PRIMARY KEY,
  item_id TEXT NOT NULL REFERENCES review_items(id) ON DELETE CASCADE,
  revision INTEGER NOT NULL,
  reason TEXT NOT NULL DEFAULT 'edit',
  prompt TEXT NOT NULL DEFAULT '',
  answer TEXT NOT NULL DEFAULT '',
  created_at INTEGER NOT NULL,
  data TEXT NOT NULL
);
CREATE INDEX review_item_revisions_item ON review_item_revisions(item_id, revision DESC);

CREATE TABLE review_origins (
  id TEXT PRIMARY KEY,
  item_id TEXT NOT NULL REFERENCES review_items(id) ON DELETE CASCADE,
  origin_key TEXT NOT NULL UNIQUE,
  source_type TEXT NOT NULL DEFAULT 'manual',
  document_id TEXT,
  document_hash TEXT NOT NULL DEFAULT '',
  page INTEGER CHECK(page IS NULL OR page > 0),
  region_json TEXT NOT NULL DEFAULT '{}',
  note_id TEXT,
  note_revision INTEGER,
  lesson_id TEXT,
  exercise_id TEXT,
  session_id TEXT,
  snapshot_text TEXT NOT NULL DEFAULT '',
  source_available INTEGER NOT NULL DEFAULT 1,
  created_at INTEGER NOT NULL,
  updated_at INTEGER NOT NULL,
  data TEXT NOT NULL
);
CREATE INDEX review_origins_item ON review_origins(item_id, created_at);
CREATE INDEX review_origins_doc ON review_origins(document_id);
CREATE INDEX review_origins_note ON review_origins(note_id);

CREATE TABLE review_candidates (
  id TEXT PRIMARY KEY,
  origin_key TEXT NOT NULL UNIQUE,
  source_type TEXT NOT NULL DEFAULT 'lesson',
  document_id TEXT,
  note_id TEXT,
  lesson_id TEXT,
  exercise_id TEXT,
  session_id TEXT,
  title TEXT NOT NULL DEFAULT '',
  prompt TEXT NOT NULL DEFAULT '',
  answer TEXT NOT NULL DEFAULT '',
  hint TEXT NOT NULL DEFAULT '',
  explanation TEXT NOT NULL DEFAULT '',
  status TEXT NOT NULL DEFAULT 'pending',
  linked_item_id TEXT REFERENCES review_items(id) ON DELETE SET NULL,
  reason TEXT NOT NULL DEFAULT '',
  created_at INTEGER NOT NULL,
  updated_at INTEGER NOT NULL,
  data TEXT NOT NULL
);
CREATE INDEX review_candidates_status ON review_candidates(status, updated_at DESC);
CREATE INDEX review_candidates_doc ON review_candidates(document_id);

CREATE TABLE review_checks (
  id TEXT PRIMARY KEY,
  origin_key TEXT UNIQUE,
  target_type TEXT NOT NULL DEFAULT 'feedback',
  target_id TEXT NOT NULL DEFAULT '',
  target_version INTEGER NOT NULL DEFAULT 1,
  item_id TEXT REFERENCES review_items(id) ON DELETE CASCADE,
  document_id TEXT,
  session_id TEXT,
  attempt_key TEXT,
  reason TEXT NOT NULL DEFAULT '',
  status TEXT NOT NULL DEFAULT 'open',
  resolution_note TEXT NOT NULL DEFAULT '',
  created_at INTEGER NOT NULL,
  updated_at INTEGER NOT NULL,
  data TEXT NOT NULL
);
CREATE INDEX review_checks_status ON review_checks(status, updated_at DESC);
CREATE INDEX review_checks_item ON review_checks(item_id);

CREATE TABLE review_schedules (
  item_id TEXT PRIMARY KEY REFERENCES review_items(id) ON DELETE CASCADE,
  mode TEXT NOT NULL DEFAULT 'fsrs',
  algorithm_version TEXT NOT NULL DEFAULT 'fsrs-v5-default-19w',
  state TEXT NOT NULL DEFAULT 'newCard',
  stability REAL NOT NULL DEFAULT 0.0,
  difficulty REAL NOT NULL DEFAULT 0.0,
  elapsed_days REAL NOT NULL DEFAULT 0.0,
  scheduled_days INTEGER NOT NULL DEFAULT 0,
  reps INTEGER NOT NULL DEFAULT 0,
  lapses INTEGER NOT NULL DEFAULT 0,
  step INTEGER NOT NULL DEFAULT 0,
  training_stage TEXT NOT NULL DEFAULT 'initial',
  algorithm_due_at_utc INTEGER,
  defer_until_utc INTEGER,
  paused INTEGER NOT NULL DEFAULT 0,
  revision INTEGER NOT NULL DEFAULT 1,
  last_review_at_utc INTEGER,
  updated_at INTEGER NOT NULL,
  data TEXT NOT NULL
);
CREATE INDEX review_schedules_due ON review_schedules(paused, algorithm_due_at_utc);

CREATE TABLE review_attempts (
  id TEXT PRIMARY KEY,
  item_id TEXT NOT NULL REFERENCES review_items(id) ON DELETE CASCADE,
  session_id TEXT,
  item_revision INTEGER NOT NULL DEFAULT 1,
  mode TEXT NOT NULL DEFAULT 'formal',
  answer_text TEXT NOT NULL DEFAULT '',
  answer_payload_json TEXT NOT NULL DEFAULT '{}',
  used_hint INTEGER NOT NULL DEFAULT 0,
  viewed_source INTEGER NOT NULL DEFAULT 0,
  self_eval INTEGER NOT NULL DEFAULT 0,
  rating TEXT,
  complexity_outcome TEXT,
  ai_suggestion_json TEXT,
  ai_disputed INTEGER NOT NULL DEFAULT 0,
  result_source TEXT NOT NULL DEFAULT 'self',
  active_seconds INTEGER NOT NULL DEFAULT 0,
  study_day TEXT NOT NULL,
  created_at_utc INTEGER NOT NULL,
  operation_id TEXT NOT NULL UNIQUE,
  undone INTEGER NOT NULL DEFAULT 0,
  data TEXT NOT NULL
);
CREATE INDEX review_attempts_item ON review_attempts(item_id, created_at_utc DESC);
CREATE INDEX review_attempts_day ON review_attempts(study_day, mode);

CREATE TABLE review_events (
  id TEXT PRIMARY KEY,
  item_id TEXT NOT NULL REFERENCES review_items(id) ON DELETE CASCADE,
  attempt_id TEXT,
  operation_id TEXT NOT NULL UNIQUE,
  event_type TEXT NOT NULL,
  algorithm_version TEXT NOT NULL DEFAULT '',
  before_schedule_json TEXT NOT NULL DEFAULT '{}',
  after_schedule_json TEXT NOT NULL DEFAULT '{}',
  study_day TEXT NOT NULL,
  created_at_utc INTEGER NOT NULL,
  data TEXT NOT NULL
);
CREATE INDEX review_events_item ON review_events(item_id, created_at_utc DESC);

CREATE TABLE review_sessions (
  id TEXT PRIMARY KEY,
  mode TEXT NOT NULL DEFAULT 'formal',
  scope_json TEXT NOT NULL DEFAULT '{}',
  budget_minutes INTEGER NOT NULL DEFAULT 20,
  status TEXT NOT NULL DEFAULT 'active',
  current_index INTEGER NOT NULL DEFAULT 0,
  active_seconds INTEGER NOT NULL DEFAULT 0,
  study_day TEXT NOT NULL,
  schedule_task_id TEXT,
  schedule_block_id TEXT,
  started_at_utc INTEGER NOT NULL,
  updated_at_utc INTEGER NOT NULL,
  completed_at_utc INTEGER,
  data TEXT NOT NULL
);
CREATE INDEX review_sessions_status ON review_sessions(status, updated_at_utc DESC);

CREATE TABLE review_session_items (
  session_id TEXT NOT NULL REFERENCES review_sessions(id) ON DELETE CASCADE,
  position INTEGER NOT NULL,
  item_id TEXT NOT NULL REFERENCES review_items(id) ON DELETE CASCADE,
  item_revision INTEGER NOT NULL DEFAULT 1,
  draft_answer TEXT NOT NULL DEFAULT '',
  draft_notes TEXT NOT NULL DEFAULT '',
  used_hint INTEGER NOT NULL DEFAULT 0,
  viewed_source INTEGER NOT NULL DEFAULT 0,
  status TEXT NOT NULL DEFAULT 'pending',
  attempt_id TEXT,
  updated_at_utc INTEGER NOT NULL,
  PRIMARY KEY (session_id, position)
);
CREATE INDEX review_session_items_item ON review_session_items(item_id);

CREATE TABLE review_memberships (
  id TEXT PRIMARY KEY,
  item_id TEXT NOT NULL REFERENCES review_items(id) ON DELETE CASCADE,
  scope_type TEXT NOT NULL,
  scope_id TEXT NOT NULL,
  created_at INTEGER NOT NULL,
  UNIQUE(item_id, scope_type, scope_id)
);
CREATE INDEX review_memberships_scope ON review_memberships(scope_type, scope_id);

CREATE TABLE review_task_links (
  id TEXT PRIMARY KEY,
  task_id TEXT NOT NULL UNIQUE,
  block_id TEXT,
  session_id TEXT,
  plan_id TEXT,
  study_day TEXT NOT NULL,
  target_minutes INTEGER NOT NULL DEFAULT 20,
  actual_seconds INTEGER NOT NULL DEFAULT 0,
  status TEXT NOT NULL DEFAULT 'planned',
  created_at_utc INTEGER NOT NULL,
  updated_at_utc INTEGER NOT NULL,
  data TEXT NOT NULL
);
CREATE INDEX review_task_links_plan ON review_task_links(plan_id, study_day);

CREATE TABLE review_tags (
  item_id TEXT NOT NULL REFERENCES review_items(id) ON DELETE CASCADE,
  tag_id TEXT NOT NULL REFERENCES library_tags(id) ON DELETE CASCADE,
  PRIMARY KEY (item_id, tag_id)
);
CREATE INDEX review_tags_tag ON review_tags(tag_id);

CREATE TABLE review_asset_refs (
  id TEXT PRIMARY KEY,
  owner_type TEXT NOT NULL,
  owner_id TEXT NOT NULL,
  asset_path TEXT NOT NULL,
  sha256 TEXT NOT NULL DEFAULT '',
  created_at INTEGER NOT NULL
);
CREATE INDEX review_asset_refs_owner ON review_asset_refs(owner_type, owner_id);
CREATE INDEX review_asset_refs_path ON review_asset_refs(asset_path);
''';