# Security

## Reporting

Report a vulnerability privately through GitHub's
[security advisory](https://github.com/Prog-Jacob/ntfy-agent/security/advisories/new)
form. Please do not open a public issue for anything exploitable.

Supported version: the latest release.

## Threat model

**The ntfy topic is a bearer credential.** On ntfy.sh there are no accounts, so
whoever knows the topic can read every notification published to it, and the
server caches messages by default. `setup` generates a random 128-bit topic and
writes the config `600` for that reason. Treat a topic like a password: do not
commit it, paste it, or put it in a screenshot. Rotate by editing
`NTFY_AGENT_URLS` and resubscribing your phone.
 
**The agent's output is untrusted input.** The assistant's last message ends up
in HTTP headers, a JSON body, an AppleScript string and a PowerShell command,
and a coding agent's output can contain anything it read from your repository or
the internet. The notification path therefore:

- flattens the message to a single line, so it cannot split an HTTP header
- JSON-escapes every interpolated field, including `session_id` and the click
  URL, so it cannot inject keys into a webhook body
- passes the body to curl on **stdin**, never as an argument, because curl reads
  a value beginning with `@` as a filename and a message of `@/etc/passwd` would
  otherwise post that file to your notification server
- passes destinations and tokens to curl in a config file rather than argv, so
  they do not appear in `ps`
- hands `cmd://` values to `sh -c` with the notification in environment
  variables, never interpolated into the command string

If you set `NTFY_AGENT_BODY=none`, only the title is sent, which keeps code and
file paths off a third-party server entirely.
