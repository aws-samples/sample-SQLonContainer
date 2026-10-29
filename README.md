# SQLonContainer

Run **Microsoft SQL Server 2022** as a containerized, stateful workload on **Amazon EKS**, deployed with **Helm**.

The SQL Server `sa` credentials are stored in **AWS Secrets Manager** and mounted into the pod at runtime via the **Secrets Store CSI Driver + AWS provider (ASCP)** using IRSA (**AWS Identity and Access Management (IAM)** Roles for Service Accounts). No password is ever stored in this repo — you create the secret manually, and the deployment only references it by name.

## Repository layout

```
.
├── k8-resource/
│   └── cluster.yaml            # eksctl cluster definition (create the EKS cluster)
└── sql-server-k8s/
    ├── aws-setup.sh            # One-shot AWS/EKS prerequisite setup (CSI, IRSA, LB controller)
    └── helm/mssql/             # Helm chart for SQL Server 2022 (StatefulSet, Service, etc.)
```

## What gets deployed

| Component | Purpose |
|-----------|---------|
| Amazon EKS cluster | Kubernetes control plane + managed nodes (`k8-resource/cluster.yaml`) |
| Amazon EBS CSI Driver | Dynamic `gp3` volume provisioning for data/log/backup |
| AWS Secrets Manager | Stores the SA credentials (`username` + `password`) |
| IAM (IRSA) | Lets the pod read the secret without static AWS keys |
| Secrets Store CSI Driver + ASCP | Mounts the secret into the pod at `/mnt/secrets` |
| AWS Load Balancer Controller | Provisions the NLB for external access |
| SQL Server 2022 StatefulSet | The database workload itself |

## Prerequisites

Install these locally and configure AWS credentials (`aws configure` or SSO):

- `aws` CLI v2
- `eksctl`
- `kubectl`
- `helm` v3

## Before you deploy: update values for your environment

This repo ships with example values. **Before deploying, review and update these to match
your own AWS account, cluster, and network** in `sql-server-k8s/helm/mssql/values.yaml`
(and `k8-resource/cluster.yaml`):

| Setting | File | Change to |
|---------|------|-----------|
| `networkPolicy.healthCheckCidrs` | `values.yaml` | **Your** VPC/NLB subnet CIDR(s) and/or your client IP as `/32`. Replace the `10.0.0.0/16` example. **Never `0.0.0.0/0`.** |
| `aws.region` | `values.yaml` | Your region (default `us-east-1`) |
| `aws.accountId` | `values.yaml` | Your 12-digit account ID — replace the `123456789012` placeholder |
| Account ID in ARNs | `values.yaml`, `aws-setup.sh`, this `README.md` | Replace every `123456789012` with your own account ID |
| `aws.secretName` | `values.yaml` | Name of the secret you create in Secrets Manager |
| `aws.irsaRoleArn` | `values.yaml` | ARN of the IRSA role you create |
| `metadata.name` / `region` | `k8-resource/cluster.yaml` | Your cluster name and region |

> **CIDR is the most important one to get right.** The value(s) in
> `networkPolicy.healthCheckCidrs` become the inbound `ipBlock` rules for port 1433. Set
> them to the ranges you actually want to allow (your VPC CIDR and/or your `/32` client IP).
> Find your public IP with `curl -s ifconfig.me`, and your VPC CIDR with
> `aws ec2 describe-vpcs --query 'Vpcs[].CidrBlock' --output text`.

> **Account ID:** `123456789012` is a placeholder used throughout the repo. Replace it with
> your own 12-digit AWS account ID everywhere it appears (`values.yaml`, `aws-setup.sh`, and
> this `README.md`). Find yours with `aws sts get-caller-identity --query Account --output text`.

## Quick start

### 1. Install Helm

If you don't already have Helm, install it with the official script:

```bash
# Stable Helm 3 (recommended):
curl -fsSL -o get_helm.sh https://raw.githubusercontent.com/helm/helm/main/scripts/get-helm-3
chmod 700 get_helm.sh
./get_helm.sh

# Verify
helm version
```

> To track the newer Helm 4 line instead, use `get-helm-4` in the URL. This chart works with
> either. On macOS you can also `brew install helm`.

### 2. Create the EKS cluster

```bash
eksctl create cluster -f k8-resource/cluster.yaml
```

This creates the `eksclusql` cluster in `us-east-1` (edit `k8-resource/cluster.yaml` to change the name, region, or node instance types).

### 3. Create the SA credentials secret manually (one-time)

The repo never creates or prompts for the password — you create the secret yourself, and the chart references it by name. Use a strong password that meets SQL Server's policy (8+ chars with at least three of: uppercase, lowercase, digits, symbols).

```bash
aws secretsmanager create-secret \
  --name mssql/sa-password \
  --secret-string '{"username":"sa","password":"<YOUR-SA-PASSWORD>"}' \
  --region us-east-1
```

The secret value must be JSON with both a `username` and a `password` key. The secret **name** must match `aws.secretName` in `sql-server-k8s/helm/mssql/values.yaml` (default: `mssql/sa-password`).

### 4. Run the AWS/EKS setup script

```bash
cd sql-server-k8s
chmod +x aws-setup.sh
./aws-setup.sh
```

This installs the EBS CSI driver, Secrets Store CSI driver + ASCP, creates the IRSA role/service account, the AWS Load Balancer Controller, and **verifies** the secret from step 3 exists (it does not create it).

### 5. Deploy SQL Server with Helm

Run from inside `sql-server-k8s`:

```bash
helm install mssql ./helm/mssql -n mssql --create-namespace \
  --set resources.requests.cpu=500m \
  --set resources.limits.cpu=2 \
  --set storage.create=true

kubectl get pods -n mssql -w
```

- `--create-namespace` creates the `mssql` namespace if it doesn't exist (safe no-op if it does).
- `resources.requests.cpu` / `resources.limits.cpu` override the chart defaults (4 vCPU) — tune to your node size.
- `storage.create=true` creates the `mssql-storage` StorageClass on the **first** deploy. On later deploys where it already exists, use `storage.create=false` to avoid a conflict.

### 6. Connect

```bash
# Get the NLB DNS name
kubectl get svc mssql-mssql -n mssql \
  -o jsonpath='{.status.loadBalancer.ingress[0].hostname}'

# Connect as sa (password comes from the secret you created)
sqlcmd -S <nlb-dns>,1433 -U sa
```

## IRSA role (manual alternative)

`aws-setup.sh` creates the IRSA role for you. If you prefer to create it by hand, do this
before running the setup script (replace `123456789012` with your account ID and
`eksclusql`/`us-east-1` with your cluster/region):

```bash
OIDC_ID=$(aws eks describe-cluster --name eksclusql --region us-east-1 \
  --query "cluster.identity.oidc.issuer" --output text | sed 's|.*/||')

# Policy: allow reading the mssql/* secrets
cat > /tmp/mssql-secrets-policy.json << 'EOF'
{
  "Version": "2012-10-17",
  "Statement": [{
    "Effect": "Allow",
    "Action": ["secretsmanager:GetSecretValue", "secretsmanager:DescribeSecret"],
    "Resource": "arn:aws:secretsmanager:us-east-1:123456789012:secret:mssql/*"
  }]
}
EOF
aws iam create-policy --policy-name mssql-secrets-policy \
  --policy-document file:///tmp/mssql-secrets-policy.json

# Role with OIDC trust scoped to the mssql-sa service account
cat > /tmp/trust-policy.json << EOF
{
  "Version": "2012-10-17",
  "Statement": [{
    "Effect": "Allow",
    "Principal": {
      "Federated": "arn:aws:iam::123456789012:oidc-provider/oidc.eks.us-east-1.amazonaws.com/id/${OIDC_ID}"
    },
    "Action": "sts:AssumeRoleWithWebIdentity",
    "Condition": {
      "StringEquals": {
        "oidc.eks.us-east-1.amazonaws.com/id/${OIDC_ID}:sub": "system:serviceaccount:mssql:mssql-sa",
        "oidc.eks.us-east-1.amazonaws.com/id/${OIDC_ID}:aud": "sts.amazonaws.com"
      }
    }
  }]
}
EOF
aws iam create-role --role-name mssql-secrets-role \
  --assume-role-policy-document file:///tmp/trust-policy.json
aws iam attach-role-policy --role-name mssql-secrets-role \
  --policy-arn arn:aws:iam::123456789012:policy/mssql-secrets-policy
```

The resulting role ARN must match `aws.irsaRoleArn` in `sql-server-k8s/helm/mssql/values.yaml`.

## Troubleshooting

| Symptom | Cause | Fix |
|---------|-------|-----|
| `fetch-secrets` AccessDenied | IRSA role missing/misconfigured | Recreate the IRSA role, then `kubectl delete pod mssql-mssql-0 -n mssql` |
| Secret not found on `aws-setup.sh` | Secret not created yet | Create it (step 3), then re-run the script |
| Pod ContainerCreating + volume error | Secrets Store CSI driver not installed | Re-run `aws-setup.sh` (installs the CSI driver + ASCP) |
| PVC Pending | EBS CSI driver missing | Ensure the EBS CSI addon is installed (done by `aws-setup.sh`) |
| Pod Pending (no nodes) | Toleration/taint mismatch | `kubectl taint nodes <node> database=mssql:NoSchedule` or remove the toleration in `values.yaml` |
| No NLB DNS on the service | AWS Load Balancer Controller missing | Ensure the controller is installed (done by `aws-setup.sh`) |

## Configuration

Deployment settings live in `sql-server-k8s/helm/mssql/values.yaml` — region, secret name, IRSA role ARN, resources, storage sizes, network policy CIDRs, and SQL Server `mssql.conf` options. Override any value at deploy time with `--set key=value`.

## Network access

Inbound access to SQL Server (port 1433) is controlled by the Kubernetes NetworkPolicy
(`networkPolicy.enabled: true` by default). It only allows:

1. Pods in namespaces labeled `access-mssql=true`, and
2. The CIDR ranges you list in `networkPolicy.healthCheckCidrs`.

**You must add your own IP or CIDR** to `networkPolicy.healthCheckCidrs` in
`sql-server-k8s/helm/mssql/values.yaml` so your client (and the NLB health checks) can
reach port 1433. Use your VPC/NLB subnet CIDR block, or your client's IP as a `/32` —
**never `0.0.0.0/0`**.

```yaml
# sql-server-k8s/helm/mssql/values.yaml
networkPolicy:
  enabled: true
  healthCheckCidrs:
    - 10.0.0.0/16        # your VPC CIDR (example)
    - 203.0.113.25/32    # your client IP, e.g. `curl -s ifconfig.me`
```

Or override at deploy time:

```bash
helm install mssql ./helm/mssql -n mssql --create-namespace \
  --set 'networkPolicy.healthCheckCidrs={10.0.0.0/16,203.0.113.25/32}'
```

> This NetworkPolicy governs traffic **inside the cluster**. Inbound access at the AWS
> layer is also controlled by the NLB/node **security groups**, which you should scope to
> the same trusted ranges.

## Security notes

- The SA password is never committed, prompted for by the code, or stored in the repo. It lives only in AWS Secrets Manager.
- Access to the secret is granted via IRSA scoped to the `mssql-sa` service account.
- The NetworkPolicy restricts access to port 1433 to the namespaces and CIDRs you allow — set `networkPolicy.healthCheckCidrs` to your own IP/CIDR, never `0.0.0.0/0`.

## Disclaimer

This repository is provided as a **sample / reference implementation** to demonstrate
running SQL Server 2022 on Amazon EKS. It is **not intended for production use** as-is and
is provided **"as is" without warranty of any kind**, express or implied.

- **Review and test** everything before using it in any real environment. You are
  responsible for validating it against your own requirements.
- **Security is your responsibility.** Scope the NetworkPolicy CIDRs and NLB/node security
  groups to trusted ranges, apply IAM least-privilege, and manage secrets and encryption
  per your organization's standards. Do not use `0.0.0.0/0`.
- **You are responsible for AWS costs.** Deploying EKS, EBS volumes, an NLB, and Secrets
  Manager will incur charges in your account.
- **SQL Server licensing:** Microsoft SQL Server is licensed separately by Microsoft. You
  are responsible for holding a valid license for the edition you deploy (set via
  `mssql.pid` in `values.yaml`).
