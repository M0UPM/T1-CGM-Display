# Security policy

This project displays health data and reads a credentials file, so a
couple of things are worth stating plainly.

## Reporting a problem

If you find a security issue — anything that could expose credentials, health
data, or let someone reach the display from outside the local network — please
**don't open a public issue for it.**

Instead, use GitHub's private reporting:

1. Go to the **Security** tab of this repository
2. Click **Report a vulnerability**

That keeps the details out of public view until there's a fix. If private
reporting isn't enabled for a fork you're using, contact the maintainer
directly rather than filing a public issue.

## Before you paste anything into an issue

The one file that must never appear in an issue, a screenshot, or a commit is
**`.env`**. It holds LibreLinkUp, Glooko, Nightscout and notification
credentials in plain text.

- If you're asking for help, redact tokens, passwords, patient IDs and account
  emails first.
- A glucose graph is health data. Think before posting a screenshot of a real
  one — the mock preview (`kitchen-preview` / invented data) is fine.
- If you ever commit `.env` by accident, treat every credential in it as
  compromised: **change them**, don't just delete the file. Git history keeps
  everything.

## What this project is, and isn't

This is a monitoring and record display. It is **not** a medical device, and it
is **not** an alarm — the CGM manufacturer's own app remains the alarm and the
safety-critical path. A security issue here means exposed data, not a risk to
insulin delivery: nothing in this project controls a pump or doses insulin.

## Scope

The design assumes a trusted local network:

- Nothing is exposed to the internet by default. The only outbound traffic is
  the poll to the CGM vendor and the encrypted backup.
- `AUTH_DEFAULT_ROLES` is `readable` on that assumption. If you expose the
  display beyond your LAN, that becomes a real vulnerability — change it to
  `denied` first (see the README).

Reports about the LAN-only defaults being insecure when deliberately exposed to
the internet are understood, not bugs — the README already warns against it.
