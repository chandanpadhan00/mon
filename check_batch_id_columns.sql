/* =====================================================================
   Run BEFORE deploying the new batch_id format (YYYYMMDDHHMMSS + feed digit,
   15 characters, e.g. 202611181230152).

   Lists every batch_id column in asnfdm. Any row flagged TOO SHORT must be
   widened first, or loads will fail with "value too long for type".
   ===================================================================== */

SELECT table_name,
       data_type,
       character_maximum_length,
       CASE
           WHEN data_type IN ('character varying', 'character')
                AND character_maximum_length < 15 THEN 'TOO SHORT - widen to 15'
           WHEN data_type NOT IN ('character varying', 'character', 'text')
                THEN 'CHECK - not a text column'
           ELSE 'OK'
       END AS status
FROM information_schema.columns
WHERE table_schema = 'asnfdm'
  AND column_name  = 'batch_id'
ORDER BY status DESC, table_name;

-- Template for each table flagged TOO SHORT (widening a varchar is safe and fast):
-- ALTER TABLE asnfdm.<table_name> ALTER COLUMN batch_id TYPE varchar(15);
