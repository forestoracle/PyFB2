pragma user_version=2;
pragma application_id=4444;

CREATE TABLE IF NOT EXISTS nb_profile (
                name        VARCHAR (255) NOT NULL,
                ProfileType VARCHAR (255) NOT NULL DEFAULT NOTEBOOK       
        );

CREATE TABLE IF NOT EXISTS notebook (
    id         INTEGER       CONSTRAINT pk_notebook PRIMARY KEY AUTOINCREMENT
                             UNIQUE
                             NOT NULL,
    name       VARCHAR (255) NOT NULL,
    SeqNo      INTEGER,
    Rating     INTEGER       DEFAULT (0),
    TabColor   INTEGER,
    ShortDescr VARCHAR (255),
    state      VARCHAR (1)   NOT NULL DEFAULT A,
    Tags       TEXT
);

CREATE TABLE IF NOT EXISTS note (
    id         INTEGER       CONSTRAINT pk_note PRIMARY KEY AUTOINCREMENT
                             CONSTRAINT uniq_note UNIQUE
                             NOT NULL,
    ParentID   INTEGER       REFERENCES note (id),
    NotebookID INTEGER       REFERENCES notebook (id),
    SeqNo      INTEGER       DEFAULT (1000000),
    Name       VARCHAR (255) NOT NULL,
    Link       VARCHAR (255),
    ShortDescr TEXT,
    Text       TEXT,
    State      CHAR (1)      NOT NULL
                             DEFAULT A,
    TextType   VARCHAR (10)  DEFAULT HTML,
    NodeType   CHAR (1),      
    Tags       TEXT
);

CREATE INDEX IF NOT EXISTS idx_note_parentid ON note (NotebookID, ParentID, state);

CREATE TABLE IF NOT EXISTS note_image (
    id         INTEGER       CONSTRAINT pk_note_image PRIMARY KEY AUTOINCREMENT
                             CONSTRAINT uniq_note_image UNIQUE
                             NOT NULL,
    image      BLOB,
    book_id    INTEGER,
    ShortDescr VARCHAR (1024), 
    LongDescr  TEXT,
    MD5        VARCHAR (40),
    thumbnail  BLOB
);

CREATE INDEX IF NOT EXISTS idx_note_image_md5 ON note_image(MD5);

CREATE TABLE IF NOT EXISTS css (
                id       INTEGER       CONSTRAINT pk_css PRIMARY KEY AUTOINCREMENT
                                       UNIQUE NOT NULL,
                name     VARCHAR (255) NOT NULL,
                code     VARCHAR (255) UNIQUE NOT NULL,
                filename VARCHAR (255) UNIQUE NOT NULL,
                css      TEXT
);

CREATE TABLE IF NOT EXISTS links (
    id       INTEGER      CONSTRAINT pk_links PRIMARY KEY AUTOINCREMENT
                          CONSTRAINT uniq_links UNIQUE
                          NOT NULL,
    link_id  VARCHAR (32),
    filename VARCHAR (32) 
);