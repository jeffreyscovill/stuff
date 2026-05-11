CREATE OR REPLACE PROCEDURE CURATED.P_INS_BATCH_HISTORY("BATCH_RUN_CODE" VARCHAR, "BATCH_CODE" VARCHAR, "TABLE_SOURCE_MAP_ID" NUMBER(38,0), "LOAD_ORDER" NUMBER(38,0))
RETURNS VARCHAR
LANGUAGE SQL
EXECUTE AS OWNER
AS '
begin
    insert into batch_history   
    (batch_run_code,batch_code,table_source_map_id,load_order,start_date,end_date,status_code,insert_row_quantity,update_row_quantity,delete_row_quantity)
    values
    (:batch_run_code,:batch_code,:table_source_map_id,:load_order,sysdate(),''1900-01-01'',-1,0,0,0);
end';
