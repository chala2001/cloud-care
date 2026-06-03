# terraform/serverless-audit/src/lambda_function.py
import json
import os
import uuid
from datetime import datetime, timezone

import boto3

TABLE = boto3.resource("dynamodb").Table(os.environ["TABLE_NAME"])


def _resp(status: int, body: dict) -> dict:
    return {
        "statusCode": status,
        "headers": {"content-type": "application/json"},
        "body": json.dumps(body, default=str),
    }


def lambda_handler(event, context):
    method = event.get("requestContext", {}).get("http", {}).get("method")

    if method == "POST":
        body = json.loads(event.get("body") or "{}")
        item = {
            "event_id":    str(uuid.uuid4()),
            "ts":          datetime.now(timezone.utc).isoformat(),
            "entity_type": body.get("entity_type", "unknown"),
            "entity_id":   str(body.get("entity_id", "")),
            "action":      body.get("action", "unknown"),
            "actor":       body.get("actor", "system"),
        }
        TABLE.put_item(Item=item)
        return _resp(201, item)

    if method == "GET":
        # Simple Scan with a hard limit — fine at our size; see §4 for the
        # production pattern (GSI on a timestamp sort key).
        resp = TABLE.scan(Limit=50)
        return _resp(200, {"items": resp.get("Items", [])})

    return _resp(405, {"error": "method not allowed"})