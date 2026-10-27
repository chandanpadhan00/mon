-- =====================================================================
-- ASNF Monitoring Rule Engine (PostgreSQL)
-- Source view: asnfdm.pcd_phi_consolidated_vw
-- Monitored population: asnf_monitoring.monitored_cases (source view filtered to
--   case_status in the in_scope_case_statuses config -- Approved/Pending)
--
-- Design contract:
--   1. One rule = one detector function. Detectors never call each other.
--   2. Every detector returns the same shape:
--        (case_id, patient_id, rule_id, points, evidence jsonb)
--   3. Every threshold lives in rule_config, never hardcoded in a detector.
--   4. Adding rule #21 = write detect_<id>(), insert into rule_registry +
--      rule_config. The orchestrator and scoring view need zero edits.
-- =====================================================================

CREATE EXTENSION IF NOT EXISTS pgcrypto;   -- gen_random_uuid()
CREATE EXTENSION IF NOT EXISTS fuzzystrmatch; -- levenshtein/soundex, used by identity-graph rules

CREATE SCHEMA IF NOT EXISTS asnf_monitoring;

-- ---------------------------------------------------------------------
-- 1. Registry & config (the "thresholds are config, not code" layer)
-- ---------------------------------------------------------------------

CREATE TABLE IF NOT EXISTS asnf_monitoring.rule_registry (
    rule_id        TEXT PRIMARY KEY,
    lens           TEXT NOT NULL CHECK (lens IN ('contradiction','timeline','graph','geography')),
    description    TEXT NOT NULL,
    active         BOOLEAN NOT NULL DEFAULT true,
    -- 'sql' = has a detect_<rule_id>() function, dispatched by run_all_rules().
    -- 'python' = written directly into asnf_monitoring.flags by an external script
    -- (e.g. identity_ring_detector.py). run_all_rules() must skip these --
    -- there is no detect_<rule_id>() function to call.
    implementation TEXT NOT NULL DEFAULT 'sql' CHECK (implementation IN ('sql','python')),
    created_at     TIMESTAMP NOT NULL DEFAULT now()
);

CREATE TABLE IF NOT EXISTS asnf_monitoring.rule_config (
    rule_id     TEXT NOT NULL REFERENCES asnf_monitoring.rule_registry(rule_id),
    param_name  TEXT NOT NULL,
    param_value TEXT NOT NULL,
    updated_at  TIMESTAMP NOT NULL DEFAULT now(),
    PRIMARY KEY (rule_id, param_name)
);

CREATE OR REPLACE FUNCTION asnf_monitoring.get_config_numeric(p_rule_id text, p_param text)
RETURNS numeric LANGUAGE sql STABLE AS $$
    SELECT param_value::numeric
    FROM asnf_monitoring.rule_config
    WHERE rule_id = p_rule_id AND param_name = p_param;
$$;

CREATE OR REPLACE FUNCTION asnf_monitoring.get_config_text(p_rule_id text, p_param text)
RETURNS text LANGUAGE sql STABLE AS $$
    SELECT param_value
    FROM asnf_monitoring.rule_config
    WHERE rule_id = p_rule_id AND param_name = p_param;
$$;

-- Several "_reported" fields (patient_income_reported, patient_household_size_reported)
-- are varchar in the real view, not numeric, and occasionally carry stray
-- formatting ($, commas, whitespace). Detectors that do arithmetic on them
-- must go through this instead of casting directly -- a bad value here
-- should drop the row from consideration, not crash the whole rule.
CREATE OR REPLACE FUNCTION asnf_monitoring.safe_numeric(p_value text)
RETURNS numeric
LANGUAGE plpgsql IMMUTABLE AS $$
DECLARE
    v_cleaned text;
BEGIN
    IF p_value IS NULL THEN
        RETURN NULL;
    END IF;
    v_cleaned := regexp_replace(btrim(p_value), '[^0-9.\-]', '', 'g');
    IF v_cleaned = '' THEN
        RETURN NULL;
    END IF;
    RETURN v_cleaned::numeric;
EXCEPTION WHEN others THEN
    RETURN NULL;
END;
$$;

-- ---------------------------------------------------------------------
-- 2. Uniform output + audit feedback loop
-- ---------------------------------------------------------------------

CREATE TABLE IF NOT EXISTS asnf_monitoring.flags (
    flag_id     BIGSERIAL PRIMARY KEY,
    run_id      UUID NOT NULL,
    case_id     TEXT NOT NULL,
    patient_id  TEXT,
    rule_id     TEXT NOT NULL REFERENCES asnf_monitoring.rule_registry(rule_id),
    points      NUMERIC NOT NULL,
    evidence    JSONB NOT NULL,
    detected_at TIMESTAMP NOT NULL DEFAULT now()
);
CREATE INDEX IF NOT EXISTS idx_flags_case ON asnf_monitoring.flags (case_id);
CREATE INDEX IF NOT EXISTS idx_flags_rule ON asnf_monitoring.flags (rule_id);
CREATE INDEX IF NOT EXISTS idx_flags_run  ON asnf_monitoring.flags (run_id);

-- Investigator writes back here after reviewing a flagged case.
-- This is what turns "rules that fire a lot" into "rules that catch real issues".
CREATE TABLE IF NOT EXISTS asnf_monitoring.audit_outcomes (
    case_id     TEXT PRIMARY KEY,
    outcome     TEXT NOT NULL CHECK (outcome IN ('CONFIRMED','FALSE_POSITIVE','INCONCLUSIVE')),
    audited_by  TEXT,
    audited_at  TIMESTAMP NOT NULL DEFAULT now(),
    notes       TEXT
);

-- ---------------------------------------------------------------------
-- 3. Rule registry seed
-- ---------------------------------------------------------------------

INSERT INTO asnf_monitoring.rule_registry (rule_id, lens, description) VALUES
('CON01','contradiction','Reported income understated vs. validated income beyond tolerance'),
('CON02','contradiction','Reported FPL disagrees with validated FPL beyond a point-spread tolerance'),
('CON03','contradiction','Reported household size exceeds validated household size (FPL denominator inflation)'),
('CON04','contradiction','Overnetworth flag says under-limit but reported net worth contradicts it'),
('CON05','contradiction','Active primary insurance on file was excluded from determination on an approved case'),
('TML01','timeline','Determination date precedes file receipt date -- physically impossible ordering'),
('TML02','timeline','Shipment occurred outside the eligibility window'),
('TML03','timeline','Receipt-to-ship window too short for real verification to have occurred'),
('TML04','timeline','Reapplication filed too soon after a prior denial (denial-shopping)'),
('TML05','timeline','Multiple case_ids opened under the same hub_case_id in a short window (quantity-limit churn)'),
('GRF01','graph','Single email address fans out across many distinct patients'),
('GRF02','graph','Single office contact fans out across many distinct prescribers (NPIs)'),
('GRF03','graph','Many distinct surnames share one address -- ring indicator'),
('GRF04','graph','Baseline: many distinct cases share one address (legacy rule, low specificity, kept for continuity)'),
('GEO01','geography','Prescriber state and patient state diverge, at volume'),
('GEO02','geography','Address matches known institutional/correctional facility patterns')
ON CONFLICT (rule_id) DO NOTHING;

-- ---------------------------------------------------------------------
-- 4. Threshold config seed -- every number below is the only place it lives
-- ---------------------------------------------------------------------

INSERT INTO asnf_monitoring.rule_config (rule_id, param_name, param_value) VALUES
('CON01','points','10'),
('CON01','delta_pct','0.25'),

('CON02','points','8'),
('CON02','delta_points','15'),

('CON03','points','8'),
('CON03','min_diff','1'),

('CON04','points','8'),
('CON04','net_worth_limit','1000000'),   -- placeholder: set to actual program ceiling

('CON05','points','15'),

('TML01','points','30'),

('TML02','points','15'),

('TML03','points','12'),
('TML03','max_days','2'),

('TML04','points','10'),
('TML04','max_days','14'),

('TML05','points','10'),
('TML05','min_subcases','3'),
('TML05','window_days','30'),

('GRF01','points','12'),
('GRF01','min_patients','4'),

('GRF02','points','10'),
('GRF02','min_prescribers','4'),

('GRF03','points','18'),
('GRF03','min_surnames','3'),

('GRF04','points','5'),
('GRF04','min_cases','6'),

('GEO01','points','12'),
('GEO01','min_cases','6'),

('GEO02','points','25'),
('GEO02','patterns','CORRECTION|PRISON|DETENTION| FCI | USP |COUNTY JAIL| DOC |STATE PEN|REHABILITATION CTR')
ON CONFLICT (rule_id, param_name) DO NOTHING;

-- ---------------------------------------------------------------------
-- 4b. Population scope -- the "initial level" filter applied before ANY rule
--     runs. Only cases whose case_status is in this list are monitored.
--     Lives in config (pipe-delimited, matched case-insensitively), not in
--     the rules: widening or narrowing scope is a data change.
-- ---------------------------------------------------------------------

CREATE TABLE IF NOT EXISTS asnf_monitoring.global_config (
    param_name  TEXT PRIMARY KEY,
    param_value TEXT NOT NULL,
    updated_at  TIMESTAMP NOT NULL DEFAULT now()
);

INSERT INTO asnf_monitoring.global_config (param_name, param_value) VALUES
('in_scope_case_statuses','APPROVED|PENDING')
ON CONFLICT (param_name) DO NOTHING;

-- Every SQL detector (and the Python identity-ring detector) reads from this
-- view instead of the raw source view. Exception: TML04 reads the raw view for
-- its prior-case lookback, since the denied case it looks for is out of scope
-- by definition -- see the note inside detect_tml04().
-- Cases with a NULL case_status are excluded (NULL never matches the list).
-- Note: SELECT t.* is expanded when the view is created, so if the source
-- view gains/loses columns, re-run this file to refresh it.
CREATE OR REPLACE VIEW asnf_monitoring.monitored_cases AS
SELECT t.*
FROM asnfdm.pcd_phi_consolidated_vw t
WHERE upper(btrim(t.case_status)) = ANY (
    string_to_array(
        upper((SELECT g.param_value FROM asnf_monitoring.global_config g
               WHERE g.param_name = 'in_scope_case_statuses')),
        '|'
    )
);

-- =====================================================================
-- 5. DETECTORS -- one rule, one function, uniform output, config-driven
-- =====================================================================

-- ---------------- CONTRADICTION LENS ----------------------------------
-- Every _reported field has a _validated twin. The signal is in the gap.

CREATE OR REPLACE FUNCTION asnf_monitoring.detect_con01()
RETURNS TABLE (case_id text, patient_id text, rule_id text, points numeric, evidence jsonb)
LANGUAGE sql STABLE AS $$
    SELECT
        t.case_id, t.patient_id, 'CON01',
        asnf_monitoring.get_config_numeric('CON01','points'),
        jsonb_build_object(
            'patient_income_reported',  t.patient_income_reported,
            'patient_income_validated', t.patient_income_validated,
            'delta_pct', round(((t.patient_income_validated - asnf_monitoring.safe_numeric(t.patient_income_reported))
                                  / NULLIF(asnf_monitoring.safe_numeric(t.patient_income_reported),0))::numeric, 3)
        )
    FROM asnf_monitoring.monitored_cases t
    WHERE t.patient_income_reported IS NOT NULL
      AND t.patient_income_validated IS NOT NULL
      AND asnf_monitoring.safe_numeric(t.patient_income_reported) IS NOT NULL
      AND (t.patient_income_validated - asnf_monitoring.safe_numeric(t.patient_income_reported))
          > asnf_monitoring.get_config_numeric('CON01','delta_pct') * NULLIF(asnf_monitoring.safe_numeric(t.patient_income_reported),0);
$$;

CREATE OR REPLACE FUNCTION asnf_monitoring.detect_con02()
RETURNS TABLE (case_id text, patient_id text, rule_id text, points numeric, evidence jsonb)
LANGUAGE sql STABLE AS $$
    SELECT
        t.case_id, t.patient_id, 'CON02',
        asnf_monitoring.get_config_numeric('CON02','points'),
        jsonb_build_object(
            'patient_fpl_reported',  t.patient_fpl_reported,
            'patient_fpl_validated', t.patient_fpl_validated,
            'point_diff', t.patient_fpl_validated - t.patient_fpl_reported
        )
    FROM asnf_monitoring.monitored_cases t
    WHERE t.patient_fpl_reported IS NOT NULL
      AND t.patient_fpl_validated IS NOT NULL
      AND (t.patient_fpl_validated - t.patient_fpl_reported)
          > asnf_monitoring.get_config_numeric('CON02','delta_points');
$$;

CREATE OR REPLACE FUNCTION asnf_monitoring.detect_con03()
RETURNS TABLE (case_id text, patient_id text, rule_id text, points numeric, evidence jsonb)
LANGUAGE sql STABLE AS $$
    SELECT
        t.case_id, t.patient_id, 'CON03',
        asnf_monitoring.get_config_numeric('CON03','points'),
        jsonb_build_object(
            'household_reported',  t.patient_household_size_reported,
            'household_validated', t.patient_household_size_validated
        )
    FROM asnf_monitoring.monitored_cases t
    WHERE t.patient_household_size_reported IS NOT NULL
      AND t.patient_household_size_validated IS NOT NULL
      AND asnf_monitoring.safe_numeric(t.patient_household_size_reported) IS NOT NULL
      AND (asnf_monitoring.safe_numeric(t.patient_household_size_reported) - t.patient_household_size_validated)
          >= asnf_monitoring.get_config_numeric('CON03','min_diff');
$$;

CREATE OR REPLACE FUNCTION asnf_monitoring.detect_con04()
RETURNS TABLE (case_id text, patient_id text, rule_id text, points numeric, evidence jsonb)
LANGUAGE sql STABLE AS $$
    SELECT
        t.case_id, t.patient_id, 'CON04',
        asnf_monitoring.get_config_numeric('CON04','points'),
        jsonb_build_object(
            'patient_net_worth_reported', t.patient_net_worth_reported,
            'overnetworth_flag', t.overnetworth
        )
    FROM asnf_monitoring.monitored_cases t
    WHERE t.patient_net_worth_reported IS NOT NULL
      AND btrim(upper(t.overnetworth::text)) IN ('N','FALSE','0')
      AND t.patient_net_worth_reported > asnf_monitoring.get_config_numeric('CON04','net_worth_limit');
$$;

CREATE OR REPLACE FUNCTION asnf_monitoring.detect_con05()
RETURNS TABLE (case_id text, patient_id text, rule_id text, points numeric, evidence jsonb)
LANGUAGE sql STABLE AS $$
    SELECT
        t.case_id, t.patient_id, 'CON05',
        asnf_monitoring.get_config_numeric('CON05','points'),
        jsonb_build_object(
            'primary_insurance_payer', t.primary_medical_insurance_payer_or_insurer,
            'used_for_determination',  t.pri_medical_insurance_used_for_determination,
            'case_status', t.case_status
        )
    FROM asnf_monitoring.monitored_cases t
    WHERE t.primary_medical_insurance_payer_or_insurer IS NOT NULL
      AND upper(btrim(t.pri_medical_insurance_used_for_determination)) = 'N'
      AND upper(btrim(t.case_status)) = 'APPROVED';
$$;

-- ---------------- TIMELINE LENS ----------------------------------------
-- Legitimate cases move intake -> verification -> determination -> ship,
-- in order, with plausible gaps. Abuse compresses or reorders the sequence.

CREATE OR REPLACE FUNCTION asnf_monitoring.detect_tml01()
RETURNS TABLE (case_id text, patient_id text, rule_id text, points numeric, evidence jsonb)
LANGUAGE sql STABLE AS $$
    SELECT
        t.case_id, t.patient_id, 'TML01',
        asnf_monitoring.get_config_numeric('TML01','points'),
        jsonb_build_object(
            'file_receipt_date_time',  t.file_receipt_date_time,
            'case_determination_date', t.case_determination_date
        )
    FROM asnf_monitoring.monitored_cases t
    WHERE t.file_receipt_date_time IS NOT NULL
      AND t.case_determination_date IS NOT NULL
      AND t.case_determination_date < t.file_receipt_date_time::date;
$$;

CREATE OR REPLACE FUNCTION asnf_monitoring.detect_tml02()
RETURNS TABLE (case_id text, patient_id text, rule_id text, points numeric, evidence jsonb)
LANGUAGE sql STABLE AS $$
    SELECT
        t.case_id, t.patient_id, 'TML02',
        asnf_monitoring.get_config_numeric('TML02','points'),
        jsonb_build_object(
            'last_ship_date', t.last_ship_date,
            'eligibility_start_date', t.eligibility_start_date,
            'eligibility_end_date', t.eligibility_end_date
        )
    FROM asnf_monitoring.monitored_cases t
    WHERE t.last_ship_date IS NOT NULL
      AND (t.last_ship_date < t.eligibility_start_date OR t.last_ship_date > t.eligibility_end_date);
$$;

CREATE OR REPLACE FUNCTION asnf_monitoring.detect_tml03()
RETURNS TABLE (case_id text, patient_id text, rule_id text, points numeric, evidence jsonb)
LANGUAGE sql STABLE AS $$
    SELECT
        t.case_id, t.patient_id, 'TML03',
        asnf_monitoring.get_config_numeric('TML03','points'),
        jsonb_build_object(
            'file_receipt_date_time', t.file_receipt_date_time,
            'last_ship_date', t.last_ship_date,
            'days_receipt_to_ship', (t.last_ship_date - t.file_receipt_date_time::date)
        )
    FROM asnf_monitoring.monitored_cases t
    WHERE t.file_receipt_date_time IS NOT NULL
      AND t.last_ship_date IS NOT NULL
      AND (t.last_ship_date - t.file_receipt_date_time::date)
          <= asnf_monitoring.get_config_numeric('TML03','max_days');
$$;

CREATE OR REPLACE FUNCTION asnf_monitoring.detect_tml04()
RETURNS TABLE (case_id text, patient_id text, rule_id text, points numeric, evidence jsonb)
LANGUAGE sql STABLE AS $$
    -- Reads the full, unscoped source view on purpose: the "prior denied case"
    -- this rule looks for is, by definition, outside the Approved/Pending scope
    -- filter. The scope filter is applied to the case being flagged (the new
    -- one) via the EXISTS check at the bottom, not to the history lookback.
    WITH ordered AS (
        SELECT
            t.case_id, t.patient_id, t.case_status, t.case_created_date,
            LAG(t.case_status) OVER (PARTITION BY t.patient_id ORDER BY t.case_created_date) AS prior_status,
            LAG(t.case_created_date) OVER (PARTITION BY t.patient_id ORDER BY t.case_created_date) AS prior_date
        FROM asnfdm.pcd_phi_consolidated_vw t
        WHERE t.patient_id IS NOT NULL AND t.case_created_date IS NOT NULL
    )
    SELECT
        o.case_id, o.patient_id, 'TML04',
        asnf_monitoring.get_config_numeric('TML04','points'),
        jsonb_build_object(
            'prior_status', o.prior_status,
            'prior_case_date', o.prior_date,
            'this_case_date', o.case_created_date,
            'days_since_prior_case', (o.case_created_date - o.prior_date)
        )
    FROM ordered o
    WHERE upper(btrim(o.prior_status)) IN ('DENIED','REJECTED')
      AND (o.case_created_date - o.prior_date) <= asnf_monitoring.get_config_numeric('TML04','max_days')
      AND EXISTS (SELECT 1 FROM asnf_monitoring.monitored_cases m WHERE m.case_id = o.case_id);
$$;

CREATE OR REPLACE FUNCTION asnf_monitoring.detect_tml05()
RETURNS TABLE (case_id text, patient_id text, rule_id text, points numeric, evidence jsonb)
LANGUAGE sql STABLE AS $$
    WITH churn AS (
        SELECT
            hub_case_id,
            COUNT(DISTINCT case_id) AS case_count,
            MAX(file_receipt_date_time) - MIN(file_receipt_date_time) AS span_days
        FROM asnf_monitoring.monitored_cases
        WHERE hub_case_id IS NOT NULL
        GROUP BY hub_case_id
        HAVING COUNT(DISTINCT case_id) >= asnf_monitoring.get_config_numeric('TML05','min_subcases')
           AND (MAX(file_receipt_date_time) - MIN(file_receipt_date_time))
               <= asnf_monitoring.get_config_numeric('TML05','window_days')
    )
    SELECT
        t.case_id, t.patient_id, 'TML05',
        asnf_monitoring.get_config_numeric('TML05','points'),
        jsonb_build_object('hub_case_id', t.hub_case_id, 'case_count', c.case_count, 'span_days', c.span_days, 'drug', t.drug)
    FROM asnf_monitoring.monitored_cases t
    JOIN churn c ON c.hub_case_id = t.hub_case_id;
$$;

-- ---------------- GRAPH LENS --------------------------------------------
-- Count distinct entities per shared key -- and count the RIGHT entity.
-- GRF04 counts cases per address (the weak baseline). GRF03 counts distinct
-- surnames per address using the identical query shape -- that's the ring.

CREATE OR REPLACE FUNCTION asnf_monitoring.detect_grf01()
RETURNS TABLE (case_id text, patient_id text, rule_id text, points numeric, evidence jsonb)
LANGUAGE sql STABLE AS $$
    WITH fanout AS (
        SELECT email_addr, COUNT(DISTINCT patient_id) AS distinct_patients
        FROM asnf_monitoring.monitored_cases
        WHERE email_addr IS NOT NULL
        GROUP BY email_addr
        HAVING COUNT(DISTINCT patient_id) >= asnf_monitoring.get_config_numeric('GRF01','min_patients')
    )
    SELECT
        t.case_id, t.patient_id, 'GRF01',
        asnf_monitoring.get_config_numeric('GRF01','points'),
        jsonb_build_object('email_addr', t.email_addr, 'distinct_patients_sharing_email', f.distinct_patients)
    FROM asnf_monitoring.monitored_cases t
    JOIN fanout f ON f.email_addr = t.email_addr;
$$;

CREATE OR REPLACE FUNCTION asnf_monitoring.detect_grf02()
RETURNS TABLE (case_id text, patient_id text, rule_id text, points numeric, evidence jsonb)
LANGUAGE sql STABLE AS $$
    WITH fanout AS (
        SELECT office_contact_first_name, office_contact_last_name,
               COUNT(DISTINCT md_npi) AS distinct_prescribers
        FROM asnf_monitoring.monitored_cases
        WHERE office_contact_first_name IS NOT NULL
        GROUP BY 1, 2
        HAVING COUNT(DISTINCT md_npi) >= asnf_monitoring.get_config_numeric('GRF02','min_prescribers')
    )
    SELECT
        t.case_id, t.patient_id, 'GRF02',
        asnf_monitoring.get_config_numeric('GRF02','points'),
        jsonb_build_object(
            'office_contact', t.office_contact_first_name || ' ' || t.office_contact_last_name,
            'distinct_prescribers_sharing_contact', f.distinct_prescribers,
            'md_npi', t.md_npi
        )
    FROM asnf_monitoring.monitored_cases t
    JOIN fanout f
      ON f.office_contact_first_name = t.office_contact_first_name
     AND f.office_contact_last_name  = t.office_contact_last_name;
$$;

CREATE OR REPLACE FUNCTION asnf_monitoring.detect_grf03()
RETURNS TABLE (case_id text, patient_id text, rule_id text, points numeric, evidence jsonb)
LANGUAGE sql STABLE AS $$
    WITH fanout AS (
        SELECT addr1, addr_zip, COUNT(DISTINCT upper(btrim(lname))) AS distinct_surnames
        FROM asnf_monitoring.monitored_cases
        WHERE addr1 IS NOT NULL AND lname IS NOT NULL
        GROUP BY addr1, addr_zip
        HAVING COUNT(DISTINCT upper(btrim(lname))) >= asnf_monitoring.get_config_numeric('GRF03','min_surnames')
    )
    SELECT
        t.case_id, t.patient_id, 'GRF03',
        asnf_monitoring.get_config_numeric('GRF03','points'),
        jsonb_build_object('addr1', t.addr1, 'addr_zip', t.addr_zip, 'distinct_surnames_at_address', f.distinct_surnames)
    FROM asnf_monitoring.monitored_cases t
    JOIN fanout f ON f.addr1 = t.addr1 AND f.addr_zip = t.addr_zip;
$$;

CREATE OR REPLACE FUNCTION asnf_monitoring.detect_grf04()
RETURNS TABLE (case_id text, patient_id text, rule_id text, points numeric, evidence jsonb)
LANGUAGE sql STABLE AS $$
    WITH fanout AS (
        SELECT drug, addr1, addr_city, addr_state, addr_zip, COUNT(DISTINCT case_id) AS number_cases
        FROM asnf_monitoring.monitored_cases
        WHERE addr1 IS NOT NULL
        GROUP BY drug, addr1, addr_city, addr_state, addr_zip
        HAVING COUNT(DISTINCT case_id) >= asnf_monitoring.get_config_numeric('GRF04','min_cases')
    )
    SELECT
        t.case_id, t.patient_id, 'GRF04',
        asnf_monitoring.get_config_numeric('GRF04','points'),
        jsonb_build_object('drug', t.drug, 'addr1', t.addr1, 'number_cases_at_address', f.number_cases)
    FROM asnf_monitoring.monitored_cases t
    JOIN fanout f
      ON f.drug = t.drug AND f.addr1 = t.addr1 AND f.addr_city = t.addr_city AND f.addr_zip = t.addr_zip;
$$;

-- ---------------- GEOGRAPHY LENS ----------------------------------------
-- Patient, prescriber, and pharmacy should mostly be near each other.
-- Scatter is the anomaly.

CREATE OR REPLACE FUNCTION asnf_monitoring.detect_geo01()
RETURNS TABLE (case_id text, patient_id text, rule_id text, points numeric, evidence jsonb)
LANGUAGE sql STABLE AS $$
    WITH fanout AS (
        SELECT md_npi, md_state, patient_state, COUNT(DISTINCT case_id) AS cases
        FROM asnf_monitoring.monitored_cases
        WHERE md_state IS NOT NULL AND patient_state IS NOT NULL AND md_state <> patient_state
        GROUP BY md_npi, md_state, patient_state
        HAVING COUNT(DISTINCT case_id) >= asnf_monitoring.get_config_numeric('GEO01','min_cases')
    )
    SELECT
        t.case_id, t.patient_id, 'GEO01',
        asnf_monitoring.get_config_numeric('GEO01','points'),
        jsonb_build_object('md_npi', t.md_npi, 'md_state', t.md_state, 'patient_state', t.patient_state, 'cluster_case_count', f.cases)
    FROM asnf_monitoring.monitored_cases t
    JOIN fanout f ON f.md_npi = t.md_npi AND f.md_state = t.md_state AND f.patient_state = t.patient_state;
$$;

CREATE OR REPLACE FUNCTION asnf_monitoring.detect_geo02()
RETURNS TABLE (case_id text, patient_id text, rule_id text, points numeric, evidence jsonb)
LANGUAGE sql STABLE AS $$
    SELECT
        t.case_id, t.patient_id, 'GEO02',
        asnf_monitoring.get_config_numeric('GEO02','points'),
        jsonb_build_object('addr1', t.addr1, 'addr_city', t.addr_city, 'addr_state', t.addr_state)
    FROM asnf_monitoring.monitored_cases t
    WHERE t.addr1 IS NOT NULL
      AND EXISTS (
          SELECT 1
          FROM unnest(string_to_array(asnf_monitoring.get_config_text('GEO02','patterns'), '|')) AS pat
          WHERE upper(t.addr1) LIKE '%' || pat || '%'
      );
$$;

-- =====================================================================
-- 6. Orchestrator -- dispatches to detect_<lower(rule_id)>() by convention.
--    Adding a rule never requires editing this function.
-- =====================================================================

CREATE OR REPLACE FUNCTION asnf_monitoring.run_all_rules()
RETURNS uuid
LANGUAGE plpgsql
AS $$
DECLARE
    v_run_id uuid := gen_random_uuid();
    v_rule   RECORD;
BEGIN
    FOR v_rule IN SELECT rule_id FROM asnf_monitoring.rule_registry WHERE active AND implementation = 'sql' LOOP
        IF v_rule.rule_id !~ '^[A-Za-z0-9_]+$' THEN
            RAISE EXCEPTION 'Unsafe rule_id blocked from dynamic dispatch: %', v_rule.rule_id;
        END IF;

        EXECUTE format(
            'INSERT INTO asnf_monitoring.flags (run_id, case_id, patient_id, rule_id, points, evidence)
             SELECT %L, case_id, patient_id, rule_id, points, evidence
             FROM asnf_monitoring.detect_%s()',
            v_run_id, lower(v_rule.rule_id)
        );
    END LOOP;
    RETURN v_run_id;
END;
$$;

-- Same dispatch logic as run_all_rules(), scoped to a caller-supplied list of
-- rule_ids instead of every active SQL rule -- for testing or re-running a
-- subset (e.g. just the rules aligned to the 100-series) without touching
-- flags for the other rules. Still only ever dispatches rules that are
-- active and implementation = 'sql'; passing a Python-owned or inactive
-- rule_id here is silently a no-op for that id, not an error.
CREATE OR REPLACE FUNCTION asnf_monitoring.run_selected_rules(p_rule_ids text[])
RETURNS uuid
LANGUAGE plpgsql
AS $$
DECLARE
    v_run_id uuid := gen_random_uuid();
    v_rule   RECORD;
BEGIN
    FOR v_rule IN
        SELECT rule_id FROM asnf_monitoring.rule_registry
        WHERE active AND implementation = 'sql' AND rule_id = ANY(p_rule_ids)
    LOOP
        IF v_rule.rule_id !~ '^[A-Za-z0-9_]+$' THEN
            RAISE EXCEPTION 'Unsafe rule_id blocked from dynamic dispatch: %', v_rule.rule_id;
        END IF;

        EXECUTE format(
            'INSERT INTO asnf_monitoring.flags (run_id, case_id, patient_id, rule_id, points, evidence)
             SELECT %L, case_id, patient_id, rule_id, points, evidence
             FROM asnf_monitoring.detect_%s()',
            v_run_id, lower(v_rule.rule_id)
        );
    END LOOP;
    RETURN v_run_id;
END;
$$;

-- =====================================================================
-- 7. Scoring: prioritization, not judgment.
--    Escalation rewards corroboration across independent lenses, not
--    just more flags from the same lens.
-- =====================================================================

CREATE OR REPLACE VIEW asnf_monitoring.case_risk_score AS
WITH per_case AS (
    SELECT
        f.run_id,
        f.case_id,
        MAX(f.patient_id) AS patient_id,
        SUM(f.points) AS raw_score,
        COUNT(DISTINCT f.rule_id) AS distinct_rules_triggered,
        COUNT(DISTINCT r.lens) AS distinct_lenses_triggered,
        jsonb_agg(
            jsonb_build_object('rule_id', f.rule_id, 'lens', r.lens, 'points', f.points, 'evidence', f.evidence)
            ORDER BY f.points DESC
        ) AS evidence_trail
    FROM asnf_monitoring.flags f
    JOIN asnf_monitoring.rule_registry r ON r.rule_id = f.rule_id
    GROUP BY f.run_id, f.case_id
)
SELECT
    run_id, case_id, patient_id, raw_score, distinct_rules_triggered, distinct_lenses_triggered,
    LEAST(100, raw_score * (1 + 0.15 * GREATEST(distinct_lenses_triggered - 1, 0))) AS monitoring_score,
    CASE
        WHEN LEAST(100, raw_score * (1 + 0.15 * GREATEST(distinct_lenses_triggered - 1, 0))) >= 75 THEN 'CRITICAL'
        WHEN LEAST(100, raw_score * (1 + 0.15 * GREATEST(distinct_lenses_triggered - 1, 0))) >= 50 THEN 'HIGH'
        WHEN LEAST(100, raw_score * (1 + 0.15 * GREATEST(distinct_lenses_triggered - 1, 0))) >= 25 THEN 'MEDIUM'
        ELSE 'LOW'
    END AS risk_tier,
    evidence_trail
FROM per_case;

CREATE OR REPLACE VIEW asnf_monitoring.case_risk_score_latest AS
SELECT *
FROM asnf_monitoring.case_risk_score
WHERE run_id = (SELECT run_id FROM asnf_monitoring.flags ORDER BY detected_at DESC LIMIT 1);

-- =====================================================================
-- 8. Self-measurement: precision per rule, once audit_outcomes has data.
--    This is what lets weights get retuned toward rules that catch real issues
--    instead of rules that just fire often.
-- =====================================================================

CREATE OR REPLACE VIEW asnf_monitoring.rule_precision AS
SELECT
    f.rule_id,
    r.lens,
    COUNT(DISTINCT f.case_id) AS total_flagged,
    COUNT(DISTINCT f.case_id) FILTER (WHERE a.outcome = 'CONFIRMED')  AS true_positives,
    COUNT(DISTINCT f.case_id) FILTER (WHERE a.outcome = 'FALSE_POSITIVE') AS false_positives,
    round(
        COUNT(DISTINCT f.case_id) FILTER (WHERE a.outcome = 'CONFIRMED')::numeric
        / NULLIF(COUNT(DISTINCT f.case_id) FILTER (WHERE a.outcome IN ('CONFIRMED','FALSE_POSITIVE')), 0),
        3
    ) AS precision
FROM asnf_monitoring.flags f
JOIN asnf_monitoring.rule_registry r ON r.rule_id = f.rule_id
LEFT JOIN asnf_monitoring.audit_outcomes a ON a.case_id = f.case_id
GROUP BY f.rule_id, r.lens
ORDER BY precision DESC NULLS LAST;

-- =====================================================================
-- 9. Rule registered for an external (Python) detector.
--    identity_ring_detector.py finds multi-hop identity rings -- patients
--    transitively linked via shared email/phone or fuzzy name+DOB match --
--    via graph connected components. Not a clean single-pass SQL rule:
--    a same-field GROUP BY only sees direct shares (A-B), not transitive
--    chains (A-B via phone, B-C via email => A-C is still a ring member).
--    It writes into the same asnf_monitoring.flags table under rule_id GRF05,
--    reading its own thresholds from rule_config exactly like the SQL
--    detectors do, so it rolls into the same case_risk_score.
-- =====================================================================

INSERT INTO asnf_monitoring.rule_registry (rule_id, lens, description, implementation) VALUES
('GRF05','graph','Multi-hop identity ring: patients transitively linked via shared email/phone or fuzzy name+DOB match, found via graph connected components (Python detector)','python')
ON CONFLICT (rule_id) DO NOTHING;

INSERT INTO asnf_monitoring.rule_config (rule_id, param_name, param_value) VALUES
('GRF05','points','20'),
('GRF05','min_ring_size','3'),
('GRF05','max_lname_distance','2'),
('GRF05','min_fname_similarity','85')
ON CONFLICT (rule_id, param_name) DO NOTHING;

-- =====================================================================
-- 10. Provider/patient identity collision -- a prescriber's own fields
--     matching the patient's own fields on the same record. A patient and
--     their treating physician should never be the same person; when their
--     address, name, or phone collide, that assumption is broken. Same
--     mechanical shape as the graph fan-out rules (comparing identity
--     fields), just cross-role (patient vs. their own listed provider) on
--     a single row rather than fan-out across many rows -- so these use
--     the fuzzystrmatch extension enabled at the top of this file, which
--     until now had no SQL rule actually using it (GRF05's fuzzy matching
--     runs in Python).
-- =====================================================================

CREATE OR REPLACE FUNCTION asnf_monitoring.detect_grf06()
RETURNS TABLE (case_id text, patient_id text, rule_id text, points numeric, evidence jsonb)
LANGUAGE sql STABLE AS $$
    SELECT
        t.case_id, t.patient_id, 'GRF06',
        asnf_monitoring.get_config_numeric('GRF06','points'),
        jsonb_build_object(
            'provider_address', t.md_address_1,
            'patient_address', t.addr1,
            'md_npi', t.md_npi
        )
    FROM asnf_monitoring.monitored_cases t
    WHERE t.md_address_1 IS NOT NULL
      AND t.addr1 IS NOT NULL
      AND upper(btrim(t.md_address_1)) = upper(btrim(t.addr1));
$$;

CREATE OR REPLACE FUNCTION asnf_monitoring.detect_grf07()
RETURNS TABLE (case_id text, patient_id text, rule_id text, points numeric, evidence jsonb)
LANGUAGE sql STABLE AS $$
    SELECT
        t.case_id, t.patient_id, 'GRF07',
        asnf_monitoring.get_config_numeric('GRF07','points'),
        jsonb_build_object(
            'provider_name', t.md_first_name || ' ' || t.md_last_name,
            'patient_name', t.fname || ' ' || t.lname,
            'lname_distance', levenshtein(upper(btrim(t.md_last_name)), upper(btrim(t.lname))),
            'fname_distance', levenshtein(upper(btrim(t.md_first_name)), upper(btrim(t.fname))),
            'md_npi', t.md_npi
        )
    FROM asnf_monitoring.monitored_cases t
    WHERE t.md_first_name IS NOT NULL AND t.md_last_name IS NOT NULL
      AND t.fname IS NOT NULL AND t.lname IS NOT NULL
      AND levenshtein(upper(btrim(t.md_last_name)), upper(btrim(t.lname)))
          <= asnf_monitoring.get_config_numeric('GRF07','max_lname_distance')
      AND levenshtein(upper(btrim(t.md_first_name)), upper(btrim(t.fname)))
          <= asnf_monitoring.get_config_numeric('GRF07','max_fname_distance');
$$;

CREATE OR REPLACE FUNCTION asnf_monitoring.detect_grf08()
RETURNS TABLE (case_id text, patient_id text, rule_id text, points numeric, evidence jsonb)
LANGUAGE sql STABLE AS $$
    SELECT
        t.case_id, t.patient_id, 'GRF08',
        asnf_monitoring.get_config_numeric('GRF08','points'),
        jsonb_build_object(
            'provider_phone', t.md_phone,
            'matched_patient_phone', CASE
                WHEN regexp_replace(t.md_phone, '[^0-9]', '', 'g') = regexp_replace(t.phone_preferred, '[^0-9]', '', 'g')
                THEN t.phone_preferred ELSE t.phone_alternate
            END,
            'md_npi', t.md_npi
        )
    FROM asnf_monitoring.monitored_cases t
    WHERE t.md_phone IS NOT NULL
      AND regexp_replace(t.md_phone, '[^0-9]', '', 'g') <> ''
      AND (
          regexp_replace(t.md_phone, '[^0-9]', '', 'g') = regexp_replace(t.phone_preferred, '[^0-9]', '', 'g')
          OR regexp_replace(t.md_phone, '[^0-9]', '', 'g') = regexp_replace(t.phone_alternate, '[^0-9]', '', 'g')
      );
$$;

INSERT INTO asnf_monitoring.rule_registry (rule_id, lens, description) VALUES
('GRF06','graph','Provider address matches the patient''s own address on the same case'),
('GRF07','graph','Provider name closely matches the patient''s own name on the same case (fuzzy)'),
('GRF08','graph','Provider phone matches the patient''s own phone on the same case')
ON CONFLICT (rule_id) DO NOTHING;

INSERT INTO asnf_monitoring.rule_config (rule_id, param_name, param_value) VALUES
('GRF06','points','20'),

('GRF07','points','18'),
('GRF07','max_lname_distance','2'),
('GRF07','max_fname_distance','2'),

('GRF08','points','22')
ON CONFLICT (rule_id, param_name) DO NOTHING;

-- =====================================================================
-- Usage:
--   SELECT asnf_monitoring.run_all_rules();                    -- run every active rule
--   SELECT asnf_monitoring.run_selected_rules(ARRAY['GRF06','GRF07','GRF08','GEO02']);
--                                                                 -- run just a subset
--   SELECT * FROM asnf_monitoring.case_risk_score_latest        -- prioritized queue
--     ORDER BY monitoring_score DESC;
--   SELECT * FROM asnf_monitoring.rule_precision;                -- retuning input
--
-- To retire a noisy rule: UPDATE rule_registry SET active = false WHERE rule_id = '...';
-- To retune a threshold:  UPDATE rule_config SET param_value = '...' WHERE rule_id = '...' AND param_name = '...';
-- Neither requires touching a single detector function.
--
-- Combined run (SQL detectors + Python identity-ring detector, one shared
-- run_id, one composite score):
--   python identity_ring_detector.py
-- =====================================================================
