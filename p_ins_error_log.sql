CREATE OR REPLACE PROCEDURE curated.p_ins_error_log(batch_run_code string, batch_code string,table_source_map_id number(38,0),error_message string)
returns string
LANGUAGE SQL
EXECUTE AS OWNER
AS '
begin
    insert into error_log (batch_run_code,batch_code,table_source_map_id,error_message,error_date)
    values
    (:batch_run_code,:batch_code,:table_source_map_id,:error_message,sysdate());
end';
