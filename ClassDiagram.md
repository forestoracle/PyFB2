# Диаграмма классов PyFB2 
```mermaid

classDiagram
    direction RL
    class FB2ConvertBase {
        -int level
        -int counter
        -int parent_id
        -sqlite3 dbconn 
        -create_path(path) str
        -exclude_restricted_chars(name) str
         
        -create_memory_db()
        -backup_memory_db()
        +write_binaries() []
        
    }
   
     
    FB2ConvertBase --|> FB2Hyst
    FB2ConvertBase --|> FB2HTML
    FB2ConvertBase --|> FB2Chm
    
    FB2HTML: +create_html()
    FB2HTML: +create_index()
    
    FB2Hyst: +write_hyst()
    FB2Chm: +write_chm()
   
 ```

```mermaid
graph TD;
    FB2Renamer-->FB2GroupRenamer;
 ```