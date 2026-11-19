/* =====================================================================
   PRESCREEN INQUIRIES (REGALORX) - one-time DDL
   Source: prescreen_inquiries Schema.xlsx

   Stage rule: COPY loads the file BY POSITION. The 19 source columns
   below must be in exactly the same order as the file's columns.
   S3tofactLoad.py then appends four audit columns, in this order:
   EXTERNAL_SOURCE, CREATED_BY, CREATED_DT, BATCH_ID.

   Data types are inferred from the schema descriptions (the workbook
   gives no types). Confirm them against a real file; items marked
   [confirm] are the likeliest to differ.
   ===================================================================== */

-- Stage: emptied and reloaded for every Prescreen file.
CREATE TABLE asnfdm.stg_accera_prescreen (
    id                            bigint,          -- source PK (auto_increment)
    created_at                    date,            -- MM/DD/YYYY in the file, e.g. 08/13/2026; needs DateStyle MDY
    outcome                       varchar(10),     -- pass / fail
    denial_reasons                text,            -- raw, as received; often not valid JSON, e.g. [residency"]"
    medication_name               varchar(255),
    fpl_reported                  numeric(10,2),   -- [confirm] plain number, no % sign
    household_income_reported     numeric(14,2),   -- [confirm] plain number, no $ or commas
    household_number_reported     integer,         -- [confirm] whole number
    insurance_commercial          varchar(30),     -- raw, as received: Yes / No / yes
    insurance_coverage            varchar(30),     -- commercial, medicaid, medicare, va, medicare_part_d, lis_extra_help, none
    insurance_government_program  varchar(30),     -- raw, as received: Yes / No / yes
    insurance_ihs_tribal          varchar(30),     -- raw, as received: Yes / No / yes
    insurance_medicaid            varchar(30),     -- raw, as received: Yes / No / yes
    insurance_medicare            varchar(30),     -- raw, as received: Yes / No / yes
    insurance_military_benefits   varchar(30),     -- raw, as received: Yes / No / yes
    insurance_sharing_ministry    varchar(30),     -- raw, as received: Yes / No / yes
    insurance_types               text,            -- raw, as received; may have the same JSON problems as denial_reasons
    residency                     varchar(30),     -- raw, as received: Yes / No / yes
    residency_region              varchar(30),     -- contiguous_us, alaska, hawaii, american_samoa, guam, puerto_rico, us_virgin_islands
    -- audit columns written by S3tofactLoad.py
    external_source               varchar(30),     -- 'REGALORX'
    created_by                    varchar(30),     -- 'S3toFactLoad.py'
    created_dt                    date,            -- load date
    batch_id                      varchar(15)
);

-- Fact: append-only history of every Prescreen file loaded. Never truncated.
-- One row per inquiry per file. Re-loading a file with the same name
-- replaces only that file's rows (see f_accera_prescreen.sql).
CREATE TABLE asnfdm.f_accera_prescreen (
    inquiry_id                    bigint          NOT NULL,   -- source "id"
    created_at                    date,            -- inquiry date (the file carries no time)
    outcome                       varchar(10),
    denial_reasons                text,            -- cleaned codes, comma-separated, e.g. 'residency, income_over_fpl'; '' = empty list, NULL = not sent
    denial_reasons_raw            text,            -- exactly as received, for audit
    medication_name               varchar(255),
    fpl_reported                  numeric(10,2),
    household_income_reported     numeric(14,2),
    household_number_reported     integer,
    insurance_commercial          varchar(30),     -- 'Yes' / 'No'; any other value kept as sent
    insurance_coverage            varchar(30),
    insurance_government_program  varchar(30),     -- 'Yes' / 'No'; any other value kept as sent
    insurance_ihs_tribal          varchar(30),     -- 'Yes' / 'No'; any other value kept as sent
    insurance_medicaid            varchar(30),     -- 'Yes' / 'No'; any other value kept as sent
    insurance_medicare            varchar(30),     -- 'Yes' / 'No'; any other value kept as sent
    insurance_military_benefits   varchar(30),     -- 'Yes' / 'No'; any other value kept as sent
    insurance_sharing_ministry    varchar(30),     -- 'Yes' / 'No'; any other value kept as sent
    insurance_types               text,            -- cleaned codes, e.g. 'medicare', 'none'; '' = empty list, NULL = not sent
    insurance_types_raw           text,            -- exactly as received, for audit
    residency                     varchar(30),     -- 'Yes' / 'No'; any other value kept as sent
    residency_region              varchar(30),
    -- NULL until Prescreen QC rules exist; then 'Y' or 'N'.
    qc_passed                     varchar(10)     CHECK (qc_passed IN ('Y', 'N')),
    external_source               varchar(30)     NOT NULL,
    created_by                    varchar(30),
    created_dt                    date,
    batch_id                      varchar(15)     NOT NULL,
    source_file_name              varchar(255)    NOT NULL,   -- lineage and safe re-load
    CONSTRAINT uq_f_accera_prescreen UNIQUE (external_source, inquiry_id, source_file_name)
);

CREATE INDEX ix_f_accera_prescreen_batch ON asnfdm.f_accera_prescreen (batch_id);

-- Turns a received code list into plain, comma-separated codes.
-- Used for denial_reasons and insurance_types.
--   '[residency"]"'                   -> 'residency'
--   '[Cancelled-No Response"]"'       -> 'Cancelled-No Response'
--   '[medicare"'                      -> 'medicare'
--   '[none"]'                         -> 'none'      (vendor sent the code "none")
--   '["residency","income_over_fpl"]' -> 'residency, income_over_fpl'
--   '[]'                              -> ''          (vendor sent an empty list)
--   blank in the file (NULL)          -> NULL        (vendor sent nothing)
-- The three cases 'none', '' and NULL stay distinct.
-- Brackets, quotes and spaces are trimmed only from the ends of each item,
-- so characters inside a code are kept. Assumes a code never contains a comma.
-- STRICT: a NULL input returns NULL without running the body.
CREATE OR REPLACE FUNCTION asnfdm.fn_clean_code_list(raw_value text)
RETURNS text
LANGUAGE sql
IMMUTABLE
STRICT
AS $fn$
    SELECT array_to_string(ARRAY(
               SELECT btrim(t.item, ' []"''')
               FROM unnest(string_to_array(raw_value, ',')) WITH ORDINALITY AS t(item, ord)
               WHERE btrim(t.item, ' []"''') <> ''
               ORDER BY t.ord
           ), ', ');
$fn$;

-- Normalises a Yes/No flag to the house style used in the PCD tables.
--   'Yes', 'yes', 'Y', 'TRUE', '1' -> 'Yes'
--   'No', 'no', 'N', 'FALSE', '0'  -> 'No'
--   blank (NULL)                   -> NULL
--   anything else                  -> kept as sent (trimmed), so a future QC
--                                     rule can flag it instead of losing it
CREATE OR REPLACE FUNCTION asnfdm.fn_clean_yes_no(raw_value text)
RETURNS varchar
LANGUAGE sql
IMMUTABLE
STRICT
AS $fn$
    SELECT CASE
               WHEN upper(btrim(raw_value)) IN ('YES', 'Y', 'TRUE', 'T', '1') THEN 'Yes'
               WHEN upper(btrim(raw_value)) IN ('NO', 'N', 'FALSE', 'F', '0') THEN 'No'
               WHEN btrim(raw_value) = '' THEN NULL
               ELSE btrim(raw_value)
           END;
$fn$;

-- Latest known version of each inquiry across all files.
-- batch_id starts with YYYYMMDDHHMMSS, so it sorts in load order.
CREATE VIEW asnfdm.v_accera_prescreen_latest AS
SELECT DISTINCT ON (external_source, inquiry_id) *
FROM asnfdm.f_accera_prescreen
ORDER BY external_source, inquiry_id, batch_id DESC;
