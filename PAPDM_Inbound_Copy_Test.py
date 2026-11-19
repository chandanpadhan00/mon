"""
PAPDM inbound copy (prod -> test/inbound)

Copies vendor files, unchanged, from their prod drop folder to test/inbound/
in the same bucket. The copy in test/inbound/ is what starts
PAPDM-S3toFactLoad_V2-Test.

Files handled (one S3 trigger per file type, each fires on that file's own arrival):
    REGALORX  prod/inbound/Patient_Case_Detail_Report_v2_YYYY_MM_DD.csv     (PCD 2.0)
    REGALORX  prod/inbound/Patient_Detail_Report_YYYY_MM_DD.csv           (PHI)
    REGALORX  prod/inbound/Prescreen_Detail_Report_YYYY_MM_DD.csv         (Prescreen)
    SNX       prod/Patient_Case_Detail_Report_v2.0_YYYY_MM_DD.csv         (PCD 2.0)
    SNX       prod/ASNF_PATIENT_DEMOGRAPHICS.SONEXUS.YYYYMMDD.csv         (PHI)

PCD 2.0 names are accepted as either "_v2_" or "_v2.0_" for both vendors.
PCD 1.0 files (no "v2") are not handled here; PAPDM-WeeklyLoad-DEV copies them to dev.

Safeguards:
  - Only exact file-name patterns are copied; anything else is logged and skipped.
  - Files dated outside +/- MAX_FILE_AGE_DAYS of today (UTC) are refused, so a
    re-sent old file cannot overwrite current data. Set MAX_FILE_AGE_DAYS=-1
    to switch the check off. To load an older file on purpose, copy it into
    test/inbound/ by hand, as today.
  - A duplicate S3 event for the same file version is skipped while the earlier
    copy is still waiting in test/inbound/ (compared by the source ETag).
  - The prod original is never modified or deleted.
  - Failures raise, so Lambda retries and the failure appears in the Errors
    metric and in the on-failure destination, if one is configured.
  - Only file names are logged, never file contents.
"""
import logging
import os
import re
from datetime import datetime, timedelta, timezone
from urllib.parse import unquote_plus

import boto3
from botocore.exceptions import ClientError

TARGET_PREFIX = os.environ.get("TARGET_PREFIX", "test/inbound/")
MAX_FILE_AGE_DAYS = int(os.environ.get("MAX_FILE_AGE_DAYS", "1"))

# bucket -> files to copy. "pattern" must match the whole file name; its one
# group is the file date, read with "date_format".
COPY_RULES = {
    "amgen-gco-asnf-regalorx-bkt": [
        {"name": "REGALORX PCD 2.0", "source_prefix": "prod/inbound/",
         "pattern": r"Patient_Case_Detail_Report_v2(?:\.0)?_(\d{4}_\d{2}_\d{2})\.csv", "date_format": "%Y_%m_%d"},
        {"name": "REGALORX PHI", "source_prefix": "prod/inbound/",
         "pattern": r"Patient_Detail_Report_(\d{4}_\d{2}_\d{2})\.csv", "date_format": "%Y_%m_%d"},
        {"name": "REGALORX Prescreen", "source_prefix": "prod/inbound/",
         "pattern": r"Prescreen_Detail_Report_(\d{4}_\d{2}_\d{2})\.csv", "date_format": "%Y_%m_%d"},
    ],
    "amgen-gco-asnf-snx-bkt": [
        {"name": "SNX PCD 2.0", "source_prefix": "prod/",
         "pattern": r"Patient_Case_Detail_Report_v2(?:\.0)?_(\d{4}_\d{2}_\d{2})\.csv", "date_format": "%Y_%m_%d"},
        {"name": "SNX PHI", "source_prefix": "prod/",
         "pattern": r"ASNF_PATIENT_DEMOGRAPHICS\.SONEXUS\.(\d{8})\.csv", "date_format": "%Y%m%d"},
    ],
}

logger = logging.getLogger()
logger.setLevel(logging.INFO)
s3 = boto3.client("s3")


class FileRejected(Exception):
    """The file matched a rule but must not be copied (for example, it is stale)."""


def match_rule(bucket, source_key):
    """Return (rule, file_name, file_date) for a file to copy, or None to skip it."""
    for rule in COPY_RULES.get(bucket, []):
        prefix = rule["source_prefix"]
        if not source_key.startswith(prefix):
            continue
        file_name = source_key[len(prefix):]
        if "/" in file_name:          # sub-folders are never copied
            continue
        found = re.fullmatch(rule["pattern"], file_name)
        if not found:
            continue
        try:
            file_date = datetime.strptime(found.group(1), rule["date_format"]).date()
        except ValueError:
            raise FileRejected(f"{rule['name']}: invalid date in file name {file_name}")
        return rule, file_name, file_date
    return None


def check_fresh(rule, file_name, file_date):
    if MAX_FILE_AGE_DAYS < 0:
        return
    today = datetime.now(timezone.utc).date()
    window = timedelta(days=MAX_FILE_AGE_DAYS)
    if not (today - window <= file_date <= today + window):
        raise FileRejected(
            f"{rule['name']}: {file_name} is dated {file_date}, outside "
            f"+/-{MAX_FILE_AGE_DAYS} day(s) of {today}. Not copied. "
            f"To load it on purpose, copy it into {TARGET_PREFIX} by hand.")


def pending_copy_of(bucket, target_key, source_etag):
    """True if target_key is already a copy of this exact source version."""
    try:
        head = s3.head_object(Bucket=bucket, Key=target_key)
    except ClientError as e:
        if e.response.get("Error", {}).get("Code") in ("404", "NoSuchKey", "NotFound"):
            return False
        raise
    return head.get("Metadata", {}).get("source-etag") == source_etag


def copy_file(bucket, source_key, target_key):
    source = s3.head_object(Bucket=bucket, Key=source_key)
    source_etag = source["ETag"].strip('"')
    if pending_copy_of(bucket, target_key, source_etag):
        logger.info("Already copied, skipped duplicate event: s3://%s/%s", bucket, source_key)
        return False
    metadata = dict(source.get("Metadata", {}))
    metadata.update({"source-key": source_key, "source-etag": source_etag})
    extra_args = {"MetadataDirective": "REPLACE", "Metadata": metadata}
    if source.get("ContentType"):
        extra_args["ContentType"] = source["ContentType"]
    # Managed copy: server-side, and multipart for files over 5 GB.
    s3.copy({"Bucket": bucket, "Key": source_key}, bucket, target_key, ExtraArgs=extra_args)
    return True


def lambda_handler(event, context):
    copied, skipped, errors = [], [], []
    for record in event.get("Records", []):
        bucket = record["s3"]["bucket"]["name"]
        # S3 event keys are URL-encoded (a space arrives as '+').
        source_key = unquote_plus(record["s3"]["object"]["key"])
        try:
            matched = match_rule(bucket, source_key)
            if matched is None:
                logger.info("Skipped s3://%s/%s: no copy rule matches", bucket, source_key)
                skipped.append(source_key)
                continue
            rule, file_name, file_date = matched
            check_fresh(rule, file_name, file_date)
            target_key = TARGET_PREFIX + file_name
            if target_key == source_key:
                raise FileRejected(f"Source and target are the same key: {source_key}")
            if copy_file(bucket, source_key, target_key):
                logger.info("%s copied: s3://%s/%s -> %s", rule["name"], bucket, source_key, target_key)
                copied.append(target_key)
            else:
                skipped.append(source_key)
        except Exception as e:
            logger.error("Copy failed for s3://%s/%s: %s", bucket, source_key, e)
            errors.append(f"{source_key}: {e}")
    if errors:
        raise Exception("Inbound copy failed: " + " | ".join(errors))
    return {"copied": copied, "skipped": skipped}
