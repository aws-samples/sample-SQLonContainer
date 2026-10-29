#!/bin/bash
# AWS Setup for SQL Server on EKS - Secrets Store CSI Driver + ASCP + IRSA
# References:
#   https://docs.aws.amazon.com/secretsmanager/latest/userguide/integrating_ascp_irsa.html
#   https://secrets-store-csi-driver.sigs.k8s.io/
#
# Prerequisites: EKS cluster, kubectl, helm, eksctl, aws cli

CLUSTER_NAME="eksclusql"
REGION="us-east-1"
ACCOUNT_ID="123456789012"
NAMESPACE="mssql"
SA_NAME="mssql-sa"
SECRET_NAME="mssql/sa-password"
POLICY_NAME="mssql-secrets-policy"
POLICY_ARN="arn:aws:iam::${ACCOUNT_ID}:policy/${POLICY_NAME}"

set -e

echo "=== Step 1: Associate OIDC provider ==="
eksctl utils associate-iam-oidc-provider \
  --cluster $CLUSTER_NAME \
  --region $REGION \
  --approve

echo ""
echo "=== Step 2: Install EBS CSI Driver ==="
eksctl create addon --name aws-ebs-csi-driver \
  --cluster $CLUSTER_NAME --region $REGION 2>/dev/null || echo "EBS CSI driver already installed"

echo ""
echo "=== Step 3: Install Secrets Store CSI Driver ==="
helm repo add secrets-store-csi-driver \
  https://kubernetes-sigs.github.io/secrets-store-csi-driver/charts 2>/dev/null || true
helm repo update

# tokenRequests is required for IRSA to work with CSI driver
helm upgrade --install csi-secrets-store \
  secrets-store-csi-driver/secrets-store-csi-driver \
  -n kube-system \
  --set syncSecret.enabled=true \
  --set "tokenRequests[0].audience=sts.amazonaws.com"

echo ""
echo "=== Step 4: Install AWS Secrets Provider (ASCP) ==="
# Use kubectl apply to avoid Helm ServiceAccount ownership conflict
kubectl apply -f https://raw.githubusercontent.com/aws/secrets-store-csi-driver-provider-aws/main/deployment/aws-provider-installer.yaml

echo "Waiting 20s for pods..."
sleep 20
echo "CSI Driver pods:"
kubectl get pods -n kube-system -l app=secrets-store-csi-driver --no-headers
echo "ASCP pods:"
kubectl get pods -n kube-system -l app=csi-secrets-store-provider-aws --no-headers

echo ""
echo "=== Step 5: Verify pre-created secret in AWS Secrets Manager ==="
# The SA credentials secret must be created MANUALLY before running this script,
# so that no password is ever passed through or stored in this repo. Create it once with:
#
#   aws secretsmanager create-secret \
#     --name mssql/sa-password \
#     --secret-string '{"username":"sa","password":"<YOUR-SA-PASSWORD>"}' \
#     --region us-east-1
#
# This script only verifies that the secret already exists and is readable.
if ! aws secretsmanager describe-secret --secret-id "$SECRET_NAME" --region "$REGION" >/dev/null 2>&1; then
  echo "ERROR: Secret '$SECRET_NAME' not found in region '$REGION'."
  echo "Create it manually first (see the command above / README Step 4), then re-run this script."
  exit 1
fi
echo "Found existing secret '$SECRET_NAME'. Referencing it."

echo ""
echo "=== Step 6: Create IAM policy ==="
cat > /tmp/mssql-secrets-policy.json << EOF
{
  "Version": "2012-10-17",
  "Statement": [{
    "Effect": "Allow",
    "Action": [
      "secretsmanager:GetSecretValue",
      "secretsmanager:DescribeSecret"
    ],
    "Resource": "arn:aws:secretsmanager:${REGION}:${ACCOUNT_ID}:secret:mssql/*"
  }]
}
EOF

aws iam create-policy \
  --policy-name $POLICY_NAME \
  --policy-document file:///tmp/mssql-secrets-policy.json 2>/dev/null || echo "Policy already exists"

echo ""
echo "=== Step 7: Create namespace ==="
kubectl create namespace $NAMESPACE 2>/dev/null || echo "Namespace already exists"

echo ""
echo "=== Step 8: Create IRSA Service Account ==="
# eksctl handles: IAM role + trust policy + K8s SA annotation
# If eksctl says "excluded", it means the CloudFormation stack exists
# but the K8s SA may not. We handle that below.
eksctl create iamserviceaccount \
  --name $SA_NAME \
  --namespace $NAMESPACE \
  --cluster $CLUSTER_NAME \
  --region $REGION \
  --attach-policy-arn $POLICY_ARN \
  --approve \
  --override-existing-serviceaccounts 2>/dev/null || true

# If SA doesn't exist (eksctl excluded it), create manually
if ! kubectl get sa $SA_NAME -n $NAMESPACE &>/dev/null; then
  echo "SA not found, creating manually..."
  ROLE_ARN=$(aws cloudformation describe-stacks \
    --stack-name eksctl-${CLUSTER_NAME}-addon-iamserviceaccount-${NAMESPACE}-${SA_NAME} \
    --query "Stacks[0].Outputs[?OutputKey=='Role1'].OutputValue" \
    --output text --region $REGION 2>/dev/null)

  if [ -z "$ROLE_ARN" ] || [ "$ROLE_ARN" == "None" ]; then
    echo "ERROR: Could not find IAM role. Delete the eksctl stack and re-run:"
    echo "  aws cloudformation delete-stack --stack-name eksctl-${CLUSTER_NAME}-addon-iamserviceaccount-${NAMESPACE}-${SA_NAME}"
    echo "  Then re-run this script."
    exit 1
  fi

  kubectl create serviceaccount $SA_NAME -n $NAMESPACE
  kubectl annotate serviceaccount $SA_NAME -n $NAMESPACE \
    eks.amazonaws.com/role-arn=$ROLE_ARN
fi

echo ""
echo "=== Step 9: Verify ==="
echo "ServiceAccount:"
kubectl get sa $SA_NAME -n $NAMESPACE -o jsonpath='{.metadata.annotations}' && echo ""

echo ""
echo "=== Setup complete ==="
echo ""
echo "Deploy:"
echo "  helm install mssql ./helm/mssql -n mssql \\"
echo "    --set resources.requests.cpu=500m \\"
echo "    --set resources.limits.cpu=2 \\"
echo "    --set storage.create=false"
echo ""
echo "  (use storage.create=true on first deploy if StorageClass doesn't exist)"
echo ""
echo "Verify:"
echo "  kubectl get pods -n mssql -w"
echo "  kubectl describe pod mssql-mssql-0 -n mssql"
echo "  kubectl logs mssql-mssql-0 -n mssql --tail=20"

echo ""
echo "=== Step 10: Install AWS Load Balancer Controller ==="

# Download IAM policy
echo "Downloading IAM policy for AWS Load Balancer Controller..."
curl -O https://raw.githubusercontent.com/kubernetes-sigs/aws-load-balancer-controller/main/docs/install/iam_policy.json

# Create IAM policy
echo "Creating IAM policy..."
aws iam create-policy \
  --policy-name AWSLoadBalancerControllerIAMPolicy \
  --policy-document file://iam_policy.json \
  --region $REGION 2>/dev/null || echo "AWSLoadBalancerControllerIAMPolicy already exists"

# Create IRSA service account for the controller
echo "Creating IRSA service account for AWS Load Balancer Controller..."
eksctl create iamserviceaccount \
  --cluster $CLUSTER_NAME \
  --namespace kube-system \
  --name aws-load-balancer-controller \
  --attach-policy-arn arn:aws:iam::${ACCOUNT_ID}:policy/AWSLoadBalancerControllerIAMPolicy \
  --approve \
  --region $REGION \
  --override-existing-serviceaccounts 2>/dev/null || true

# Install the controller via Helm
echo "Installing AWS Load Balancer Controller via Helm..."
helm repo add eks https://aws.github.io/eks-charts 2>/dev/null || true
helm repo update

helm install aws-load-balancer-controller eks/aws-load-balancer-controller \
  -n kube-system \
  --set clusterName=$CLUSTER_NAME \
  --set serviceAccount.create=false \
  --set serviceAccount.name=aws-load-balancer-controller

echo "Waiting 15s for controller pods..."
sleep 15
echo "AWS Load Balancer Controller pods:"
kubectl get pods -n kube-system -l app.kubernetes.io/name=aws-load-balancer-controller --no-headers

# Clean up downloaded policy file
rm -f iam_policy.json

echo ""
echo "=== AWS Load Balancer Controller installation complete ==="
