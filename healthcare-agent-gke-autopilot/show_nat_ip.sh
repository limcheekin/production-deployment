#!/bin/bash

gcloud compute addresses list --filter="region:us-central1" --format="table(name,address,region,status)"