-- 1 up
CREATE TABLE manager (
    id INTEGER PRIMARY KEY,
    hostname TEXT,
    url TEXT,
    api_key TEXT,
    status TEXT,
    checked DATETIME,
    updated DATETIME DEFAULT CURRENT_TIMESTAMP,
    inserted DATETIME DEFAULT CURRENT_TIMESTAMP
);

CREATE TRIGGER manager_update AFTER UPDATE ON manager
BEGIN
    UPDATE manager SET updated = DATETIME('NOW')
    WHERE rowid = new.rowid;
END;

CREATE TABLE status (
    id INTEGER PRIMARY KEY,
    status TEXT,
    stdout TEXT,
    stderr TEXT,
    updated DATETIME DEFAULT CURRENT_TIMESTAMP,
    inserted DATETIME DEFAULT CURRENT_TIMESTAMP
);

CREATE TRIGGER status_update AFTER UPDATE ON status
BEGIN
    UPDATE status SET updated = DATETIME('NOW')
    WHERE rowid = new.rowid;
END;

-- 1 down
DROP TABLE manager;
DROP TABLE status;
