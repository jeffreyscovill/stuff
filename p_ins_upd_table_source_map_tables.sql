CREATE OR REPLACE PROCEDURE CURATED.p_ins_upd_table_source_map_tables(input_table_name STRING, input_batch_code STRING)
RETURNS VARCHAR
LANGUAGE SQL
EXECUTE AS OWNER
AS 
BEGIN
--Set default values
        LET source_schema_name VARCHAR := 'CURATED_STG';
        LET source_table_name VARCHAR := concat('VW_STG_',:input_table_name);
        LET target_schema_name VARCHAR := 'CURATED';
        LET scd_type VARCHAR := 'TYPE 1';

        --call procedure using default values
        call curated.p_ins_upd_table_source_map_tables(:input_table_name,:input_batch_code,:source_schema_name,:source_table_name,:target_schema_name,:scd_type);
        
    RETURN input_table_name;
END
