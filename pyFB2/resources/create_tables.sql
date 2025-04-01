/******************************************************************
   Создание БД записной книжки.
   ---------------------------------
   Версия 2022-08-23
   Создаются следующие таблицы:
     notebook         - записные книжки
     note             - заметки, разбитые по записным книжкам
     note_image       - хранение изображений из заметок
     table_comments   - комментарии к таблицам
     column_comments  - комментарии к столбцам
******************************************************************/
pragma user_version=2;
pragma application_id=4444;

CREATE TABLE IF NOT EXISTS nb_profile (
                name        VARCHAR (255) NOT NULL,
                ProfileType VARCHAR (255) NOT NULL DEFAULT NOTEBOOK       
        );

/******************************************************************
* NOTEBOOK
  Значение столбца STATE
        A	Активна
	H	Скрыта
	D	Удалена
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

  Значение столбца STATE
        A	Активна
	H	Скрыта
	D	Удалена

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
/* Вставка строк */
insert into table_comments (TableName, Comment) values ('NOTEBOOK', 'Записные книжки');
insert into table_comments (TableName, Comment) values ('NOTE', 'Текст заметок в записных книжках');
insert into table_comments (TableName, Comment) values ('NOTE_IMAGE', 'Изображения из записных книжек');
insert into table_comments (TableName, Comment) values ('CSS', 'Таблицы стилей');
/******************************************************************
*   COLUMN_COMMENTS
******************************************************************/
CREATE TABLE IF NOT EXISTS column_comments (
    TableName  VARCHAR (32)  REFERENCES table_comments (TableName),
    ColumnName VARCHAR (32),
    Comment    VARCHAR (255) 
);
delete from column_comments;
/* Вставка строк */
  /* NOTEBOOK */
insert into column_comments (TableName, ColumnName, Comment) values ('NOTEBOOK', 'ID', 'Идентификатор записи');
insert into column_comments (TableName, ColumnName, Comment) values ('NOTEBOOK', 'NAME', 'Заголовок книжки');
insert into column_comments (TableName, ColumnName, Comment) values ('NOTEBOOK', 'SEQNO', 'Порядок отображения в дереве записных книжек');
insert into column_comments (TableName, ColumnName, Comment) values ('NOTEBOOK', 'RATING', 'Рэйтинг (пока не используется)');
insert into column_comments (TableName, ColumnName, Comment) values ('NOTEBOOK', 'TABCOLOR', 'Цвет закладки (пока не используется)');
insert into column_comments (TableName, ColumnName, Comment) values ('NOTEBOOK', 'SHORTDESCR', 'Короткое описание');
insert into column_comments (TableName, ColumnName, Comment) values ('NOTEBOOK', 'STATE', 'Состояние (A - Активна,H - Скрыта,D - Удалена)');
  /* NOTE */       
insert into column_comments (TableName, ColumnName, Comment) values ('NOTE', 'ID', 'Идентификатор записи');
insert into column_comments (TableName, ColumnName, Comment) values ('NOTE', 'PARENTID', 'Идентификатор родительской записи, таблица NOTE');
insert into column_comments (TableName, ColumnName, Comment) values ('NOTE', 'NOTEBOOKID', 'Идентификатор записной книжки, таблица NOTEBOOK');
insert into column_comments (TableName, ColumnName, Comment) values ('NOTE', 'SEQNO', 'Порядок отображения в дереве заметок');
insert into column_comments (TableName, ColumnName, Comment) values ('NOTE', 'NAME', 'Заголовок заметки');
insert into column_comments (TableName, ColumnName, Comment) values ('NOTE', 'SHORTDESCR', 'Короткое описание');
insert into column_comments (TableName, ColumnName, Comment) values ('NOTE', 'TEXT', 'Текст заметки');
insert into column_comments (TableName, ColumnName, Comment) values ('NOTE', 'STATE', 'Состояние (A - Активна,H - Скрыта,D - Удалена)');
insert into column_comments (TableName, ColumnName, Comment) values ('NOTE', 'TEXTTYPE', 'Тип текста (HTML, HTMLZ, MD, MDZ)');
insert into column_comments (TableName, ColumnName, Comment) values ('NOTE', 'NODETYPE', 'Тип узла (A - автор, С - Заголовок книги,... )');
insert into column_comments (TableName, ColumnName, Comment) values ('NOTE', 'TAGS', 'Тэги');

  /* NOTE_IMAGE */
insert into column_comments (TableName, ColumnName, Comment) values ('NOTE_IMAGE', 'ID', 'Идентификатор записи');
insert into column_comments (TableName, ColumnName, Comment) values ('NOTE_IMAGE', 'IMAGE', 'Блоб с изображением');
insert into column_comments (TableName, ColumnName, Comment) values ('NOTE_IMAGE', 'SHORTDESCR', 'Короткое описание');
insert into column_comments (TableName, ColumnName, Comment) values ('NOTE_IMAGE', 'LONGDESCR', 'Длинное описание');
insert into column_comments (TableName, ColumnName, Comment) values ('NOTE_IMAGE', 'MD5', 'Контрольная сумма MD5');
insert into column_comments (TableName, ColumnName, Comment) values ('NOTE_IMAGE', 'THUMBNAIL', 'Миниатюра');
