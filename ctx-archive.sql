PRAGMA foreign_keys=OFF;
BEGIN TRANSACTION;
CREATE TABLE block (
    id     TEXT PRIMARY KEY,
    title  TEXT NOT NULL,
    status TEXT NOT NULL CHECK (status IN ('pending','wip','done')) DEFAULT 'pending'
);
CREATE TABLE item (
    block_id TEXT NOT NULL REFERENCES block(id),
    seq      INTEGER NOT NULL,
    text     TEXT NOT NULL,
    done     INTEGER NOT NULL DEFAULT 0,
    PRIMARY KEY (block_id, seq)
);
CREATE TABLE doc (
    id     TEXT PRIMARY KEY,
    kind   TEXT NOT NULL CHECK (kind IN ('ADR','MTS','STD','RFC','VOC')),
    title  TEXT NOT NULL,
    status TEXT NOT NULL
);
CREATE TABLE doc_field (
    doc_id  TEXT NOT NULL REFERENCES doc(id),
    name    TEXT NOT NULL,
    content TEXT NOT NULL,
    PRIMARY KEY (doc_id, name)
);
CREATE TABLE doc_rule (
    doc_id TEXT NOT NULL REFERENCES doc(id),
    seq    INTEGER NOT NULL,
    modal  TEXT NOT NULL CHECK (modal IN ('MUST','MUST_NOT','SHOULD','MAY')),
    text   TEXT NOT NULL,
    PRIMARY KEY (doc_id, seq)
);
CREATE TABLE doc_ref (
    from_id TEXT NOT NULL REFERENCES doc(id),
    to_id   TEXT NOT NULL REFERENCES doc(id),
    rel     TEXT NOT NULL CHECK (rel IN ('depends_on','references')),
    PRIMARY KEY (from_id, to_id, rel)
);
CREATE TABLE decision (
    id      INTEGER PRIMARY KEY AUTOINCREMENT,
    seq     INTEGER NOT NULL,
    text    TEXT NOT NULL,
    adr_ref TEXT REFERENCES doc(id)
);
CREATE TABLE roadmap_phase (
    id             INTEGER PRIMARY KEY,
    title          TEXT NOT NULL,
    status         TEXT NOT NULL CHECK (status IN ('pending','done')) DEFAULT 'pending',
    depends_on_doc TEXT REFERENCES doc(id)
);
CREATE TABLE roadmap_item (
    phase_id INTEGER NOT NULL REFERENCES roadmap_phase(id),
    seq      INTEGER NOT NULL,
    text     TEXT NOT NULL,
    done     INTEGER NOT NULL DEFAULT 0,
    PRIMARY KEY (phase_id, seq)
);
CREATE TABLE prose_section (
    source  TEXT NOT NULL CHECK (source IN ('terminology','authoring','contributing')),
    seq     INTEGER NOT NULL,
    section TEXT NOT NULL,
    text    TEXT NOT NULL,
    PRIMARY KEY (source, seq)
);
COMMIT;
