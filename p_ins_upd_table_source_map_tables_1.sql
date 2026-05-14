CREATE OR REPLACE PROCEDURE curated.p_ins_upd_table_source_map_tables("TARGET_TABLE_NAME" VARCHAR(16777216), "INPUT_BATCH_CODE" VARCHAR(16777216), "SOURCE_SCHEMA_NAME" VARCHAR(16777216), "SOURCE_TABLE_NAME" VARCHAR(16777216), "TARGET_SCHEMA_NAME" VARCHAR(16777216), "SCD_TYPE" VARCHAR(16777216))
RETURNS VARCHAR(16777216)
LANGUAGE SQL
EXECUTE AS OWNER
AS
DECLARE
    id decimal(38,0);
BEGIN

  LET full_object_name  VARCHAR :=  CURRENT_DATABASE()||'.'||:target_schema_name||'.'||:target_table_name;

  DELETE FROM curated.datamapping_mergekey;
  SHOW PRIMARY keys in IDENTIFIER(:full_object_name) ;  
  INSERT INTO curated.datamapping_mergekey SELECT * FROM TABLE(RESULT_SCAN(LAST_QUERY_ID()));

  DELETE FROM curated.datamapping_deletekey;
  SHOW UNIQUE keys in IDENTIFIER(:full_object_name) ;
  INSERT INTO curated.datamapping_deletekey SELECT * FROM TABLE(RESULT_SCAN(LAST_QUERY_ID()));
  
  //update existing table mapping
       UPDATE curated.table_source_map
          SET batch_code = :input_batch_code
              ,audit_change_date = current_timestamp
              ,audit_change_user = 'administrator'
        WHERE upper(target_table_name)  = upper(:target_table_name)
          AND upper(target_schema_name) = upper(:target_schema_name);
  //insert new table mapping
  INSERT INTO curated.table_source_map(
              table_source_map_id
            , source_schema_name
            , source_table_name 
            , target_schema_name
            , target_table_name 
            , load_order 
            , scd_type 
            , batch_code
            , is_active
            , audit_create_date 
            , audit_change_date 
            , audit_create_user 
            , audit_change_user
            )
      SELECT id.table_source_map_id
            ,:source_schema_name
            ,:source_table_name
            ,:target_schema_name
            ,:target_table_name
            ,0
            ,:scd_type
            ,:input_batch_code
            ,1
            ,current_timestamp
            ,current_timestamp
            ,'administrator'
            ,'administrator'
        FROM information_schema.tables a
            ,(select COALESCE(max(table_source_map_id),0) + 1 as table_source_map_id from curated.table_source_map) as id
       WHERE a.table_name = upper(:target_table_name)
         AND a.table_catalog = CURRENT_DATABASE()
         AND a.table_schema = :target_schema_name
         AND NOT EXISTS (SELECT *
                           FROM curated.table_source_map
                          WHERE upper(target_table_name) = upper(:target_table_name));
                          
 //get id
 SELECT table_source_map_id into id from curated.table_source_map where target_table_name = :target_table_name;
 //delete old column mapping
 DELETE FROM curated.table_source_column_map WHERE table_source_map_id = :id;
 //insert column mapping
 INSERT INTO curated.table_source_column_map(
             table_source_map_id 
            ,source_column_name 
            ,target_column_name
            ,is_merge_key
            ,is_delete_key
            ,audit_create_date
            ,audit_change_date 
            ,audit_create_user
            ,audit_change_user
             )
     select :id as table_source_map_id
           ,case when a.column_name ='BATCH_CODE'
                 then ':BATCHCODE'
                 when a.column_name = 'BATCH_RUN_CODE'
                 then ':BATCHRUNCODE'
                 else a.column_name 
              end as sourcecolumnname
           ,a.column_name as targetcolumnname 
           ,case when b.table_name is null
                  and b.column_name is null
                 then 0
                 else 1
            end as ismergekey 
           ,case when d.table_name is null 
                  and d.column_name is null 
                 then 0
                 else 1
             end as isdeletekey
           ,current_timestamp as audit_create_date
           ,current_timestamp as audit_change_date
           ,'administrator' as audit_create_user
           ,'administrator' as audit_change_user
       from information_schema.columns a 
             left join curated.datamapping_mergekey b 
                    on a.table_name           = b.table_name
                   and a.column_name          = b.column_name
             left join curated.datamapping_deletekey d 
                    on a.table_name          = d.table_name 
                   and a.column_name         = d.column_name
      where a.table_catalog = CURRENT_DATABASE()
        and a.table_schema = :target_schema_name
        and upper(a.column_name) not in ('BATCH_CODE','BATCH_RUN_CODE')
        --,'AUDIT_CREATE_DATE','AUDIT_CHANGE_DATE','AUDIT_CREATE_USER','AUDIT_CHANGE_USER')
        and a.table_name = upper(:target_table_name);
  //insert new external table mapping
  INSERT INTO curated.table_source_external_map(
              table_source_map_id
              ,source_schema_name
              ,source_table_name
              ,audit_create_date
              ,audit_change_date 
              ,audit_create_user
              ,audit_change_user
              )
        select :id as table_source_map_id
              ,a.source_schema_name
              ,a.source_table_name
              ,current_timestamp
              ,current_timestamp
              ,'administrator'
              ,'administrator'
        from curated.vw_table_external_source a
        where a.table_name = :target_table_name
         and not exists (select 1 
                           from curated.table_source_external_map b
                          where b.table_source_map_id = :id
                            and b.source_schema_name = a.source_schema_name
                            and b.source_table_name = a.source_table_name);
RETURN target_table_name;
END;
