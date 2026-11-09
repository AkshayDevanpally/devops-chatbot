"""QwenOps kill switch: called by the monthly budget (through SNS) at 100% of actual spend.

In every enabled region it terminates every EC2 instance (running or stopped, tagged or not,
termination protection removed first), cancels open Spot requests, deletes NAT gateways and
releases Elastic IPs that are not attached. EBS volumes and snapshots are left alone (they may
hold data and cost little). Invoke with {"dry_run": true} to see what it would do.
"""
import json

import boto3

LIVE = ["pending", "running", "stopping", "stopped"]


def handler(event, context):
    dry = isinstance(event, dict) and bool(event.get("dry_run"))
    regions = [r["RegionName"] for r in boto3.client("ec2").describe_regions()["Regions"]]
    report, errors = {}, []
    for region in regions:
        ec2 = boto3.client("ec2", region_name=region)
        found = {}
        try:
            ids = [i["InstanceId"]
                   for page in ec2.get_paginator("describe_instances").paginate(
                       Filters=[{"Name": "instance-state-name", "Values": LIVE}])
                   for r in page["Reservations"] for i in r["Instances"]]
            spot = [s["SpotInstanceRequestId"] for s in ec2.describe_spot_instance_requests(
                Filters=[{"Name": "state", "Values": ["open", "active"]}])["SpotInstanceRequests"]]
            nat = [n["NatGatewayId"] for n in ec2.describe_nat_gateways(
                Filters=[{"Name": "state", "Values": ["pending", "available"]}])["NatGateways"]]
            eips = [a["AllocationId"] for a in ec2.describe_addresses()["Addresses"]
                    if "AssociationId" not in a and "AllocationId" in a]
            found = {k: v for k, v in
                     {"instances": ids, "spot_requests": spot, "nat_gateways": nat, "elastic_ips": eips}.items() if v}
            if found and not dry:
                if spot:
                    ec2.cancel_spot_instance_requests(SpotInstanceRequestIds=spot)
                for i in ids:
                    try:
                        ec2.modify_instance_attribute(InstanceId=i, DisableApiTermination={"Value": False})
                    except Exception as exc:  # keep going: terminate is what matters
                        errors.append(f"{region} {i} protection: {exc}")
                if ids:
                    ec2.terminate_instances(InstanceIds=ids)
                for n in nat:
                    ec2.delete_nat_gateway(NatGatewayId=n)
                for a in eips:
                    ec2.release_address(AllocationId=a)
        except Exception as exc:
            errors.append(f"{region}: {exc}")
        if found:
            report[region] = found
    result = {"dry_run": dry, "regions_checked": len(regions), "acted_on": report, "errors": errors}
    print(json.dumps(result))
    return result
