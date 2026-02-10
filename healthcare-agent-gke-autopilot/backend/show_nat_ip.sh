#!/bin/bash

kubectl run curl-ip-check-$(date +%s) --image=curlimages/curl --restart=Never --rm -it -- curl -s https://api.ipify.org && echo ""