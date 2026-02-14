#!/bin/bash

PROJECT_ID=$(gcloud config get-value project 2>/dev/null)
REGION="us-central1"
ROUTER_NAME="parlant-router"

echo "Fetching NAT IPs for Router: $ROUTER_NAME..."

# Fetch router status in JSON format
NAT_STATUS=$(gcloud compute routers get-status $ROUTER_NAME --region=$REGION --format="json" 2>/dev/null)

if [ -z "$NAT_STATUS" ]; then
    echo "Error: Unable to fetch router status. Ensure you are authenticated with gcloud and the router exists."
    exit 1
fi

# Extract IPv4 addresses from the output
# This assumes the only IPs in the status output are the NAT IPs.
# The output typically looks like: "autoAllocatedNatIps": [ "34.x.x.x" ]
# We grep for standard IPv4 pattern.
IPS=$(echo "$NAT_STATUS" | grep -oE '[0-9]{1,3}\.[0-9]{1,3}\.[0-9]{1,3}\.[0-9]{1,3}' | sort | uniq)

if [ -z "$IPS" ]; then
    echo "No NAT IPs found."
else
    echo "NAT IP Addresses:"
    echo "$IPS"
fi