
create or replace procedure curated.p_ins_batch_history_audit_batch_run (input_batch_code string, input_batch_run_code string)
returns string
language sql
execute as owner 
as 
begin
            insert into curated.batch_history_audit_batch_run(
                        table_source_map_id 
                       ,lower_bound_quantity 
                       ,upper_bound_quantity 
                       ,insert_average_row_quantity 
                       ,update_average_row_quantity
                       ,average_row_quantity 
                       ,upsert_quantity
                       ,max_row_quantity
                       ,min_row_quantity 
                       ,batch_run_tolerance_flag 
                       ,audit_create_date 
                       ,batch_code
                       ,batch_run_code
                        )
                 select a.table_source_map_id 
                       ,a.lower_bound_quantity 
                       ,a.upper_bound_quantity 
                       ,a.insert_average_row_quantity 
                       ,a.update_average_row_quantity
                       ,a.average_row_quantity 
                       ,a.upsert_quantity
                       ,a.max_row_quantity
                       ,a.min_row_quantity 
                       ,a.batch_run_tolerance_flag 
                       ,a.audit_create_date 
                       ,:input_batch_code
                       ,:input_batch_run_code
                  from curated.vw_batch_history_audit_batch_run_exec a
                       inner join curated.vw_table_source_map b 
                               on a.table_source_map_id         = b.table_source_map_id
                  where batch_code = :input_batch_code
                    and b.is_active = 1;

     return :input_batch_code;
end;
