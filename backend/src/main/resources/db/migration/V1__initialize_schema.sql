-- Infrastructure marker only; no participant or domain data.
CREATE TABLE infrastructure_marker (
    id integer PRIMARY KEY CHECK (id = 1),
    created_at timestamptz NOT NULL DEFAULT CURRENT_TIMESTAMP
);
INSERT INTO infrastructure_marker (id) VALUES (1);
