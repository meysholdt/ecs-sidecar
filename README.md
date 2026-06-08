# ecs-sidecar

Out-of-band tooling to attach a packet-capture (`tcpdump`) sidecar to a running
ECS **Fargate** service without modifying the service's infrastructure-as-code.

Useful for debugging connection-level issues (resets, missing ACKs, idle
timeouts) on a Fargate task whose host you cannot access. On Fargate all
containers in a task share one `awsvpc` network namespace, so a sidecar can
capture the task's own ENI traffic — and own-ENI capture does **not** require
`NET_ADMIN` or a privileged container.

## Scripts

| Script | Purpose |
|--------|---------|
| `add-tcpdump-sidecar.sh` | Registers a new task-definition revision that appends a non-essential `tcpdump` sidecar and a writable `pcap` volume, then points the service at it. Records the original revision to a state file. |
| `remove-tcpdump-sidecar.sh` | Reverts the service to the original task definition, waits for it to stabilize, deregisters the temporary revision, and deletes the state file. |

## How it works

1. Reads the task definition currently running on the target service.
2. Appends a `tcpdump` sidecar (`nicolaka/netshoot`) that auto-detects the data
   ENI (skips `lo`/`eth0`, falls back to `eth1`) and runs a rotating capture.
3. Adds a dedicated writable `pcap` volume (many task root filesystems are
   read-only).
4. Registers a new task-definition revision and updates the service to it.

The sidecar is `essential: false`, so it can never take down the main
container.

## Usage

```bash
# Attach the capture sidecar (recycles the task)
./add-tcpdump-sidecar.sh

# ... reproduce the issue, collect pcaps ...

# Restore the original task definition and clean up (recycles the task)
./remove-tcpdump-sidecar.sh
```

### Configuration

Override via environment variables:

| Variable | Default | Description |
|----------|---------|-------------|
| `AWS_PROFILE` | example profile | AWS CLI profile |
| `AWS_REGION` | `eu-west-1` | Region |
| `CLUSTER` | example proxy cluster | ECS cluster name |
| `SERVICE` | example proxy service | ECS service name |
| `SIDECAR_IMAGE` | `nicolaka/netshoot:latest` | Capture image (must provide `tcpdump`) |
| `CAPTURE_FILTER` | `tcp` | BPF filter, e.g. `tcp port 8443` |
| `PCAP_FILE_MB` | `50` | MB per rotated file (`tcpdump -C`) |
| `PCAP_FILE_COUNT` | `10` | Files kept (`tcpdump -W`) |
| `PCAP_S3_PREFIX` | _(unset)_ | If set, sidecar syncs pcaps to this `s3://…` prefix |

### Retrieving captures

- If `PCAP_S3_PREFIX` is set, rotated files sync to S3 every ~30s. This
  requires the **task role** to have `s3:PutObject` on that prefix.
- Otherwise use ECS Exec to copy from `/pcap` (ECS Exec must be enabled on the
  service).

## Requirements

- `awscli` v2 and `jq`
- AWS credentials with:
  `ecs:DescribeServices`, `ecs:DescribeTaskDefinition`,
  `ecs:RegisterTaskDefinition`, `ecs:UpdateService`,
  `ecs:DeregisterTaskDefinition`, `iam:PassRole`
- For S3 export: `s3:PutObject` on the task role for the target prefix

## Caveats

- **Fargate only.** Captures the task's own ENI (both directions as the task
  sees them). It does not see other tasks or a pre-NAT view.
- **Applying or removing the sidecar recycles the task**, briefly dropping live
  connections.
- This change is out-of-band; the next IaC deploy of the service will revert it.
- The sidecar pulls its image from a registry and (with S3 export) needs network
  egress. On locked-down networks, mirror the image to a reachable registry.

The defaults target an example ECS proxy service; override `CLUSTER`/`SERVICE`
(and the AWS profile/region) for your own environment.
