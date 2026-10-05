#!/usr/bin/env bash
# Points a name of our Route 53 zone at an ALB created by Kubernetes, or removes it.
#   dns-record.sh upsert <name> <alb-hostname>   e.g. upsert dev.example.com boutique-dev-123.us-east-1.elb.amazonaws.com
#   dns-record.sh delete <name>
# Needs DNS_ZONE_ID (Terraform output tls.zone_id) and AWS credentials.
set -euo pipefail
: "${DNS_ZONE_ID:?}"
action=${1:?upsert|delete}
name=${2:?record name}
name=${name%.}

case "$action" in
  upsert)
    alb=${3:?ALB hostname}
    # Alias record: free, follows the ALB's IPs, no TTL to wait for.
    canonical=$(aws elbv2 describe-load-balancers \
      --query "LoadBalancers[?DNSName=='${alb}'].CanonicalHostedZoneId | [0]" --output text)
    [ -n "$canonical" ] && [ "$canonical" != None ] || { echo "::error::no load balancer named ${alb}"; exit 1; }
    jq -n --arg name "$name" --arg alb "$alb" --arg zone "$canonical" '{
      Comment: "week3: points at an ALB created by Kubernetes",
      Changes: [{ Action: "UPSERT", ResourceRecordSet: {
        Name: $name, Type: "A",
        AliasTarget: { HostedZoneId: $zone, DNSName: ("dualstack." + $alb), EvaluateTargetHealth: false }
      } }]
    }' > dns-change.json
    aws route53 change-resource-record-sets --hosted-zone-id "$DNS_ZONE_ID" \
      --change-batch file://dns-change.json --query 'ChangeInfo.Status' --output text
    rm -f dns-change.json
    echo "${name} -> ${alb}"
    ;;
  delete)
    # Remove the record exactly as it is (Route 53 needs the current values to delete it).
    aws route53 list-resource-record-sets --hosted-zone-id "$DNS_ZONE_ID" \
      --query "ResourceRecordSets[?Name=='${name}.' && Type=='A']" --output json > dns-current.json
    if [ "$(jq length dns-current.json)" = 0 ]; then
      echo "${name}: no record"
    else
      jq '{Changes: [.[] | {Action: "DELETE", ResourceRecordSet: .}]}' dns-current.json > dns-change.json
      aws route53 change-resource-record-sets --hosted-zone-id "$DNS_ZONE_ID" \
        --change-batch file://dns-change.json --query 'ChangeInfo.Status' --output text
      echo "${name}: deleted"
    fi
    rm -f dns-current.json dns-change.json
    ;;
  *) echo "usage: $0 upsert <name> <alb-hostname> | delete <name>"; exit 1 ;;
esac
