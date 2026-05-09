\c "misskey"

CREATE EXTENSION pgroonga;

-- Run after misskey migration
-- CREATE INDEX idx_note_text_with_pgroonga ON note USING pgroonga (text);
