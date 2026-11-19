import json
import os
import boto3,botocore
import csv
import pandas as pd
import openpyxl
from openpyxl.styles import *
from io import BytesIO
import time
import datetime
import psycopg2
import base64
from re import search
from botocore.exceptions import ClientError
from email.mime.multipart import MIMEMultipart
from email.mime.application import MIMEApplication
from email.mime.text import MIMEText
import smtplib

#Connection_details for Aurora Postgres Database
config = json.load(open('conf_json.json', "r"))
dbname = config['conf_json']['rds_db_connection_details']['db_name']
user = config['conf_json']['rds_db_connection_details']['db_username']
host = config['conf_json']['rds_db_connection_details']['db_host']
password = config['conf_json']['rds_db_connection_details']['db_password']
password = base64.b64decode(password).decode('utf-8')

connection_string = "dbname='{}' user='{}' host='{}' password='{}'" \
        .format(dbname, user, host, password)

# To fetch stg_table_name to load data into rds based on vendorname
def rdstablename(source_name,csv_file):
  config = json.load(open('conf_json.json', "r"))
  print("Vendor Name:",source_name)
  bucket = source_name.lower()
  rds_table = '_stg_table_name'
  key_value = bucket + rds_table
  #stg_table_name = config['conf_json']['Rds_stg_tables'][key_value]
  if 'Patient_Case_Detail_Report' in csv_file:
    stg_table_name = config['conf_json']['Rds_stg_tables'][key_value][0]
  elif 'Patient_Detail_Report' in csv_file or 'ASNF_PATIENT_DEMOGRAPHICS.SONEXUS' in csv_file:
    stg_table_name = config['conf_json']['Rds_stg_tables'][key_value][1]
  elif 'Product_Shipment_Report' in csv_file:
    stg_table_name = config['conf_json']['Rds_stg_tables'][key_value][2]
  elif prescreen_details(config,source_name,csv_file):
    stg_table_name = prescreen_details(config,source_name,csv_file)['stg_table']
  else:
    raise Exception("File name not matching")

  return stg_table_name

# To identify a Prescreen file and return its table details from config.
# Returns None when the file is not a Prescreen file.
def prescreen_details(config,source_name,csv_file):
  details = config['conf_json']['prescreen_details']
  file_name = csv_file.split('/')[-1].lower()
  if details['file_pattern'].lower() not in file_name:
    return None
  if source_name not in details['vendors']:
    raise Exception("Prescreen file received for unsupported vendor: " + source_name)
  return details

# One digit per vendor and file type, appended to the batch_id so that two
# different feeds starting in the same second never share a batch_id.
# Give every new feed its own digit here.
BATCH_FEED_CODES = {
  ('SNX','PCD'): '1',      ('REGALORX','PCD'): '2',
  ('SNX','PHI'): '3',      ('REGALORX','PHI'): '4',
  ('SNX','SHIPMENT'): '5', ('REGALORX','SHIPMENT'): '6',
  ('REGALORX','PRESCREEN'): '7',
}

# File type from the file name, using the same name checks as rdstablename.
def file_type(config,csv_file):
  if 'Patient_Case_Detail_Report' in csv_file:
    return 'PCD'
  if 'Patient_Detail_Report' in csv_file or 'ASNF_PATIENT_DEMOGRAPHICS.SONEXUS' in csv_file:
    return 'PHI'
  if 'Product_Shipment_Report' in csv_file:
    return 'SHIPMENT'
  if config['conf_json']['prescreen_details']['file_pattern'].lower() in csv_file.split('/')[-1].lower():
    return 'PRESCREEN'
  return None

# batch_id = YYYYMMDDHHMMSS + feed digit, 15 characters, e.g. 202611181230152.
# Still sorts in time order, including against the older 12-character ids.
def generate_batch_id(config,source_name,csv_file):
  feed_code = BATCH_FEED_CODES.get((source_name, file_type(config,csv_file)), '0')
  return datetime.datetime.now().strftime("%Y%m%d%H%M%S") + feed_code

#To execute the Process_log_entries
def execute_query(query):
  #value=None #add this to run
  try:
      conn = psycopg2.connect(connection_string)
      print("Connecting to RDS Database")
      with conn.cursor() as cur:
        cur.execute(query)
        if 'insert' in query:
          value = None
        elif 'update' in query:
          value = None
        elif 'create table' in query:
          value = None
        elif 'select' in query:
          value = cur.fetchone()[0]
          print(value)
        else:
          value = None
        conn.commit()
        cur.close()
      print(query)
      print("Query Executed Successfully")
      conn.close()
      print("DB connection closed.")
  except Exception as e:
      print('Error while executing query{}'.format(str(e)))
  return str(value)

#To Load the csv file into rds stage tables
def loadcsvfiletords(connection_string,filedata,bucket,csv_file):
  try:
      print("File_name used for Data Load in RDS is ",filedata)
      conn = psycopg2.connect(connection_string)
      print("Connecting to RDS Database")
      # Open the input file for copy csv file data into rds table
      sql = "COPY %s FROM STDIN WITH CSV HEADER DELIMITER AS '^' NULL as '' ENCODING 'utf-8'"
      file = open(filedata,"r")
      table = rdstablename(bucket,csv_file)
      with conn.cursor() as cur:
          #Truncate respective stage table before loading the data
          cur.execute("truncate table "+table)
          #copy csv file data to respective rds stage table
          cur.copy_expert(sql=sql % table, file=file)
          conn.commit()
          cur.close()
      print("Data is loaded successfully for {}".format(table))
      conn.close()
      print("DB connection closed.")

      return True
  except Exception as e:
      print('Error while loading csv file, failed due to {}'.format(str(e)))

      return False

#To Load the data from stage to dimension
def load_data_stg_to_dimension(connection_string,batch_id,source_name):
  try:
      config = json.load(open('conf_json.json', "r"))
      conn = psycopg2.connect(connection_string)
      print("Connecting to Database")
      cur = conn.cursor()
      dim_tables= config['conf_json']['Rds_dimension_tables']['dimension_list']
      print("List of Dimension is",dim_tables)
      for table in dim_tables:
          print("RDS Dimension table_name:",table)
          table_name = table.replace('asnfdm.', '')
          print("Table key in json",table_name)
          query_val =config['conf_json']['Rds_dimension_tables'][table_name]
          print("Filename used for Data load:",query_val)
          max_key_name = table_name.replace('d_','')
          print(max_key_name)
          max_key_value = execute_query("select max("+max_key_name+"_key)+1 from "+table)
          max_key_value = max_key_value.replace('None','1')
          print("Max Sequence Key Value :",max_key_value)
          with open(query_val, 'r') as data:
              loadquery = data.read()
              sql_query = loadquery.replace('$$max_value$$',str(max_key_value)).replace('$$ext_src$$',source_name)
          with conn.cursor() as cur:
              cur.execute(sql_query)
              conn.commit()
          print("Stg_to_Dimension Data load is successful for {}".format(table))
      execute_query("update asnfdm.pap_data_process_log set stagetodim ='SUCCESS' where batch_id ='"+batch_id+"'")
      cur.close()
      conn.close()
      print("DB connection closed.")

  except Exception as e:
      print('Error while loading dimension, failed due to {}'.format(str(e)))

#To Load the data from stage to fact
def load_data_dimension_to_fact(connection_string,batch_id,csv_file,rds_table,source_name):
  try:
      config = json.load(open('conf_json.json', "r"))
      conn = psycopg2.connect(connection_string)
      print("Connecting to Database")
      cur = conn.cursor()

      if 'Patient_Case_Detail_Report' in csv_file:
          fact_table= config['conf_json']['fact_tables_details']['fact_list'][0]
      elif 'Patient_Detail_Report' in csv_file or 'ASNF_PATIENT_DEMOGRAPHICS.SONEXUS' in csv_file:
          fact_table= config['conf_json']['fact_tables_details']['fact_list'][1]
      elif 'Product_Shipment_Report' in csv_file:
          fact_table= config['conf_json']['fact_tables_details']['fact_list'][2]
      elif prescreen_details(config,source_name,csv_file):
          fact_table= prescreen_details(config,source_name,csv_file)['fact_table']
      else:
          raise Exception("File name not matching for fact table loading.")

      print("Fact Table_name:",fact_table)
      table_name = fact_table.replace('asnfdm.', '')
      print("Table key in json",table_name)
      query_val =config['conf_json']['fact_tables_details'][table_name]
      print("Filename used for Data Load :",query_val)
      with open(query_val, 'r') as data:
          loadquery = data.read()
          sql_query = loadquery.replace('$$csv_file$$',csv_file.split('/')[-1]).replace('$$stg_table$$',rds_table).replace('$$source_name$$',source_name)
      with conn.cursor() as cur:
          cur.execute(sql_query)
          conn.commit()
      print("Stage_to_Fact Data load is successful for {}".format(fact_table))
      execute_query("update asnfdm.pap_data_process_log set stage_dimtofact ='SUCCESS' where batch_id ='"+batch_id+"'")
      execute_query("update asnfdm.pap_data_process_log set end_dt =now() where batch_id ='"+batch_id+"'")
      cur.close()
      conn.close()
      print("DB connection closed.")

  except Exception as e:

      print('Error while loading fact ,failed due to {}'.format(str(e)))

def notify_mail(subject,vendor,status):
    try:
        config = json.load(open('conf_json.json', "r"))
        topic_arn = config['conf_json']['sns_details']['topic_arn']
        message = status
        sns = boto3.client('sns')
        response = sns.publish(
        TopicArn=topic_arn,
        Message=message,
        Subject=subject)
        print('Email Sent Successfully')

    except Exception as e:
        print('Error while sending notification, failed due to {}'.format(str(e)))

def archive_file(csv_file, bucket,config,temp_path,s3_client):
    try:
        s3 = boto3.resource('s3')
        env = config['conf_json']['environment']
        # Upload file to archive
        replace_value = env + '/inbound/'
        upload_filename = csv_file.replace(replace_value, '')
        upload_path = env + '/archive/' + upload_filename
        with open(temp_path, 'rb') as data:
            s3_client.upload_fileobj(data, bucket, upload_path)
        print("uploaded csv file to s3 archive folder successfully")
        # Delete the object from inbound
        s3.Object(bucket, csv_file).delete()
        print('{} transferred to archive folder'.format(csv_file))

    except Exception as e:
        print(e)
        print('Error while archive {} object '.format(csv_file))
        raise e

def counts_validation(record_count,src_count,batch_id,source_name,env):
    try:
        print("validating src and target count")
        if record_count == src_count:
            print("counts are matched")
        else:
            print("counts are not matched")
            sub= env.upper()+' : PAP Data Load Validation for ' +source_name
            status = 'Hi Team,\n\nCounts are not matching between src and target file(stage) for ' + source_name +'.PFB details\n\n''Batch_id   : ' + batch_id + '\n''Src_count : ' + str(src_count) + '\n''Stg_Count : ' + str(record_count) + '\n\n''Thanks,\n''PAP Team'
            notify_mail(subject=sub,vendor=source_name,status=status)

    except Exception as e:
        print('Error {}'.format(str(e)))


#Send email function
def send_email(subject,vendor, content):
  try:
    if vendor == 'SNX':
        email_recipient = config['conf_json']['email_details']['recipient_snx']
    elif vendor == 'REGALORX':
        email_recipient = config['conf_json']['email_details']['recipient_regalo']

    cc_recipient = config['conf_json']['email_details']['pap_team']
    sender = config['conf_json']['email_details']['sender']

    msg = MIMEMultipart('alternative')
    msg['Subject'] = subject
    msg['From'] = sender
    msg['To'] = email_recipient
    msg['Cc'] = cc_recipient
    part = MIMEText(content,'html')
    msg.attach(part)
    server = smtplib.SMTP('mailhost-i.amgen.com')
    response = server.send_message(msg)
    server.quit()
  except Exception as e:
      print(f'Error while initializing sendMail function : {e}')


#To execute the QC script
def QC_check(connection_string,batch_id,source_name):
    try:
        config = json.load(open('conf_json.json', "r"))
        conn = psycopg2.connect(connection_string)
        print("Connecting to Database")
        cur = conn.cursor()

        query_val = config['conf_json']['QC_details'][source_name]
        exclusion = f"{source_name.lower()}_case_id_exclusion"
        exclusion_id = config['conf_json']['QC_details'][exclusion]

        if not exclusion_id:
            exclusion_id = "''"

        print("QC for vendor:",source_name)
        print("Filename used for QC :",query_val)
        print("Exclusion case_id's :",exclusion_id)
        with open(query_val, 'r') as data:
            loadquery = data.read()
            sql_query = loadquery.replace('$$case_ids$$',exclusion_id)
        with conn.cursor() as cur:
            cur.execute(sql_query)
            conn.commit()
        print("QC_check is successful for {}".format(source_name))
        execute_query("update asnfdm.pap_data_process_log set quality_check ='SUCCESS' where batch_id ='"+batch_id+"'")
        cur.close()
        conn.close()
        print("DB connection closed.")

    except Exception as e:

        print('Error while QC check ,failed due to {}'.format(str(e)))


#report generation

def load_report_to_s3(connection_string,source_name,bucket,csv_file,env,batch_id):
    try:
        s3_client =boto3.client('s3')
        conn = psycopg2.connect(connection_string)
        cursor = conn.cursor()

        report_bucket = config['conf_json']['QC_details']['qc_bucket']
        sheet_name_1 = f"{config['conf_json']['QC_details']['sheet_1']} {source_name}"
        sheet_name_2 = config['conf_json']['QC_details']['sheet_2']
        qc_lkp_table = config['conf_json']['QC_details']['qc_lkp_table']

        if source_name == 'SNX':
            report_table = config['conf_json']['QC_details']['snx_qc_table']
            report_columns = config['conf_json']['QC_details']['snx_qc_columns']
            qc_report_path = f"report/snx/qc_report/{env}/{config['conf_json']['QC_details']['snx_file_name']}_{csv_file[-14:-4]}_{batch_id[4:]}.xlsx"
            qc_outbound_path = f"{env}/outbound/{config['conf_json']['QC_details']['snx_file_name']}_{csv_file[-14:-4]}_{batch_id[4:]}.xlsx"
        elif source_name == 'REGALORX':
            report_table = config['conf_json']['QC_details']['regalorx_qc_table']
            report_columns = config['conf_json']['QC_details']['regalorx_qc_columns']
            qc_report_path = f"report/regalorx/qc_report/{env}/{config['conf_json']['QC_details']['regalorx_file_name']}_{csv_file[-14:-4]}_{batch_id[4:]}.xlsx"
            qc_outbound_path = f"{env}/outbound/{config['conf_json']['QC_details']['regalorx_file_name']}_{csv_file[-14:-4]}_{batch_id[4:]}.xlsx"
        else:
            raise Exception("Error with the vendor name.")

        print("QC report path:", qc_report_path, qc_outbound_path)

        # Fetch the QC failed records
        cursor.execute(f"select distinct {report_columns} from {report_table} order by qc_rule_no")
        rows1 = cursor.fetchall()
        headers1 = [col[0] for col in cursor.description] # get headers

        # Fetch the QC failed records count  (Modified sql query)
        query = f""" WITH last_batch AS (SELECT MAX(batch_id) AS last_batch_id     FROM asnfdm.qc_rule_counts_history     WHERE batch_id < '{batch_id}'       AND vendor_name = '{source_name}' ), prev_counts AS (     SELECT qc_rule_no, counts     FROM asnfdm.qc_rule_counts_history     WHERE vendor_name = '{source_name}'       AND batch_id = (SELECT last_batch_id FROM last_batch) ) SELECT     lkp.qc_rule_no,     lkp.qc_rule,     COALESCE(curr.count, 0) AS count,     COALESCE(prev.counts, 0) AS last_load_count,     COALESCE(curr.count, 0) - COALESCE(prev.counts, 0) AS difference FROM {qc_lkp_table} lkp LEFT JOIN (     SELECT qc_rule_no, COUNT(*) AS count     FROM {report_table}     GROUP BY qc_rule_no ) curr     ON lkp.qc_rule_no = curr.qc_rule_no LEFT JOIN prev_counts prev     ON lkp.qc_rule_no = prev.qc_rule_no WHERE lkp.vendor = '{source_name}' ORDER BY lkp.s_no """
        cursor.execute(query)
        rows2 = cursor.fetchall()
        headers2 = [col[0].upper() for col in cursor.description] # get headers
        print("headers2:", headers2)
        #current_week = datetime.datetime.now().strftime("%B %d, %Y")  #Added to incorporate Week field population requested by Kapil
        #Inserting data into history table
        for row in rows2:
            #print(row)
            qc_rule_no, qc_rule, counts, *_ = row
            insert_query = f"""
                INSERT INTO asnfdm.qc_rule_counts_history
                (batch_id, vendor_name, qc_rule_no, qc_rule, counts)
                VALUES
                ('{batch_id}', '{source_name}', '{qc_rule_no}', '{qc_rule}', {counts})
            """
            execute_query(insert_query)

        try:
            # Execute the SELECT query
            cursor.execute(f"""
                SELECT external_source, patient_id, case_id, qc_rule_no
                FROM {report_table}
                ORDER BY qc_rule_no
            """)

            # Fetch all rows
            rows = cursor.fetchall()

            # Prepare the INSERT query
            insert_query = """
                INSERT INTO asnfdm.wkly_flagged_cases_hist
                (vendor_id, patient_id, case_id, qc_rule_no, process_datetime)
                VALUES (%s, %s, %s, %s, %s)
            """

            # Current timestamp
            current_timestamp = datetime.datetime.now()


            # Insert each row with the current timestamp
            for row in rows:
                cursor.execute(insert_query, (*row, current_timestamp))

            # Commit the transaction
            conn.commit()

        except Exception as e:
            print(f"An error occurred: {e}")
            conn.rollback()

        finally:
            cursor.close()
            conn.close()

        # cursor.close()
        #conn.close()

        # Create a Pandas DataFrame from the query results
        df1 = pd.DataFrame(rows1, columns=headers1)
        df2 = pd.DataFrame(rows2, columns=headers2)

        # Create a BytesIO buffer to save the Excel file
        buffer = BytesIO()

        # Write the DataFrames to an Excel file with two sheets
        with pd.ExcelWriter(buffer, engine='openpyxl') as writer:
            df1.to_excel(writer, sheet_name=sheet_name_1, index=False)
            df2.to_excel(writer, sheet_name=sheet_name_2, index=False)

        # Seek to the beginning of the buffer
        buffer.seek(0)

        # Load the workbook and select the sheets
        workbook = openpyxl.load_workbook(buffer)
        sheet1 = workbook[sheet_name_1]
        sheet2 = workbook[sheet_name_2]

        # Align headers to the left in the first sheet
        for cell in sheet1[1]:
            cell.alignment = Alignment(horizontal='left')

        # Set the width of the first column to 100 in the second sheet
        sheet2.column_dimensions['A'].width = 100

        # Define border style
        thin_border = Border(
            left=Side(style='thin'),
            right=Side(style='thin'),
            top=Side(style='thin'),
            bottom=Side(style='thin')
        )

        # Apply border to all cells in the second sheet
        for row in sheet2.iter_rows():
            for cell in row:
                cell.border = thin_border

        # Save the modified workbook back to the buffer
        modified_buffer = BytesIO()
        workbook.save(modified_buffer)
        modified_buffer.seek(0)

        # Upload the Excel file to S3
        s3_client.upload_fileobj(modified_buffer, report_bucket, qc_report_path)
        print("uploaded csv file to s3 report folder successfully:", report_bucket,qc_report_path)

        # copy the file to outbound folder
        s3_client.copy({'Bucket': report_bucket,'Key': qc_report_path}, bucket, qc_outbound_path)
        print("uploaded csv file to s3 outbound folder successfully:",bucket,qc_outbound_path)


    except Exception as e:
        print('Error while generating report, failed due to {}'.format(str(e)))
        raise(e)

    return qc_outbound_path, bucket



def lambda_handler(event, context):
    try:
        print(event)
        bucket = event['Records'][0]['s3']['bucket']['name']
        csv_file = event['Records'][0]['s3']['object']['key']
        s3_client =boto3.client('s3')
        print("Bucket Name: ",bucket)
        print("Filename: ",csv_file)
        config = json.load(open('conf_json.json', "r"))
        env = config['conf_json']['environment']
        source_name= bucket.replace('amgen-gco-asnf-','').replace('-bkt','').upper()
        #Generating batch_id for the load_data_process.
        #The batch_id is unique per feed and second (see generate_batch_id).
        #The sleep is kept so non-PCD files still start after the PCD file.
        if 'Patient_Case_Detail_Report' not in csv_file:
            time.sleep(65)
        batch_id = generate_batch_id(config,source_name,csv_file)
        sub= env.upper()+' : PAP Data load STARTED for ' +source_name
        status_start = 'Started'
        status = 'Hi Team,\n\n' + source_name + ' Data load is '+status_start+' with below batch_id\n\n''Batch_id:'+batch_id+'\n\n''Thanks,\n''PAP Team'
        notify_mail(subject=sub,vendor=source_name,status=status)
        temp_path ='/tmp/local_csv_file.csv'
        s3_client.download_file(bucket,csv_file,temp_path)
        s3 = boto3.resource('s3')
        s3obj = s3.Object(bucket,csv_file)
        filedata= s3obj.get()["Body"].read()
        src_count = filedata.decode('ISO-8859-1').count('\n')
        print("Source Csv File Record Count :",src_count)
        archive_file(csv_file, bucket,config,temp_path,s3_client)
        csv_file_value = pd.read_csv(temp_path,encoding='ISO-8859-1',dtype=object,na_filter=False,delimiter='^').replace(r'[\xc2\x92]',"\x27",regex=True).replace(r'[\xc2\x96]',"-",regex=True).replace(r'[\x99]',"™",regex=True).replace(r'^\s*$','',regex=True)
        print("File Content Details using Pandas", csv_file_value)
        sysdate = datetime.datetime.now()
        csv_file_value["EXTERNAL_SOURCE"] = source_name
        csv_file_value["CREATED_BY"] = "S3toFactLoad.py"
        csv_file_value["CREATED_DT"] = sysdate
        csv_file_value["BATCH_ID"] = batch_id
        record_count = len(csv_file_value.index)
        print("File Record Count after adding audit columns",record_count)
        print("File after adding audit columns:", csv_file_value)
        print(sysdate)
        final_csv = csv_file_value.to_csv(temp_path,index=False,sep='^')
        print("Csv File is ready to load the data into RDS database")

        #Upload file to archive folder in s3
        with open(temp_path, 'rb') as data:
            #now = datetime.datetime.now().strftime("%d%m%Y")
            replace_value =env+'/inbound/'
            upload_filename = csv_file.replace(replace_value,'')
            upload_path = env+'/archive/archive_'+upload_filename
            s3_client.upload_fileobj(data, bucket, upload_path)
            print("uploaded transformed csv file to s3 archive folder successfully")

        if loadcsvfiletords(connection_string, temp_path,source_name,csv_file) is True:
            execute_query("insert into asnfdm.pap_data_process_log (batch_id,vendor_name,start_dt,s3_source_count,s3tostage) values ('"+batch_id+"','"+source_name+"',current_timestamp,"+str(src_count)+",'SUCCESS')")
        else:
            execute_query("insert into asnfdm.pap_data_process_log (batch_id,vendor_name,start_dt,s3_source_count,s3tostage) values ('"+batch_id+"','"+source_name+"',current_timestamp,NULL,'FAILED')")
            message = "Error while loading csv file. Please check cloudwatch log for more details... "
            raise Exception(message)
        stg_status =execute_query("select s3tostage from asnfdm.pap_data_process_log where batch_id ='"+batch_id+"'")
        print("Stage table load status:",stg_status)

        #Automation script QC
        if stg_status == 'SUCCESS':
            rds_table = rdstablename(source_name,csv_file)
            print("Stage Table Name :",rds_table)
            stage_count = execute_query("select count(*) from "+rds_table)
            print("Record count of Stage Table :",stage_count)
            execute_query("update asnfdm.pap_data_process_log set stage_count ="+str(stage_count)+" where batch_id ='"+batch_id+"'")
            print("Successfully loaded csv file to Stage_table")
            counts_validation(record_count,src_count,batch_id,source_name,env)

            # Custom fix for Sonexus PCD (ASNF-approved, RITM1998459)
            # Always run after PCD load and before QC/Exception
            update_sql = """
            UPDATE asnfdm.stg_pcd_snx SET     enrollment_status = 'Approved',     enrollment_sub_status = CASE         WHEN case_id = '04989320' THEN 'Affordability - High Cost Share'         WHEN case_id = '05078942' THEN 'Uninsured'     END,     enrollment_reason_code = CASE         WHEN case_id = '04989320' THEN 'Medicare Advantage'         WHEN case_id = '05078942' THEN 'No Insurance Coverage'     END WHERE case_id IN ('04989320', '05078942');
            """
            execute_query(update_sql)
            print("Applied custom corrections to stg_pcd_snx before QC")

            # QC script check and execution
            if search('Patient_Case_Detail_Report',csv_file):
                QC_check(connection_string,batch_id,source_name)
            else:
                print(f"No QC for the file: {csv_file}")
                execute_query("update asnfdm.pap_data_process_log set quality_check ='SUCCESS' where batch_id ='"+batch_id+"'")
        else:
            execute_query("update asnfdm.pap_data_process_log set s3tostage ='FAILED',stage_count=NULL where batch_id ='"+batch_id+"'")
            message = "Error while loading stage tables. Please check cloudwatch log for more details... "
            raise Exception(message)
        QC_status=execute_query("select quality_check from asnfdm.pap_data_process_log where batch_id ='"+batch_id+"'")
        print("QC check status:",QC_status)


        # Code for Dimension tables load. Add dimension tables if needed.

        if QC_status == 'SUCCESS':
            print("QC completed")
            execute_query("update asnfdm.pap_data_process_log set stagetodim ='SUCCESS' where batch_id ='"+batch_id+"'")
        else:
            execute_query("update asnfdm.pap_data_process_log set quality_check ='FAILED',stage_count=NULL where batch_id ='"+batch_id+"'")
            message = "Error while QC. Please check cloudwatch log for more details... "
            raise Exception(message)
        dimension_status=execute_query("select stagetodim from asnfdm.pap_data_process_log where batch_id ='"+batch_id+"'")
        print("Dimension table load status:",dimension_status)

        # Fact table load
        if dimension_status =='SUCCESS':
            print("Dimension load Completed")
            load_data_dimension_to_fact(connection_string,batch_id,csv_file,rds_table,source_name)
        else:
            execute_query("update asnfdm.pap_data_process_log set stagetodim ='FAILED' where batch_id ='"+batch_id+"'")
            message = "Error while loading Dimensions. Please check cloudwatch log for more details... "
            raise Exception(message)
        facts_status=execute_query("select stage_dimtofact from asnfdm.pap_data_process_log where batch_id ='"+batch_id+"'")
        print("Fact table load status:",facts_status)
        if facts_status == 'SUCCESS':
            print("Fact load Completed")
        else:
            execute_query("update asnfdm.pap_data_process_log set stage_dimtofact ='FAILED' where batch_id ='"+batch_id+"'")
            execute_query("update asnfdm.pap_data_process_log set end_dt =now() where batch_id ='"+batch_id+"'")
            message = "Error while loading fact. Please check cloudwatch log for more details... "
            raise Exception(message)

    #QC mail
        if search('Patient_Case_Detail_Report',csv_file):
            qc_table_mail_name = f"{source_name.lower()}_qc_table"
            qc_table_mail = config['conf_json']['QC_details'][qc_table_mail_name]
            print("qc_table_mail:",qc_table_mail)
            QC_null = execute_query("select count(*) from " + qc_table_mail)


            if int(QC_null) == 0:
                print("Quality Check is successful and no failed records for the vendor", source_name)
            else:
                pcd_replace_value =env+'/inbound/'
                pcd_file_name = csv_file.replace(pcd_replace_value,'')
                print("PCD File Name:",pcd_file_name)
                #message = '\n'.join(QC_null

                qc_s3_report_path, s3_report_bucket = load_report_to_s3(connection_string,source_name,bucket,csv_file,env,batch_id)

                sub= env.upper()+' : PAP Data Load Quality Check for ' +source_name
                status = 'Hi Team,\n\nThe File (' + pcd_file_name + ') has failed the Data Quality Check. Please find the report uploaded in S3 outbound Folder. Please validate and update the required fields.\n\nThanks,\n''PAP Team'
                content = f"""<html><body>
                <p style="font-family: Calibri, sans-serif; font-size: 14px;">Hi Team,<br><br>\
                The File (<b>'{pcd_file_name}'</b>) has failed the Data Quality Check. Please find the report uploaded in S3 outbound Folder. Please validate and update the required fields. <br><br>\
                <b>Report path :</b> '{s3_report_bucket}/{qc_s3_report_path}'<br><br>\
                Thanks,<br>\
                PAP Team</p>\
                </body></html>"""
                send_email(subject=sub,vendor=source_name,content=content)
                notify_mail(subject=sub,vendor=source_name,status=status)


    # updating success for QC after QC mail sent

        #if search('Patient_Case_Detail_Report',csv_file):
        #    execute_query("update asnfdm.PAP_QC_data_count set status = 'SUCCESS' where batch_id ='"+batch_id+"' and vendor_name ='" + source_name + "'")

        sub=env.upper()+' :PAP Data load COMPLETED for ' +source_name
        status_complete='Completed'
        status = 'Hi Team,\n\n' + source_name + ' Data load is '+status_complete+' for below batch_id\n\n''Batch_id:'+batch_id+'\n\n''Thanks,\n''PAP Team'
        notify_mail(subject=sub,vendor=source_name,status=status)

        print("Data processing is completed")


    except Exception as e:
        sub=env.upper()+' :PAP Data load FAILED for ' +source_name+' | '+batch_id
        failed_status= 'Failed'
        status = 'Hi Team,\n\n' + source_name + ' Data load is '+failed_status+' due to below error\n\n''Error_message:'+str(e)+'\n\n''Thanks,\n''PAP Team'
        notify_mail(subject=sub,vendor=source_name,status=status)
        print('Error {}'.format(str(e)))

    return{
        'statusCode':200,
        'body':json.dumps('PAP Data Load')
    }