# finops-ec2-slack-bot

Self-service Slack bot to start dev EC2 instances for a bounded time window.
An instance only runs when a developer asks for it,
and stops automatically when the window closes.

## How it works

```
/ec2 wake <id|name>
        |
        v
  Lambda (Function URL)  <-- HMAC signature check
        |
        +--> shows duration buttons (1h .. 8h)
        |
   [click]
        |
        +--> ec2:StartInstances
        +--> EventBridge Scheduler: one-time schedule at T+Nh
                    |
              [window expires]
                    |
                    +--> Lambda --> ec2:StopInstances + Slack message
```

The only time-based mechanism is the one-time re-stop schedule. It carries
`ActionAfterCompletion=DELETE`, so it removes itself after firing.

Schedules are named `autostop-<instance-id>`. A second `wake` on the same
instance overwrites the first one, so the last order always wins. Durations are
independent per instance.

Failed invocations land in an SQS dead-letter queue, watched by a CloudWatch
alarm that posts to Slack and sends an email.

## Requirements

| | |
|---|---|
| Terraform | >= 1.11 (S3 backend with `use_lockfile`) |
| AWS provider | ~> 6.0 |
| archive provider | ~> 2.7 |
| Runtime | Python 3.13, arm64 |

## Usage

```hcl
module "ec2_slack_bot" {
  source = "github.com/<you>/ec2-slack-bot//modules/ec2-slack-bot"

  alert_channel    = "C0XXXXXXXXX"
  allowed_channels = ["C0XXXXXXXXX"]
  alert_email      = "ops@example.com"
}
```

## Setup

Four steps, in this order. Steps 1 and 3 are not automated.

### 1. Create the Slack app

On api.slack.com/apps, choose **From an app manifest** and paste:

```yaml
display_information:
  name: EC2 Bot
  description: Self-service wake-up for dev EC2 instances
features:
  bot_user:
    display_name: ec2bot
    always_online: false
  slash_commands:
    - command: /ec2
      url: https://example.com/placeholder
      description: Manage dev EC2 instances
      usage_hint: list | wake <id> | stop <id>
      should_escape: false
oauth_config:
  scopes:
    bot:
      - commands
      - chat:write
settings:
  interactivity:
    is_enabled: true
    request_url: https://example.com/placeholder
  org_deploy_enabled: false
  socket_mode_enabled: false
  token_rotation_enabled: false
```

The placeholder URL is intentional; you do not know the Function URL yet.
Install the app, then collect the **signing secret** (Basic Information) and the
**bot token** (OAuth & Permissions).

### 2. Apply

```bash
terraform init
terraform apply
```

### 3. Push the secret value

The module creates the secret container only. The value is pushed out of band so
it never reaches the state file.

```bash
aws secretsmanager put-secret-value \
  --secret-id ec2bot/slack \
  --secret-string '{"signing_secret":"...","bot_token":"xoxb-..."}'
```

Until this runs, the Lambda fails with `ResourceNotFoundException`.

### 4. Wire the URL back into Slack

```bash
terraform output function_url
```

Paste it in the app manifest, in **both** places: the slash command `url` and
`settings.interactivity.request_url`. Then invite the bot to the channel:

```
/invite @ec2bot
```

On a private channel `/invite` may not resolve the handle. Use the channel menu:
**Integrations** > **Add an App**. Without this, `chat.postMessage` returns
`channel_not_found` (Slack hides private channels from apps that are not
members).

## Tagging instances

The bot only sees and touches instances carrying the managed tag. This is
enforced by an IAM condition, not by application code:

```hcl
tags = {
  SlackBotManaged = "true"
}
```

## Commands

| Command | Effect |
|---|---|
| `/ec2 list` | List managed instances and their state |
| `/ec2 wake <id\|name>` | Show duration buttons, then start + schedule the stop |
| `/ec2 stop <id\|name>` | Stop now and cancel the pending schedule |

Instances can be addressed by ID or by their `Name` tag. Ambiguous names return
the list of matching IDs rather than picking one.

## Inputs

| Name | Type | Default | Description |
|---|---|---|---|
| `alert_channel` | `string` | required | Slack channel ID receiving alarms |
| `allowed_channels` | `list(string)` | `[]` | Channel allowlist. **Empty means no restriction** |
| `alert_email` | `string` | `""` | Email subscribed to alarms. Empty means no subscription |
| `name_prefix` | `string` | `"ec2bot"` | Prefix for every created resource |
| `managed_tag` | `string` | `"SlackBotManaged"` | Tag key marking manageable instances |
| `slack_secret_arn` | `string` | `""` | Existing secret ARN. Empty means the module creates one |
| `reserved_concurrency` | `number` | `null` | Reserved concurrency. `null` means none |
| `log_retention_days` | `number` | `14` | CloudWatch log retention |
| `secret_recovery_days` | `number` | `7` | Set to `0` in sandboxes for immediate deletion |
| `tags` | `map(string)` | `{}` | Additional tags |

## Outputs

| Name | Description |
|---|---|
| `function_url` | URL to paste into the Slack manifest |
| `secret_arn` | Where to push `signing_secret` and `bot_token` |
| `dlq_url` | Dead-letter queue URL |
| `alerts_topic_arn` | SNS topic, reusable for other alarms |

## Security model

**Blast radius is bounded by IAM, not by code.** `ec2:StartInstances` and
`ec2:StopInstances` are allowed only on resources carrying the managed tag, with
an explicit `Deny` on everything else. The bot cannot touch production even if
the application logic is wrong.

`ec2:DescribeInstances` does not support resource-level permissions, so the bot
reads the whole account. The tag filter in the code is what keeps `/ec2 list`
from leaking your inventory. That is a code guarantee, not an IAM one.

**Every Slack request is verified** with the HMAC signature and a 5-minute
timestamp window before anything else happens. The Function URL is public and
uses `authorization_type = NONE`; the signature is the authentication.

**Any workspace member can run the command.** Slack offers no access control on
slash commands. `allowed_channels` is the only gate, and it defaults to open.
Set it.

## Known limitations

- Slash commands cannot be restricted per user by Slack. Only channel-level
  filtering is implemented.
- The re-stop notification fires right after the API call, so it reports the
  request, not the confirmed `stopped` state.
- No fallback on `InsufficientInstanceCapacity`. A wake-up can fail if the AZ
  has no capacity for that instance type. The instance is pinned to its AZ by
  its EBS volumes, so the only lever would be resizing.
- The DLQ is the single detection path for failed re-stops. If it fails too, the
  failure is invisible.
- Destroying and re-applying changes the Function URL, which then has to be
  pasted back into the Slack manifest by hand.

## Cost

Roughly 0.40 USD/month for the Secrets Manager secret, plus a few cents for
Lambda, SQS and CloudWatch at typical volumes. Lambda invocations cost about
1.50 USD per million at 256 MB on arm64. The secret is the largest line item.

## Development

```bash
ruff format modules/ec2-slack-bot/src/handler.py
ruff check  modules/ec2-slack-bot/src/handler.py
cd examples/dev && terraform apply
```

Before releasing, generate a multi-platform lock file so the module works on
machines other than yours:

```bash
terraform providers lock \
  -platform=linux_amd64 \
  -platform=darwin_arm64 \
  -platform=linux_arm64
```

## Roadmap

- Async response pattern: acknowledge immediately, work via `response_url`
- EventBridge rule on EC2 state-change to report the confirmed state
- Instance type fallback on capacity errors
- Dropdown selector instead of typing an identifier
- User allowlist in addition to channels
- CloudFront in front of the Function URL for a stable address

## License

MIT, see [LICENSE](LICENSE).
