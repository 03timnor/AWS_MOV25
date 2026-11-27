"""novatrix-site-check: asks the site like a visitor (from OUTSIDE the VPC).

Runs every 5 minutes (EventBridge). Each check fetches one page through the
load balancer and demands HTTP 200 AND a text that proves the RIGHT content
answered (not e.g. an error page). Two metrics to CloudWatch, namespace
Novatrix/SiteCheck, dimension Site:
  Available       1 = every check passed, 0 = at least one failed
  ResponseTimeMs  the start page
The alarms in the monitoring layer watch them and mail via SNS. One JSON line
per check goes to the log -> searchable with Logs Insights.

The deployed code is inline in templates/V48_06-monitoring.yaml (no zip, no
build step); the deploy script refuses to run if the two differ.
"""
import json
import os
import ssl
import time
import urllib.error
import urllib.request

import boto3

cloudwatch = boto3.client("cloudwatch")
# The ALB's certificate is self-signed (no domain yet): check that HTTPS
# answers with the site, not who signed the certificate.
NO_VERIFY = ssl._create_unverified_context()


def check(url, must_contain):
    start = time.time()
    try:
        request = urllib.request.Request(url, headers={"User-Agent": "novatrix-site-check"})
        with urllib.request.urlopen(request, timeout=10, context=NO_VERIFY) as answer:
            status = answer.status
            body = answer.read(300000).decode("utf-8", "replace")
    except urllib.error.HTTPError as error:
        status, body = error.code, ""
    except Exception as error:
        status, body = 0, repr(error)
    ok = int(status == 200 and must_contain in body)
    ms = round((time.time() - start) * 1000)
    print(json.dumps({"url": url, "status": status, "ok": ok, "ms": ms,
                      "error": "" if ok or status else body[:200]}))
    return ok, ms


def lambda_handler(event, context):
    site = os.environ["SITE_URL"]
    # CHECKS = "path|text,path|text,..." (set in the template)
    checks = [c.split("|", 1) for c in os.environ["CHECKS"].split(",")]
    targets = [(site + path, text) for path, text in checks]
    if os.environ.get("HTTPS_URL"):
        targets.append((os.environ["HTTPS_URL"] + "/", checks[0][1]))
    results = [check(url, text) for url, text in targets]
    available = min(ok for ok, _ in results)
    ms = results[0][1]
    dims = [{"Name": "Site", "Value": os.environ["SITE_NAME"]}]
    cloudwatch.put_metric_data(Namespace="Novatrix/SiteCheck", MetricData=[
        {"MetricName": "Available", "Dimensions": dims, "Value": available, "Unit": "Count"},
        {"MetricName": "ResponseTimeMs", "Dimensions": dims, "Value": ms, "Unit": "Milliseconds"},
    ])
    print(json.dumps({"summary": True, "available": available, "passed": sum(ok for ok, _ in results),
                      "checks": len(results), "ms": ms}))
    return {"available": available, "passed": sum(ok for ok, _ in results),
            "checks": len(results), "ms": ms}
