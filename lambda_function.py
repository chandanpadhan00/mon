import json
import boto3
import time
from datetime import datetime,timedelta
import pandas as pd
import psycopg2
import smtplib
import base64
import csv
from email.mime.multipart import MIMEMultipart
from email.mime.application import MIMEApplication
from email.mime.text import MIMEText

#Connection_details for Aurora Postgres Database
dbname = "asnfdev"
user = "postgres"
host = "asnf-dev.cluster-cjwrswaefcmx.us-west-2.rds.amazonaws.com"
password = "QXNuZi1kZXYyMDIx"
password = base64.b64decode(password).decode('utf-8')

connection_string = "dbname='{}' user='{}' host='{}' password='{}'" \
        .format(dbname, user, host, password)

#To execute the QC script
def QC_check(connection_string,source_name,query_val,tmp_path,bucket,report_file_path):
    try:
        conn = psycopg2.connect(connection_string)
        print("Connecting to Database")
        cur = conn.cursor()

        print("PCD 1.0 QC for vendor:",source_name)
        print("Filename used for PCD 1.0 QC :",query_val)

        with open(query_val, 'r') as data:
            loadquery = data.read()

        cur.execute(loadquery)
        rows = cur.fetchall()
        headers = [col[0] for col in cur.description] # get headers
        rows.insert(0, tuple(headers))
        with open(tmp_path, 'w', newline = '') as fp:
            myFile = csv.writer(fp) #myFile = csv.writer(fp, lineterminator='\n')
            myFile.writerows(rows)

        with open(tmp_path, 'rb') as data:
            s3_object = boto3.client('s3', 'us-west-2')
            s3_object.upload_fileobj(data, bucket, report_file_path)
            report_file_path_prod = report_file_path.replace('dev','prod')
            report_copy_source = {'Bucket': bucket, 'Key': report_file_path}
            s3_object.copy_object(CopySource=report_copy_source, Bucket=bucket, Key=report_file_path_prod)
            print(f"uploaded csv file to s3 report folder successfully.")
            print(f"DEV: {bucket}/{report_file_path}")
            print(f"PROD: {bucket}/{report_file_path_prod}")

        print(f"QC_check is successful for {source_name}")
        cur.close()
        conn.close()
        print("DB connection closed.")

    except Exception as e:
        raise Exception(f"Error while QC check ,failed due to {e}")


#Send email function
def send_email(subject,vendor, content,bucket,report_file_name,report_file_path):
  try:
    if vendor == 'SNX':
        email_recipient = 'dl-PAP-CTS-Support@amgen.com'
    elif vendor == 'REGALORX':
        email_recipient = 'dl-PAP-CTS-Support@amgen.com'

    # cc_recipient = 'am0104@amgen.com'
    sender = 'dl-PAP-CTS-Support@amgen.com'

    msg = MIMEMultipart('alternative')
    msg['Subject'] = subject
    msg['From'] = sender
    msg['To'] = email_recipient
    # msg['Cc'] = cc_recipient
    s3_object = boto3.client('s3', 'us-west-2')
    s3_object = s3_object.get_object(Bucket=bucket, Key=report_file_path)
    body = s3_object['Body'].read()
    part = MIMEApplication(body, Name = report_file_name)
    part['Content-Disposition'] = 'attachment; filename="%s"' % report_file_name
    msg.attach(part)
    part_txt = MIMEText(content, 'html')
    msg.attach(part_txt)
    server = smtplib.SMTP('mailhost-i.amgen.com')
    response = server.send_message(msg)
    server.quit()
    print(response)
  except Exception as e:
      raise Exception(f"Error while initializing sendMail function : {e}")


def lambda_handler(event, context):
    # TODO implement
    print(event)
    bucket = event['Records'][0]['s3']['bucket']['name']
    csv_file = event['Records'][0]['s3']['object']['key']
    source_name= bucket.replace('amgen-gco-asnf-','').replace('-bkt','').upper()
    s3_object =boto3.client('s3', 'us-west-2')
    print("Bucket Name: ",bucket)
    print("Filename: ",csv_file)

    if source_name == 'SNX':
        query_val = 'SNX_QC_SCRIPT_PCD1.sql'
        report_file_name = f"PCD1_Exception_SNX_{csv_file[-14:]}"
        report_file_path = f"dev/outbound/{report_file_name}"
        tmp_path ='/tmp/pcd1_report_csv_file.csv'
    elif source_name == 'REGALORX':
        query_val = 'REGALORX_QC_SCRIPT_PCD1.sql'
        report_file_name = f"PCD1_Exception_REGALORX_{csv_file[-14:]}"
        report_file_path = f"dev/outbound/{report_file_name}"
        tmp_path ='/tmp/pcd1_report_csv_file.csv'
    else:
        raise Exception(f"Source name not matching.{source_name}")

    date_list = []
    for i in range(3):
        if i == 0:
            current_date = datetime.now()
        elif i == 1:
            current_date = datetime.now() - timedelta(days=1)
        else:
            current_date = datetime.now() + timedelta(days=1)
        format_date = current_date.strftime("%Y_%m_%d")
        date_list.append(format_date)
    print(f"Load Date: {date_list}")

    # Source file
    copy_source = {'Bucket': bucket, 'Key': csv_file}
    print(f"copy source: {copy_source}")

    # PCD 2.0 files and their PHI files are copied to test/inbound by
    # PAPDM-Inbound-Copy-Test. This function handles PCD 1.0 (dev) only.
    if 'v2' in csv_file:
        print(f"PCD 2.0 file skipped here; it is copied by PAPDM-Inbound-Copy-Test. {csv_file}")
        return {
            'statusCode': 200,
            'body': json.dumps('PCD 2.0 skipped')
        }

    if csv_file[-14:-4] in date_list:
        to_env = 'dev'
        sleep_time = 720
        file_ver = 'PCD 1.0'
    else:
        raise Exception(f"File date is not latest. Loading skipped. {csv_file}")

    #Copy PCD file to target folder
    if 'snx' in bucket:
        destination_key = csv_file.replace('prod',f'{to_env}/inbound')
    else:
        destination_key = csv_file.replace('prod',f'{to_env}')
    print(f"Target path: {destination_key}")
    s3_object.copy_object(CopySource=copy_source, Bucket=bucket, Key=destination_key)
    print(f"{file_ver} file loaded. {destination_key} waiting for {sleep_time} seconds.")

    # Going to sleep till PCD 1.0 file loads
    time.sleep(sleep_time)

    # QC report generation for pcd 1.0
    if 'v2' not in csv_file:
        # calling qc report
        print("Generating updated QC report for PCD 1.0")
        QC_check(connection_string,source_name,query_val,tmp_path,bucket,report_file_path)
        print(f"PCD 1.0 QC report generated for {source_name}")

        # send mail
        sub = f"{to_env.upper()} :[UPDATED] PAP Data Load Quality Check for {source_name}"
        status = f"""<html><body>
                    <p style="font-family: Calibri, sans-serif; font-size: 14px;">Hi Team,<br><br>\
                    Please find the attached PCD 1.0 QC report for the file (<b>'{csv_file.split("/")[-1]}'</b>). The report has been uploaded in S3 outbound Folders as well. <br><br>\
                    <b>Report path DEV:</b> "{bucket}/{report_file_path}"<br><br>\
                    <b>Report path PROD:</b> "{bucket}/{report_file_path.replace('dev','prod')}"<br><br>\
                    Thanks,<br>\
                    PAP Team</p>\
                    </body></html>"""

        send_email(sub,source_name, status,bucket,report_file_name,report_file_path)
        print(f"PCD 1.0 QC report mail sent for {source_name}")
    print("Loading PHI file.")

    if 'snx' in bucket:
        phi_source_key = f"prod/ASNF_PATIENT_DEMOGRAPHICS.SONEXUS.{csv_file[-14:].replace("_","")}"
        phi_destination_key = f"{to_env}/inbound/ASNF_PATIENT_DEMOGRAPHICS.SONEXUS.{csv_file[-14:].replace("_","")}"
    else:
        phi_source_key = f"prod/inbound/Patient_Detail_Report_{csv_file[-14:]}"
        phi_destination_key = f"{to_env}/inbound/Patient_Detail_Report_{csv_file[-14:]}"
    copy_source = {'Bucket': bucket, 'Key': phi_source_key}

    print(f"PHI Source: {phi_source_key}")
    print(f"PHI Target: {phi_destination_key}")
    try:
        s3_object.copy_object(CopySource=copy_source, Bucket=bucket, Key=phi_destination_key)
        print(f"PHI File loaded to {to_env} Folder. {phi_destination_key}")
    except:
        print("PHI file is not available.")

    return {
        'statusCode': 200,
        'body': json.dumps('Hello from Lambda!')
    }