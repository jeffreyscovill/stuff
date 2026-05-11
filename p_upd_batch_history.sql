CREATE OR REPLACE PROCEDURE CURATED.P_UPD_BATCH_HISTORY("BATCH_RUN_CODE" VARCHAR, "TABLE_SOURCE_MAP_ID" NUMBER(38,0), "STATUS_CODE" VARCHAR, "INSERT_ROW_QUANTITY" NUMBER(38,0), "UPDATE_ROW_QUANTITY" NUMBER(38,0), "DELETE_ROW_QUANTITY" NUMBER(38,0))
RETURNS VARCHAR
LANGUAGE SQL
EXECUTE AS OWNER
AS '
begin
    Update batch_history
    SET 
        status_code = :status_code
        ,end_date = sysdate()
        ,insert_row_quantity = coalesce(:insert_row_quantity, 0)
        ,update_row_quantity = coalesce(:update_row_quantity, 0)
        ,delete_row_quantity = coalesce(:delete_row_quantity, 0)
   WHERE batch_run_code = :batch_run_code
     and table_source_map_id = :table_source_map_id;
end';
