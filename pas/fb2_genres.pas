unit fb2_genres;
{ Справочник жанров FictionBook (resources/genres.json).

  Сгенерирован из pyFB2/pyFB2/resources/genres.json — используется
  конвертером EPUB -> FB2 для сопоставления <dc:subject> с кодами жанров
  (аналог _load_genres()/_match_genres() в epub_to_fb2.py). }

{$mode objfpc}{$H+}
{$codepage utf8}

interface

uses
  Classes, SysUtils;

type
  TGenreEntry = record
    Code: UnicodeString;
    Name: UnicodeString;
  end;

const
  { Коды и названия жанров FictionBook. }
  GENRES: array[0..109] of TGenreEntry = (
    (Code: 'sf_history'; Name: 'Альтернативная история'),
    (Code: 'sf_action'; Name: 'Боевая фантастика'),
    (Code: 'sf_epic'; Name: 'Эпическая фантастика'),
    (Code: 'sf_heroic'; Name: 'Героическая фантастика'),
    (Code: 'sf_detective'; Name: 'Детективная фантастика'),
    (Code: 'sf_cyberpunk'; Name: 'Киберпанк'),
    (Code: 'sf_space'; Name: 'Космическая фантастика'),
    (Code: 'sf_social'; Name: 'Социально-психологическая фантастика'),
    (Code: 'sf_horror'; Name: 'Ужасы и Мистика'),
    (Code: 'sf_humor'; Name: 'Юмористическая фантастика'),
    (Code: 'sf_fantasy'; Name: 'Фэнтези'),
    (Code: 'sf'; Name: 'Научная Фантастика'),
    (Code: 'det_classic'; Name: 'Классический детектив'),
    (Code: 'det_police'; Name: 'Полицейский детектив'),
    (Code: 'det_action'; Name: 'Боевик'),
    (Code: 'det_irony'; Name: 'Иронический детектив'),
    (Code: 'det_history'; Name: 'Исторический детектив'),
    (Code: 'det_espionage'; Name: 'Шпионский детектив'),
    (Code: 'det_crime'; Name: 'Криминальный детектив'),
    (Code: 'det_political'; Name: 'Политический детектив'),
    (Code: 'det_maniac'; Name: 'Маньяки'),
    (Code: 'det_hard'; Name: 'Крутой детектив'),
    (Code: 'thriller'; Name: 'Триллер'),
    (Code: 'detective'; Name: 'Детектив (не относящийся в прочие категории).'),
    (Code: 'prose_classic'; Name: 'Классическая проза'),
    (Code: 'prose_history'; Name: 'Историческая проза'),
    (Code: 'prose_contemporary'; Name: 'Современная проза'),
    (Code: 'prose_counter'; Name: 'Контркультура'),
    (Code: 'prose_rus_classic'; Name: 'Русская классическая проза'),
    (Code: 'prose_su_classics'; Name: 'Советская классическая проза'),
    (Code: 'love_contemporary'; Name: 'Современные любовные романы'),
    (Code: 'love_history'; Name: 'Исторические любовные романы'),
    (Code: 'love_detective'; Name: 'Остросюжетные любовные романы'),
    (Code: 'love_short'; Name: 'Короткие любовные романы'),
    (Code: 'love_erotica'; Name: 'Эротика'),
    (Code: 'adv_western'; Name: 'Вестерн'),
    (Code: 'adv_history'; Name: 'Исторические приключения'),
    (Code: 'adv_indian'; Name: 'Приключения про индейцев'),
    (Code: 'adv_maritime'; Name: 'Морские приключения'),
    (Code: 'adv_geo'; Name: 'Путешествия и география'),
    (Code: 'adv_animal'; Name: 'Природа и животные'),
    (Code: 'adventure'; Name: 'Прочие приключения (то, что не вошло в другие категории)'),
    (Code: 'child_tale'; Name: 'Сказка'),
    (Code: 'child_verse'; Name: 'Детские стихи'),
    (Code: 'child_prose'; Name: 'Детскиая проза'),
    (Code: 'child_sf'; Name: 'Детская фантастика'),
    (Code: 'child_det'; Name: 'Детские остросюжетные'),
    (Code: 'child_adv'; Name: 'Детские приключения'),
    (Code: 'child_education'; Name: 'Детская образовательная литература'),
    (Code: 'children'; Name: 'Прочая детская литература (то, что не вошло в другие категории)'),
    (Code: 'poetry'; Name: 'Поэзия'),
    (Code: 'dramaturgy'; Name: 'Драматургия'),
    (Code: 'antique_ant'; Name: 'Античная литература'),
    (Code: 'antique_european'; Name: 'Европейская старинная литература'),
    (Code: 'antique_russian'; Name: 'Древнерусская литература'),
    (Code: 'antique_east'; Name: 'Древневосточная литература'),
    (Code: 'antique_myths'; Name: 'Мифы. Легенды. Эпос'),
    (Code: 'antique'; Name: 'Прочая старинная литература (то, что не вошло в другие категории)'),
    (Code: 'sci_history'; Name: 'История'),
    (Code: 'sci_psychology'; Name: 'Психология'),
    (Code: 'sci_culture'; Name: 'Культурология'),
    (Code: 'sci_religion'; Name: 'Религиоведение'),
    (Code: 'sci_philosophy'; Name: 'Философия'),
    (Code: 'sci_politics'; Name: 'Политика'),
    (Code: 'sci_business'; Name: 'Деловая литература'),
    (Code: 'sci_juris'; Name: 'Юриспруденция'),
    (Code: 'sci_linguistic'; Name: 'Языкознание'),
    (Code: 'sci_medicine'; Name: 'Медицина'),
    (Code: 'sci_phys'; Name: 'Физика'),
    (Code: 'sci_math'; Name: 'Математика'),
    (Code: 'sci_chem'; Name: 'Химия'),
    (Code: 'sci_biology'; Name: 'Биология'),
    (Code: 'sci_tech'; Name: 'Технические науки'),
    (Code: 'science'; Name: 'Прочая научная литература (то, что не вошло в другие категории)'),
    (Code: 'comp_www'; Name: 'Интернет'),
    (Code: 'comp_programming'; Name: 'Программирование'),
    (Code: 'comp_hard'; Name: 'Компьютерное железо (аппаратное обеспечение)'),
    (Code: 'comp_soft'; Name: 'Программы'),
    (Code: 'comp_db'; Name: 'Базы данных'),
    (Code: 'comp_osnet'; Name: 'ОС и Сети'),
    (Code: 'computers'; Name: 'Прочая околокомпьтерная литература (то, что не вошло в другие категории)'),
    (Code: 'ref_encyc'; Name: 'Энциклопедии'),
    (Code: 'ref_dict'; Name: 'Словари'),
    (Code: 'ref_ref'; Name: 'Справочники'),
    (Code: 'ref_guide'; Name: 'Руководства'),
    (Code: 'reference'; Name: 'Прочая справочная литература (то, что не вошло в другие категории)'),
    (Code: 'nonf_biography'; Name: 'Биографии и Мемуары'),
    (Code: 'nonf_publicism'; Name: 'Публицистика'),
    (Code: 'nonf_criticism'; Name: 'Критика'),
    (Code: 'design'; Name: 'Искусство и Дизайн'),
    (Code: 'nonfiction'; Name: 'Прочая документальная литература (то, что не вошло в другие категории)'),
    (Code: 'religion_rel'; Name: 'Религия'),
    (Code: 'religion_esoterics'; Name: 'Эзотерика'),
    (Code: 'religion_self'; Name: 'Самосовершенствование'),
    (Code: 'religion'; Name: 'Прочая религионая литература (то, что не вошло в другие категории)'),
    (Code: 'humor_anecdote'; Name: 'Анекдоты'),
    (Code: 'humor_prose'; Name: 'Юмористическая проза'),
    (Code: 'humor_verse'; Name: 'Юмористические стихи'),
    (Code: 'humor'; Name: 'Прочий юмор (то, что не вошло в другие категории)'),
    (Code: 'home_cooking'; Name: 'Кулинария'),
    (Code: 'home_pets'; Name: 'Домашние животные'),
    (Code: 'home_crafts'; Name: 'Хобби и ремесла'),
    (Code: 'home_entertain'; Name: 'Развлечения'),
    (Code: 'home_health'; Name: 'Здоровье'),
    (Code: 'home_garden'; Name: 'Сад и огород'),
    (Code: 'home_diy'; Name: 'Сделай сам'),
    (Code: 'home_sport'; Name: 'Спорт'),
    (Code: 'home_sex'; Name: 'Эротика, Секс'),
    (Code: 'home'; Name: 'Прочее домоводство (то, что не вошло в другие категории)'),
    (Code: 'painting'; Name: 'Изобразительное искусство')
  );

{ Есть ли такой код жанра. }
function GenreCodeExists(const Code: UnicodeString): Boolean;

{ Найти код жанра по названию (без учёта регистра). '' — не найдено. }
function GenreCodeByName(const Name: UnicodeString): UnicodeString;

implementation

function GenreCodeExists(const Code: UnicodeString): Boolean;
var
  I: Integer;
begin
  for I := 0 to High(GENRES) do
    if GENRES[I].Code = Code then
      Exit(True);
  Result := False;
end;

function GenreCodeByName(const Name: UnicodeString): UnicodeString;
var
  I: Integer;
  Lower: UnicodeString;
begin
  Result := '';
  Lower := WideLowerCase(Name);
  for I := 0 to High(GENRES) do
    if WideLowerCase(GENRES[I].Name) = Lower then
      Exit(GENRES[I].Code);
end;

end.
