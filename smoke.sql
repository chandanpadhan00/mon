SELECT asnfdm.fn_clean_code_list('[residency"]"')            AS a,  -- residency
       asnfdm.fn_clean_code_list('[Cancelled-No Response"]"') AS b,  -- Cancelled-No Response
       asnfdm.fn_clean_code_list('[]') = ''                    AS c,  -- true
       asnfdm.fn_clean_code_list(NULL) IS NULL                 AS d,  -- true
       asnfdm.fn_clean_yes_no('yes')                           AS e,  -- Yes
       asnfdm.fn_clean_yes_no('No')                            AS f;  -- No

SELECT table_name FROM information_schema.tables
WHERE table_schema = 'asnfdm'
  AND table_name IN ('stg_accera_prescreen', 'f_accera_prescreen', 'v_accera_prescreen_latest');
-- expect 3 rows
