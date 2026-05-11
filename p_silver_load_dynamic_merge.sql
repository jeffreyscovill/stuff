CREATE OR REPLACE PROCEDURE CURATED.P_SILVER_LOAD_DYNAMIC_MERGE("BATCH_CODE" VARCHAR(16777216), "BATCH_RUN_CODE" VARCHAR(16777216))
RETURNS VARIANT
LANGUAGE JAVASCRIPT
EXECUTE AS OWNER
AS ' 
var metadatadict = {};
var msg = "";
var exc_col = ["AUDIT_CREATE_USER", "AUDIT_CREATE_DATE"];
var cva;
var mergesql;
var deletesql;
var batchsql;
var starttime;
var endtime;
var statuscode;
var error_msg;

//Function for insert query into Batch_History
function insertBatchHistory(batch_run_code,batch_code, tgt,loadorder) {
    return snowflake.execute(
                  {
                  sqlText: "call curated.p_ins_batch_history(?,?,?,?)",
                  binds:[batch_run_code,batch_code,tgt,loadorder]
                  }
                );     
}
//Function for update query into BatchHistory
function updateBatchHistory(batch_run_code, tgt, statuscode,insert_row_quantity,update_row_quantity,delete_row_quantity) {
    return snowflake.execute(
                  {
                  sqlText: "call curated.p_upd_batch_history(?,?,?,?,?,?)",
                  binds:[batch_run_code,tgt,statuscode,insert_row_quantity,update_row_quantity,delete_row_quantity]
                  }
                );
}

//refresh external tables for batch
snowflake.execute(
              {
              sqlText: "call curated.p_refresh_external_tables_by_batch_code(?)",
              binds:[BATCH_CODE]
              }
            );

//refresh external stages for batch
snowflake.execute(
              {
              sqlText: "call curated.p_refresh_external_stages_by_batch_code(?)",
              binds:[BATCH_CODE]
              }
            );

//get list of views
view_list = "select * from CURATED.TABLE_SOURCE_MAP a join CURATED.TABLE_SOURCE_COLUMN_MAP b on a.TABLE_SOURCE_MAP_ID = b.TABLE_SOURCE_MAP_ID and IS_ACTIVE = ''1'' and BATCH_CODE = "+ BATCH_CODE + " order by a.LOAD_ORDER asc, a.TARGET_TABLE_NAME ";
stmt = snowflake.createStatement({ sqlText: view_list });
rs = stmt.execute();
while (rs.next()) {
    //tgt is our key for each unique merge. tgt = target db + target schema + target table
    var tgt = "X" + rs.getColumnValue("TABLE_SOURCE_MAP_ID");
    //if we dont already have a key with the value tgt we create a new template to store our info
    if (!metadatadict[tgt]) {
        metadatadict[tgt] = {
            target: { schema: rs.getColumnValue("TARGET_SCHEMA_NAME"), table: rs.getColumnValue("TARGET_TABLE_NAME") },
            source: { schema: rs.getColumnValue("SOURCE_SCHEMA_NAME"), table: rs.getColumnValue("SOURCE_TABLE_NAME") },
            columns: [],
            keycolumns: [],
            updatecolumns:[],
            deletecolumns:[],
            scdtype : {scdtype: rs.getColumnValue("SCD_TYPE")},
            loadorder : {loadorder: rs.getColumnValue("LOAD_ORDER")},
            tablesourcemapid : {tablesourcemapid: rs.getColumnValue("TABLE_SOURCE_MAP_ID")},
        };
    }
    //create list of key and nonkey columns
    metadatadict[tgt].columns.push({ target: rs.getColumnValue("TARGET_COLUMN_NAME"), source: rs.getColumnValue("SOURCE_COLUMN_NAME") });
    if (rs.getColumnValue("IS_MERGE_KEY") == "1")
    {    
        metadatadict[tgt].keycolumns.push({ target: rs.getColumnValue("TARGET_COLUMN_NAME"), source: rs.getColumnValue("TARGET_COLUMN_NAME") });
    } 
    if (rs.getColumnValue("IS_MERGE_KEY") == "0" && !exc_col.includes(rs.getColumnValue("TARGET_COLUMN_NAME")))     //Exclude columns mentioned in the exc_col list
    {    
        metadatadict[tgt].updatecolumns.push({ target: rs.getColumnValue("TARGET_COLUMN_NAME"), source: rs.getColumnValue("TARGET_COLUMN_NAME") });
    }
    if (rs.getColumnValue("IS_DELETE_KEY") == "1") 
    {    
        metadatadict[tgt].deletecolumns.push({ target: rs.getColumnValue("TARGET_COLUMN_NAME"), source: rs.getColumnValue("TARGET_COLUMN_NAME") });
    } 
}
for (i in metadatadict) {
try {
var error = 0;
//get target table path
var tgt = metadatadict[i].target.schema + "." + metadatadict[i].target.table;
//get source table path
var src = metadatadict[i].source.schema + "." + metadatadict[i].source.table;
var scdtype = metadatadict[i].scdtype.scdtype;
var loadorder = metadatadict[i].loadorder.loadorder;
var tablesourcemapid = metadatadict[i].tablesourcemapid.tablesourcemapid;
//vars for strings in merge statement
var keymapping = "";
var tgtcols = "";
var srccols = "";
var updatecols = "";
var deletecols = "";
var insert_row_quantity = 0;
var update_row_quantity = 0;
var delete_row_quantity = 0;
for (j in metadatadict[i].keycolumns) {
if (j == 0) {
keymapping += "src." + metadatadict[i].keycolumns[j].source + " = tgt." + metadatadict[i].keycolumns[j].target;
} else {
keymapping += " and src." + metadatadict[i].keycolumns[j].source + " = tgt." + metadatadict[i].keycolumns[j].target;
}
}
for (j in metadatadict[i].columns) {
if (j==0) {
  tgtcols += metadatadict[i].columns[j].target;
  srccols += "src." + metadatadict[i].columns[j].source;  
} 
else {
    tgtcols += " ," + metadatadict[i].columns[j].target;
    srccols += ",src." + metadatadict[i].columns[j].source;
     }
}
for (j in metadatadict[i].updatecolumns) {
if (j==0) {
updatecols += "tgt." + metadatadict[i].updatecolumns[j].target + " = src." + metadatadict[i].updatecolumns[j].source;
} else {
            updatecols += ", tgt." + metadatadict[i].updatecolumns[j].target + " = src." + metadatadict[i].updatecolumns[j].source;
            }
}
for (j in metadatadict[i].deletecolumns) {
if (j==0) {
deletecols += "tgt." + metadatadict[i].deletecolumns[j].target + " = src." + metadatadict[i].deletecolumns[j].source;
} else {
            deletecols += " and tgt." + metadatadict[i].deletecolumns[j].target + " = src." + metadatadict[i].deletecolumns[j].source;
            }
}

tgtcols += ", BATCH_CODE, BATCH_RUN_CODE";
srccols += ",''" + BATCH_CODE + "'',''" + BATCH_RUN_CODE + "''";
updatecols += ", tgt.BATCH_CODE = ''" + BATCH_CODE + "'', tgt.BATCH_RUN_CODE = ''" + BATCH_RUN_CODE + "''";
// for only insert
 if (scdtype == "TYPE 0")
          {
            //if no defined delete columns truncate table
            if(deletecols=="")
                {deletesql = "TRUNCATE TABLE "+ tgt;
                }
            else
                {deletesql = "DELETE from " + tgt + " tgt WHERE EXISTS(SELECT 1 FROM " + src + " src WHERE " + deletecols + ")";
                }
            mergesql = " INSERT INTO " + tgt + "(" + tgtcols + ") SELECT " + srccols + " FROM " + src + " src ";
           }
// for merge
    else
        {
   deletesql = "SELECT 1"   ;      
mergesql =
"MERGE INTO " +
tgt +
" tgt USING " +
src +
" src ON " +
keymapping +
" WHEN MATCHED THEN UPDATE SET "+updatecols+ " WHEN NOT MATCHED THEN INSERT (" +
tgtcols +
") VALUES (" +
srccols +
")";
            }
try {
insertBatchHistory(BATCH_RUN_CODE,BATCH_CODE, tablesourcemapid, loadorder);

snowflake.execute({ sqlText: deletesql });

var delete_result = snowflake.execute({
    sqlText: "select * from table(result_scan(last_query_id()))"
});

try {

    if (delete_result.next()) {
        delete_row_quantity = delete_result.getColumnValue("number of rows deleted") || 0;
    }

} catch (err) {

    if (scdtype == "TYPE 0" && deletecols == "") {
        delete_row_quantity = -1;

    } else if (deletesql.toUpperCase().includes("SELECT 1")) {
        delete_row_quantity = 0;

    } else {
        delete_row_quantity = 0;
    }
}

snowflake.execute({ sqlText: mergesql });
var merge_result = snowflake.execute({
    sqlText: "select * from table(result_scan(last_query_id()))"
});
if (merge_result.next()) {
    // insert count (merge or insert)
    try {
        insert_row_quantity = merge_result.getColumnValue("number of rows inserted") || 0;
    } catch (err) {
        insert_row_quantity = 0;
    }
    // update count (merge only if update existed)
    try {
        update_row_quantity = merge_result.getColumnValue("number of rows updated") || 0;
    } catch (err) {
        update_row_quantity = 0;
    }
}

updateBatchHistory(BATCH_RUN_CODE, tablesourcemapid, ''0'',insert_row_quantity,update_row_quantity,delete_row_quantity);
msg += mergesql;
} catch (err) {
msg += "Failed: " + err.message + " SQL COMMAND: " + mergesql +" "+deletesql+ "\\\\n";
error_msg = err.message.replace(/''/g, "");
throw err
}
} catch(err) {
updateBatchHistory(BATCH_RUN_CODE, tablesourcemapid, ''1'',''0'',''0'',''0'');
snowflake.execute(
              {
              sqlText: "call curated.p_ins_error_log(?,?,?,?)",
              binds:[BATCH_RUN_CODE,BATCH_CODE,tablesourcemapid,error_msg]
              }
            );
msg += error.message
}
}
return msg;
';
