/* =====================================================================
   PRESCREEN stage -> fact load (run by load_data_dimension_to_fact)
   Placeholders replaced by S3tofactLoad.py:
     $$csv_file$$     file name without the S3 path
     $$stg_table$$    asnfdm.stg_accera_prescreen
     $$source_name$$  REGALORX

   History model: every file is kept, rows are never updated.
   qc_passed is left NULL until Prescreen QC rules exist.
   ===================================================================== */

-- Makes re-processing safe: loading the same file again replaces its
-- rows instead of duplicating them. Other files' history is untouched.
DELETE FROM asnfdm.f_accera_prescreen
WHERE source_file_name = '$$csv_file$$'
  AND external_source  = '$$source_name$$';

INSERT INTO asnfdm.f_accera_prescreen (
    inquiry_id, created_at, outcome, denial_reasons, denial_reasons_raw, medication_name,
    fpl_reported, household_income_reported, household_number_reported,
    insurance_commercial, insurance_coverage, insurance_government_program,
    insurance_ihs_tribal, insurance_medicaid, insurance_medicare,
    insurance_military_benefits, insurance_sharing_ministry, insurance_types, insurance_types_raw,
    residency, residency_region,
    external_source, created_by, created_dt, batch_id,
    source_file_name
)
SELECT
    id, created_at, outcome, asnfdm.fn_clean_code_list(denial_reasons), denial_reasons, medication_name,
    fpl_reported, household_income_reported, household_number_reported,
    asnfdm.fn_clean_yes_no(insurance_commercial), insurance_coverage, asnfdm.fn_clean_yes_no(insurance_government_program),
    asnfdm.fn_clean_yes_no(insurance_ihs_tribal), asnfdm.fn_clean_yes_no(insurance_medicaid), asnfdm.fn_clean_yes_no(insurance_medicare),
    asnfdm.fn_clean_yes_no(insurance_military_benefits), asnfdm.fn_clean_yes_no(insurance_sharing_ministry), asnfdm.fn_clean_code_list(insurance_types), insurance_types,
    asnfdm.fn_clean_yes_no(residency), residency_region,
    external_source, created_by, created_dt, batch_id,
    '$$csv_file$$'
FROM $$stg_table$$;
