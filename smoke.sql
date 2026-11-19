SELECT batch_id, s3tostage, quality_check, stagetodim, stage_dimtofact, s3_source_count, stage_count
FROM asnfdm.pap_data_process_log ORDER BY start_dt DESC LIMIT 1;

SELECT source_file_name, batch_id, count(*) FROM asnfdm.f_accera_prescreen GROUP BY 1, 2;

SELECT denial_reasons_raw, denial_reasons, count(*) FROM asnfdm.f_accera_prescreen GROUP BY 1, 2 ORDER BY 3 DESC;
SELECT insurance_types_raw, insurance_types, count(*) FROM asnfdm.f_accera_prescreen GROUP BY 1, 2 ORDER BY 3 DESC;
SELECT residency, insurance_medicare, count(*) FROM asnfdm.f_accera_prescreen GROUP BY 1, 2;
