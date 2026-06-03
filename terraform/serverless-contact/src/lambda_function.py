# terraform/serverless-contact/src/lambda_function.py
import json
import os

import boto3

ses = boto3.client("sesv2")
SENDER    = os.environ["SENDER_EMAIL"]
RECIPIENT = os.environ["RECIPIENT_EMAIL"]


def _resp(status: int, body: dict) -> dict:
    return {
        "statusCode": status,
        "headers": {"content-type": "application/json"},
        "body": json.dumps(body),
    }


def lambda_handler(event, context):
    method = event.get("requestContext", {}).get("http", {}).get("method")
    if method != "POST":
        return _resp(405, {"error": "method not allowed"})

    try:
        body = json.loads(event.get("body") or "{}")
        name    = body["name"].strip()
        email   = body["email"].strip()
        message = body["message"].strip()
    except (KeyError, AttributeError, ValueError):
        return _resp(400, {"error": "name, email, and message are required"})

    if not (name and email and message):
        return _resp(400, {"error": "all fields must be non-empty"})

    ses.send_email(
        FromEmailAddress=SENDER,
        Destination={"ToAddresses": [RECIPIENT]},
        ReplyToAddresses=[email],   # reply goes to the submitter, not to ourselves
        Content={
            "Simple": {
                "Subject": {"Data": f"CloudCare contact from {name}"},
                "Body": {
                    "Text": {"Data": f"From: {name} <{email}>\n\n{message}"}
                },
            }
        },
    )

    return _resp(200, {"status": "sent"})