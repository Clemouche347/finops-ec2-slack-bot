import base64
import hashlib
import hmac
import json
import logging
import os
import time
import urllib.parse
import urllib.request
from datetime import datetime, timedelta, timezone

import boto3

log = logging.getLogger()
log.setLevel(logging.INFO)

ec2 = boto3.client("ec2")
scheduler = boto3.client("scheduler")

MANAGED_TAG = os.environ["MANAGED_TAG"]
SECRET_ARN = os.environ["SLACK_SECRET_ARN"]
SCHEDULE_GROUP = os.environ["SCHEDULE_GROUP"]
SCHEDULER_ROLE_ARN = os.environ["SCHEDULER_ROLE_ARN"]

ALLOWED_CHANNELS = [c for c in os.environ.get("ALLOWED_CHANNELS", "").split(",") if c]

DURATIONS = [1, 2, 3, 4, 6, 8]

DLQ_ARN = os.environ["DLQ_ARN"]

ALERT_CHANNEL = os.environ["ALERT_CHANNEL"]

_secrets = None


def secrets():
    global _secrets
    if _secrets is None:
        sm = boto3.client("secretsmanager")
        raw = sm.get_secret_value(SecretId=SECRET_ARN)["SecretString"]
        _secrets = json.loads(raw)
    return _secrets


def verify(headers, raw_body):
    ts = headers.get("x-slack-request-timestamp")
    sig = headers.get("x-slack-signature")
    if not ts or not sig:
        return False
    if abs(time.time() - int(ts)) > 300:
        return False
    base = f"v0:{ts}:{raw_body}".encode()
    expected = (
        "v0="
        + hmac.new(
            secrets()["signing_secret"].encode(), base, hashlib.sha256
        ).hexdigest()
    )
    return hmac.compare_digest(expected, sig)


def reply(text):
    return {
        "statusCode": 200,
        "headers": {"content-type": "application/json"},
        "body": json.dumps({"response_type": "ephemeral", "text": text}),
    }


def managed_instances():
    pages = ec2.get_paginator("describe_instances").paginate(
        Filters=[{"Name": f"tag:{MANAGED_TAG}", "Values": ["true"]}]
    )
    out = {}
    for page in pages:
        for res in page["Reservations"]:
            for i in res["Instances"]:
                name = next(
                    (t["Value"] for t in i.get("Tags", []) if t["Key"] == "Name"),
                    i["InstanceId"],
                )
                out[i["InstanceId"]] = {"name": name, "state": i["State"]["Name"]}
    return out


def schedule_name(instance_id):
    return f"autostop-{instance_id}"


def set_autostop(instance_id, hours, channel, user, lambda_arn):
    at = datetime.now(timezone.utc) + timedelta(hours=hours)
    params = {
        "Name": schedule_name(instance_id),
        "GroupName": SCHEDULE_GROUP,
        "ScheduleExpression": f"at({at.strftime('%Y-%m-%dT%H:%M:%S')})",
        "ScheduleExpressionTimezone": "UTC",
        "FlexibleTimeWindow": {"Mode": "OFF"},
        "ActionAfterCompletion": "DELETE",
        "Target": {
            "DeadLetterConfig": {"Arn": DLQ_ARN},
            "Arn": lambda_arn,
            "RoleArn": SCHEDULER_ROLE_ARN,
            "Input": json.dumps(
                {
                    "source": "autostop",
                    "instance_id": instance_id,
                    "channel": channel,
                    "user": user,
                }
            ),
            "RetryPolicy": {"MaximumRetryAttempts": 3},
        },
    }
    try:
        scheduler.create_schedule(**params)
    except scheduler.exceptions.ConflictException:
        scheduler.update_schedule(**params)
    return at


def clear_autostop(instance_id):
    try:
        scheduler.delete_schedule(
            Name=schedule_name(instance_id), GroupName=SCHEDULE_GROUP
        )
    except scheduler.exceptions.ResourceNotFoundException:
        pass


def post_slack(channel, text):
    req = urllib.request.Request(
        "https://slack.com/api/chat.postMessage",
        data=json.dumps({"channel": channel, "text": text}).encode(),
        headers={
            "Content-Type": "application/json",
            "Authorization": f"Bearer {secrets()['bot_token']}",
        },
    )
    with urllib.request.urlopen(req, timeout=5) as r:
        body = json.loads(r.read())
    if not body.get("ok"):
        log.error("slack post failed: %s", body.get("error"))
    return body


def duration_blocks(instance_id, name):
    return [
        {
            "type": "section",
            "text": {
                "type": "mrkdwn",
                "text": f"*{name}* `{instance_id}`\nDurée de la fenêtre ?",
            },
        },
        {
            "type": "actions",
            "elements": [
                {
                    "type": "button",
                    "text": {"type": "plain_text", "text": f"{h}h"},
                    "action_id": f"wake_{h}h",
                    "value": json.dumps({"i": instance_id, "h": h}),
                }
                for h in DURATIONS
            ],
        },
    ]


def respond_url(url, text):
    req = urllib.request.Request(
        url,
        data=json.dumps(
            {
                "response_type": "ephemeral",
                "replace_original": True,
                "text": text,
            }
        ).encode(),
        headers={"Content-Type": "application/json"},
    )
    with urllib.request.urlopen(req, timeout=5) as r:
        return r.read()


def resolve(token, inst):
    if token in inst:
        return token, None
    matches = [k for k, v in inst.items() if v["name"] == token]
    if len(matches) == 1:
        return matches[0], None
    if len(matches) > 1:
        ids = ", ".join(f"`{m}`" for m in matches)
        return None, f"Nom ambigu, {len(matches)} instances portent ce nom : {ids}"
    return None, f"Instance inconnue ou non gérée : {token}"


def handler(event, context):
    # 0. notification SNS d'une alarme CloudWatch
    if "Records" in event and event["Records"][0].get("EventSource") == "aws:sns":
        msg = json.loads(event["Records"][0]["Sns"]["Message"])
        icon = (
            ":rotating_light:"
            if msg["NewStateValue"] == "ALARM"
            else ":white_check_mark:"
        )
        post_slack(
            ALERT_CHANNEL,
            f"{icon} *{msg['AlarmName']}* → {msg['NewStateValue']}\n"
            f"{msg['NewStateReason']}",
        )
        return {"ok": True}

    # 1. invocation par EventBridge Scheduler, pas de HTTP
    if event.get("source") == "autostop":
        iid = event["instance_id"]
        log.info("autostop triggered for %s", iid)

        inst = managed_instances()
        if iid not in inst:
            log.warning("autostop on unmanaged instance %s", iid)
            return {"ok": False}

        ec2.stop_instances(InstanceIds=[iid])
        post_slack(
            event["channel"],
            f"Fin de fenêtre ouverte par {event.get('user', '?')} : "
            f"arrêt de {inst[iid]['name']} (`{iid}`).",
        )
        log.info("autostop done for %s", iid)
        return {"ok": True}

    # 2a. requete HTTP Slack
    raw = event.get("body") or ""
    if event.get("isBase64Encoded"):
        raw = base64.b64decode(raw).decode("utf-8")

    if not verify(event.get("headers", {}), raw):
        return {"statusCode": 401, "body": "unauthorized"}

    form = urllib.parse.parse_qs(raw)

    # 2b. channels autorisés
    channel = form.get("channel_id", [""])[0] or json.loads(
        form.get("payload", ["{}"])[0]
    ).get("channel", {}).get("id", "")
    if ALLOWED_CHANNELS and channel not in ALLOWED_CHANNELS:
        log.warning("blocked channel %s", channel)
        return reply("Commande non autorisée dans ce canal.")

    # 3. clic sur un bouton
    if "payload" in form:
        p = json.loads(form["payload"][0])
        log.info(
            "interaction channel=%s user=%s",
            p.get("channel", {}).get("id"),
            p.get("user", {}).get("username"),
        )
        v = json.loads(p["actions"][0]["value"])
        iid, hours = v["i"], v["h"]
        channel = p["channel"]["id"]
        user = p["user"]["username"]

        inst = managed_instances()
        if iid not in inst:
            return reply(f"Instance inconnue : {iid}")

        ec2.start_instances(InstanceIds=[iid])
        at = set_autostop(iid, hours, channel, user, context.invoked_function_arn)
        log.info("wake %s %sh by %s", iid, hours, user)

        ts = int(at.timestamp())
        post_slack(
            channel,
            f"{user} a réveillé {inst[iid]['name']} (`{iid}`) pour {hours}h. "
            f"Arrêt prévu à <!date^{ts}^{{time}}|{at.strftime('%H:%M')} UTC>.",
        )

        respond_url(
            p["response_url"],
            f"Réveil de {inst[iid]['name']} (`{iid}`) lancé pour {hours}h.",
        )
        return {"statusCode": 200, "body": ""}

    # 4. slash command
    args = (form.get("text", [""])[0]).split()
    action = args[0] if args else "list"
    target = args[1].strip("`<>\"' ") if len(args) > 1 else None

    log.info("command %s %s by %s", action, target, form.get("user_name", [""])[0])

    inst = managed_instances()

    if action == "list":
        if not inst:
            return reply("Aucune instance gérée.")
        return reply(
            "\n".join(f"`{k}` {v['name']} : {v['state']}" for k, v in inst.items())
        )

    if not target:
        return reply("Usage : /ec2 list | wake <id ou nom> | stop <id ou nom>")

    target, err = resolve(target, inst)
    if err:
        return reply(err)

    try:
        if action == "wake":
            return {
                "statusCode": 200,
                "headers": {"content-type": "application/json"},
                "body": json.dumps(
                    {
                        "response_type": "ephemeral",
                        "blocks": duration_blocks(target, inst[target]["name"]),
                    }
                ),
            }
        if action == "stop":
            clear_autostop(target)
            ec2.stop_instances(InstanceIds=[target])
            return reply(f"Arrêt de {inst[target]['name']} (`{target}`) en cours.")
    except ec2.exceptions.ClientError as e:
        return reply(f"Échec : {e.response['Error']['Code']}")

    return reply("Usage : /ec2 list | wake <id> | stop <id>")
