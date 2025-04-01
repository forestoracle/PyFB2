/******************************************************************
   �������� �� �������� ������.
   ---------------------------------
   ������ 2022-08-23
   ��������� ��������� �������:
     notebook         - �������� ������
     note             - �������, �������� �� �������� �������
     note_image       - �������� ����������� �� �������
     table_comments   - ����������� � ��������
     column_comments  - ����������� � ��������
******************************************************************/
pragma user_version=2;
pragma application_id=4444;

CREATE TABLE IF NOT EXISTS nb_profile (
                name        VARCHAR (255) NOT NULL,
                ProfileType VARCHAR (255) NOT NULL DEFAULT NOTEBOOK       
        );

/******************************************************************
* NOTEBOOK
  �������� ������� STATE
        A	�������
	H	������
	D	�������
******************************************************************/
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

/******************************************************************
*   NOTE

  �������� ������� STATE
        A	�������
	H	������
	D	�������

******************************************************************/
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

/******************************************************************
*   NOTE_IMAGE
******************************************************************/

CREATE TABLE IF NOT EXISTS note_image (
    id         INTEGER       CONSTRAINT pk_note_image PRIMARY KEY AUTOINCREMENT
                             CONSTRAINT uniq_note_image UNIQUE
                             NOT NULL,
    image      BLOB,
    ShortDescr VARCHAR (1024), 
    LongDescr  TEXT,
    MD5        VARCHAR (40),
    thumbnail  BLOB
);

CREATE INDEX IF NOT EXISTS idx_note_image_md5 ON note_image(MD5);

DROP TRIGGER IF EXISTS image_update_md5;
CREATE TRIGGER image_update_md5
         AFTER UPDATE OF image
            ON note_image
      FOR EACH ROW
BEGIN
    UPDATE note_image
       SET md5 = md5(image) 
     WHERE id = new.id;
END;


/******************************************************************
*   CSS
******************************************************************/

CREATE TABLE IF NOT EXISTS css (
                id       INTEGER       CONSTRAINT pk_css PRIMARY KEY AUTOINCREMENT
                                       UNIQUE NOT NULL,
                name     VARCHAR (255) NOT NULL,
                code     VARCHAR (255) UNIQUE NOT NULL,
                filename VARCHAR (255) UNIQUE NOT NULL,
                css      TEXT
);

/******************************************************************
*   TABLE_COMMENTS
******************************************************************/

CREATE TABLE IF NOT EXISTS table_comments (
    TableName VARCHAR (32)  PRIMARY KEY ASC,
    Comment   VARCHAR (255) 
);
delete from table_comments;
/* ������� ����� */
insert into table_comments (TableName, Comment) values ('NOTEBOOK', '�������� ������');
insert into table_comments (TableName, Comment) values ('NOTE', '����� ������� � �������� �������');
insert into table_comments (TableName, Comment) values ('NOTE_IMAGE', '����������� �� �������� ������');
insert into table_comments (TableName, Comment) values ('CSS', '������� ������');
/******************************************************************
*   COLUMN_COMMENTS
******************************************************************/
CREATE TABLE IF NOT EXISTS column_comments (
    TableName  VARCHAR (32)  REFERENCES table_comments (TableName),
    ColumnName VARCHAR (32),
    Comment    VARCHAR (255) 
);
delete from column_comments;
/* ������� ����� */
  /* NOTEBOOK */
insert into column_comments (TableName, ColumnName, Comment) values ('NOTEBOOK', 'ID', '������������� ������');
insert into column_comments (TableName, ColumnName, Comment) values ('NOTEBOOK', 'NAME', '��������� ������');
insert into column_comments (TableName, ColumnName, Comment) values ('NOTEBOOK', 'SEQNO', '������� ����������� � ������ �������� ������');
insert into column_comments (TableName, ColumnName, Comment) values ('NOTEBOOK', 'RATING', '������� (���� �� ������������)');
insert into column_comments (TableName, ColumnName, Comment) values ('NOTEBOOK', 'TABCOLOR', '���� �������� (���� �� ������������)');
insert into column_comments (TableName, ColumnName, Comment) values ('NOTEBOOK', 'SHORTDESCR', '�������� ��������');
insert into column_comments (TableName, ColumnName, Comment) values ('NOTEBOOK', 'STATE', '��������� (A - �������,H - ������,D - �������)');
  /* NOTE */       
insert into column_comments (TableName, ColumnName, Comment) values ('NOTE', 'ID', '������������� ������');
insert into column_comments (TableName, ColumnName, Comment) values ('NOTE', 'PARENTID', '������������� ������������ ������, ������� NOTE');
insert into column_comments (TableName, ColumnName, Comment) values ('NOTE', 'NOTEBOOKID', '������������� �������� ������, ������� NOTEBOOK');
insert into column_comments (TableName, ColumnName, Comment) values ('NOTE', 'SEQNO', '������� ����������� � ������ �������');
insert into column_comments (TableName, ColumnName, Comment) values ('NOTE', 'NAME', '��������� �������');
insert into column_comments (TableName, ColumnName, Comment) values ('NOTE', 'SHORTDESCR', '�������� ��������');
insert into column_comments (TableName, ColumnName, Comment) values ('NOTE', 'TEXT', '����� �������');
insert into column_comments (TableName, ColumnName, Comment) values ('NOTE', 'STATE', '��������� (A - �������,H - ������,D - �������)');
insert into column_comments (TableName, ColumnName, Comment) values ('NOTE', 'TEXTTYPE', '��� ������ (HTML, HTMLZ, MD, MDZ)');
insert into column_comments (TableName, ColumnName, Comment) values ('NOTE', 'NODETYPE', '��� ���� (A - �����, � - ��������� �����,... )');
insert into column_comments (TableName, ColumnName, Comment) values ('NOTE', 'TAGS', '����');

  /* NOTE_IMAGE */
insert into column_comments (TableName, ColumnName, Comment) values ('NOTE_IMAGE', 'ID', '������������� ������');
insert into column_comments (TableName, ColumnName, Comment) values ('NOTE_IMAGE', 'IMAGE', '���� � ������������');
insert into column_comments (TableName, ColumnName, Comment) values ('NOTE_IMAGE', 'SHORTDESCR', '�������� ��������');
insert into column_comments (TableName, ColumnName, Comment) values ('NOTE_IMAGE', 'LONGDESCR', '������� ��������');
insert into column_comments (TableName, ColumnName, Comment) values ('NOTE_IMAGE', 'MD5', '����������� ����� MD5');
insert into column_comments (TableName, ColumnName, Comment) values ('NOTE_IMAGE', 'THUMBNAIL', '���������');
