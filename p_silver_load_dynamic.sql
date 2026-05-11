CREATE OR REPLACE PROCEDURE CURATED.P_SILVER_LOAD_DYNAMIC("BATCH_CODE" VARCHAR(16777216))
RETURNS VARIANT
LANGUAGE SQL
EXECUTE AS OWNER
AS
$$
declare
    batch_run_code STRING;
    msg STRING;
    merge_msg STRING;
    audit_msg STRING;
    stats_msg STRING;
    metric_msg STRING;
begin
    -- Generate batch_run_code
    select UUID_STRING() into :batch_run_code;
    msg := 'Batch run code: ' || batch_run_code || ' | ';

    -- Call silver load merge proc
    call curated.p_silver_load_dynamic_merge(:BATCH_CODE, :batch_run_code) into :merge_msg;
    msg := msg || 'Silver Load Merge Statement: ' || merge_msg || ' | ';
    
    -- Run RI Audit
    begin
        call curated.p_ins_batch_history_audit_ri(:BATCH_CODE, :batch_run_code);
        audit_msg := 'RI Audit Procedure executed successfully.';
    exception
        when other then
            audit_msg := 'RI Audit Proc failed: ' || :SQLERRM;
    end;
    msg := msg || audit_msg;

    --Load row stats information
    begin
        call curated.p_ins_batch_history_audit_batch_run(:BATCH_CODE, :batch_run_code);
        stats_msg := 'Stats Audit Procedure executed successfully.';
    exception
        when other then
            stats_msg := 'Status Audit Proc failed: ' || :SQLERRM;
    end;
    msg := msg || audit_msg || stats_msg;

    --specific metric validations for important tables
    begin
        call curated.p_ins_batch_history_audit_table_source_map(:BATCH_CODE, :batch_run_code);
        metric_msg := 'Status Metric Audit Procedure executed successfully.';
    exception
        when other then
            metric_msg := 'Status Metric Audit Proc failed: ' || :SQLERRM;
    end;
    msg := msg || audit_msg || stats_msg || metric_msg;

    return msg;
end;
$$;
