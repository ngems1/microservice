# Real order emails with Amazon SES (emailservice), on top of the DynamoDB log and Slack.
# Needs the domain (DOMAIN_NAME, see dns.tf). Sender: orders@<domain>, signed with DKIM
# (records created in the Route 53 zone, so the domain is verified automatically).
#
# SES starts in "sandbox" mode: it only delivers TO verified addresses. The GitHub
# variable SES_RECIPIENTS (comma-separated) lists them: AWS emails each one a
# verification link, to click once. emailservice only sends to these addresses; every
# other order (load tests, example.com) stays in log mode.

locals {
  ses_enabled    = local.tls_enabled
  ses_from       = local.ses_enabled ? "orders@${var.domain_name}" : ""
  ses_recipients = local.ses_enabled ? toset(compact(split(",", replace(var.ses_recipients, " ", "")))) : toset([])
}

resource "aws_sesv2_email_identity" "domain" {
  count          = local.ses_enabled ? 1 : 0
  email_identity = var.domain_name
}

# Easy DKIM: three CNAME records prove we own the domain and sign every email.
resource "aws_route53_record" "ses_dkim" {
  count   = local.ses_enabled ? 3 : 0
  zone_id = data.aws_route53_zone.main[0].zone_id
  name    = "${aws_sesv2_email_identity.domain[0].dkim_signing_attributes[0].tokens[count.index]}._domainkey.${var.domain_name}"
  type    = "CNAME"
  ttl     = 600
  records = ["${aws_sesv2_email_identity.domain[0].dkim_signing_attributes[0].tokens[count.index]}.dkim.amazonses.com"]
}

# Sandbox: the addresses allowed to receive (AWS sends them a verification link).
resource "aws_sesv2_email_identity" "recipient" {
  for_each       = local.ses_recipients
  email_identity = each.value
}
