# Cloud Monitoring Queries for Simulated Scale Testing

This document contains MQL (Monitoring Query Language) queries for monitoring
the Parlant infrastructure during load testing.

## Cloud NAT Monitoring

### Port Usage High-Water Mark

Shows the maximum port usage across all VM instances:

```sql
fetch gce_instance
| metric 'router.googleapis.com/nat/port_usage'
| group_by [resource.zone], max(val())
```

**Alert Threshold**: > 80% of `min_ports_per_vm` (e.g., > 3,276 if set to 4,096)

### NAT Allocation Failures

Critical failure signal - any value > 0 indicates connections are being dropped:

```sql
fetch nat_gateway
| metric 'router.googleapis.com/nat/nat_allocation_failed'
| align rate(1m)
| every 1m
```

**Alert Threshold**: > 0

### Dropped Packets (Out of Resources)

Packets dropped due to NAT resource exhaustion:

```sql
fetch gce_instance
| metric 'router.googleapis.com/nat/dropped_sent_packets_count'
| filter metric.reason == 'OUT_OF_RESOURCES'
| align rate(1m)
```

**Alert Threshold**: > 0

---

## GKE Metrics

### Pod CPU Utilization

Monitor CPU across Parlant pods:

```sql
fetch k8s_container
| metric 'kubernetes.io/container/cpu/core_usage_time'
| filter resource.container_name == 'parlant'
| align rate(1m)
| group_by [resource.pod_name], mean(val())
```

### Pod Memory Usage

Monitor for memory leaks during soak test:

```sql
fetch k8s_container
| metric 'kubernetes.io/container/memory/used_bytes'
| filter resource.container_name == 'parlant'
| group_by [resource.pod_name], mean(val())
```

### HPA Replica Count

Track autoscaling behavior:

```sql
fetch k8s_pod
| metric 'kubernetes.io/pod/phase'
| filter metadata.user_labels.app == 'parlant'
| group_by [], count(val())
```

---

## Dashboard Setup

1. Go to **Cloud Monitoring** > **Dashboards** > **Create Dashboard**
2. Add charts using the MQL queries above
3. Recommended layout:
   - Row 1: NAT Port Usage, NAT Failures, Dropped Packets
   - Row 2: Pod CPU, Pod Memory, HPA Replicas
4. Set refresh interval to 1 minute during testing

---

## Alert Policies

Create alerts for critical metrics:

| Metric | Condition | Severity |
|--------|-----------|----------|
| NAT Allocation Failed | > 0 for 1 min | Critical |
| Dropped Packets | > 0 for 1 min | Critical |
| Port Usage | > 80% for 5 min | Warning |
| Pod Memory | Slope > 0 for 30 min | Warning |
