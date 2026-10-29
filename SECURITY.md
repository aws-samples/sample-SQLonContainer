# Security

This document describes the security model of **SQLonContainer** — running
Microsoft SQL Server 2022 as a StatefulSet on Amazon EKS with credentials in
AWS Secrets Manager. It covers the controls the Helm chart and setup script
ship with, the split of responsibilities between the chart and the operator,
and the additional hardening required before running it against production
workloads.

It is a companion to the deployment guide in [`README.md`](README.md).

---

## Reporting a vulnerability

If you discover a security issue in this project, do **not** open a public
issue with exploit details. Report it privately and include:

- affected component (Helm template, `aws-setup.sh`, `values.yaml`),
- reproduction steps and impact,
- chart version (see [`sql-server-k8s/helm/mssql/Chart.yaml`](sql-server-k8s/helm/mssql/Chart.yaml)).

Report suspected security issues privately via
[AWS Vulnerability Reporting](https://aws.amazon.com/security/vulnerability-reporting/)
(aws-security@amazon.com), or open a private advisory through this repository's
security advisories. Do **not** open a public issue with exploit details.

---

## Security model

The chart provides secure **defaults**; the operator owns the surrounding
environment (VPC, cluster, IAM account posture, and credential lifecycle).

### Secrets management

- The SQL Server `sa` password is stored in **AWS Secrets Manager** and mounted
  into the pod at runtime through the **Secrets Store CSI Driver + AWS provider
  (ASCP)** via the `SecretProviderClass`
  ([`secretproviderclass.yaml`](sql-server-k8s/helm/mssql/templates/secretproviderclass.yaml)).
- The password is **never** placed in the Helm values, the StatefulSet manifest,
  a Kubernetes `Secret`, environment variables baked into an image, or the repo.
  The container reads it from the mounted file (`/mnt/secrets/password`) at
  startup ([`statefulset.yaml`](sql-server-k8s/helm/mssql/templates/statefulset.yaml)).
- The secret is **created manually** by the operator before deployment; the
  chart and `aws-setup.sh` only **reference and verify** it — they do not create
  or prompt for the password.

### Identity and access (IRSA)

- The pod authenticates to AWS through **IRSA** (IAM Roles for Service Accounts)
  bound to the `mssql-sa` service account — no static AWS keys are used.
- The IAM policy created by
  [`aws-setup.sh`](sql-server-k8s/aws-setup.sh) is **least-privilege**: it grants
  only `secretsmanager:GetSecretValue` and `secretsmanager:DescribeSecret`,
  scoped by resource ARN to `secret:mssql/*` — not to every secret in the
  account.
- The trust policy is scoped to the specific OIDC subject
  (`system:serviceaccount:mssql:mssql-sa`) and audience (`sts.amazonaws.com`).

### Container hardening

- Containers run **non-root**: `runAsNonRoot: true` with UID/GID `10001` and
  `fsGroup: 10001`.
- **`allowPrivilegeEscalation: false`** is set on the container security context,
  preventing the process from gaining more privileges than its parent.

### Data at rest

- The `mssql-storage` StorageClass provisions **encrypted gp3 Amazon EBS**
  volumes (`encrypted: "true"`) for the data, log, and backup PersistentVolumes
  ([`storageclass.yaml`](sql-server-k8s/helm/mssql/templates/storageclass.yaml)).
- The StorageClass uses **`reclaimPolicy: Retain`**, so the underlying EBS
  volumes (and the data on them) are preserved if a PersistentVolumeClaim is
  deleted, guarding against accidental data loss.

### Data in transit

- SQL Server is configured to **force encryption** and require **TLS 1.2**
  (`forceencryption = 1`, `tlsprotocols = 1.2`) via the `mssql.conf` ConfigMap
  ([`configmap.yaml`](sql-server-k8s/helm/mssql/templates/configmap.yaml)), so
  client connections are encrypted.
- Pod egress to the AWS Secrets Manager API uses HTTPS (port 443).

### Network posture

- A **NetworkPolicy**
  ([`networkpolicy.yaml`](sql-server-k8s/helm/mssql/templates/networkpolicy.yaml))
  restricts inbound access to port 1433 to (1) namespaces labeled
  `access-mssql=true` and (2) the CIDR ranges in
  `networkPolicy.healthCheckCidrs`. It does **not** allow `0.0.0.0/0` inbound.
  Egress is limited to DNS (53) and HTTPS (443).
- The external NLB Service defaults to **`scheme: internal`** (VPC-only). Public
  exposure (`internet-facing`) is an explicit opt-in.

### Availability and resource controls

- A **PodDisruptionBudget** (`minAvailable: 1`) protects the pod from voluntary
  disruptions during node drains/upgrades.
- **Resource requests and limits** (CPU/memory) are set on the container to
  bound its footprint and support predictable scheduling.
- **`podAntiAffinity`** encourages the SQL Server pod to be scheduled away from
  other replicas of the same workload for resilience.

### Static analysis

- **SAST scanners** (Checkov, cfn-nag, Semgrep, Bandit) report **no findings**
  against the manifests and chart as shipped.
- **Secret-scanner** keyword matches on the secret *name* (for example
  `mssql/sa-password`) were reviewed and confirmed as **false positives** — no
  secret material is stored in the repo (see Secrets management above).

---

## Shared responsibility

| Provided by the chart / setup script | Owned by the operator |
|---|---|
| Secret referenced from Secrets Manager via CSI (never in manifests) | Creating the secret, choosing a strong `sa` password, rotating it |
| Least-privilege IRSA (`GetSecretValue`/`DescribeSecret` on `mssql/*`) | The EKS cluster, OIDC provider, and account-level IAM posture |
| Non-root containers, no privilege escalation | Node/AMI patching and cluster upgrades |
| Encrypted gp3 EBS, `reclaimPolicy: Retain` | Backup strategy and disaster recovery |
| Forced TLS 1.2 for SQL Server | Client-side certificate trust/validation |
| NetworkPolicy, internal-by-default NLB | Scoping `healthCheckCidrs` and NLB/node **security groups** to trusted ranges |
| PDB, resource limits, podAntiAffinity | Right-sizing resources for the workload |

---

## Production hardening checklist

The shipped defaults are safe for evaluation and internal use. Before running a
**production** workload, apply the extra measures below.

### Access and credentials
- [ ] Enable **automatic rotation** on the Secrets Manager secret.
- [ ] Attach an **IAM permissions boundary** to the IRSA role to cap its maximum privilege.
- [ ] Require **MFA** for the human identities that manage the secret and deploy the chart.

### Network
- [ ] Keep the NLB **`scheme: internal`**; only use `internet-facing` with a hardened perimeter.
- [ ] Scope `networkPolicy.healthCheckCidrs` to your VPC/NLB subnet CIDRs or a `/32` client IP — **never `0.0.0.0/0`**.
- [ ] Scope the NLB/node **security groups** to the same trusted ranges at the AWS layer.
- [ ] Reach AWS Secrets Manager over a **VPC interface endpoint (PrivateLink)** and tighten the egress rule from `0.0.0.0/0:443` to the endpoint.

### Encryption
- [ ] Use a **customer-managed KMS key (CMK)** for the EBS volumes instead of the account default key, for auditable/revocable encryption.
- [ ] Enforce strict client-side TLS validation when connecting to SQL Server.

### Operations
- [ ] Keep the SQL Server image and node OS **patched**; rebuild on a schedule.
- [ ] Verify a tested **backup/restore** path for the retained EBS volumes.
- [ ] Enable **CloudTrail** and monitor Secrets Manager `GetSecretValue` volume and IAM changes.

---

## Known limitations and non-goals


- The NetworkPolicy only enforces anything if the cluster's CNI supports network
  policy (for example the Amazon VPC CNI with network policy enabled, or Calico).
- Microsoft SQL Server is licensed separately by Microsoft; the operator is
  responsible for a valid license for the deployed edition (`mssql.pid`).
- The project protects **credentials, data at rest/in transit, and pod
  posture**; it does not, by itself, provide account-level controls (SCPs,
  GuardDuty, Config, CloudTrail) — those belong to the surrounding AWS account.
