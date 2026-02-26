#!/bin/bash
# Quick Start Script for DeepSeek RayService Deployment
# Usage: ./quickstart.sh <your-huggingface-token>

set -e

# Colors for output
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
NC='\033[0m' # No Color

# Function to print colored messages
print_info() {
    echo -e "${GREEN}[INFO]${NC} $1"
}

print_warning() {
    echo -e "${YELLOW}[WARNING]${NC} $1"
}

print_error() {
    echo -e "${RED}[ERROR]${NC} $1"
}

# Check if HuggingFace token is provided
if [ -z "$1" ]; then
    print_error "HuggingFace token not provided"
    echo "Usage: $0 <your-huggingface-token>"
    exit 1
fi

HF_TOKEN="$1"
NAMESPACE="default"

print_info "Starting DeepSeek RayService deployment..."

# Step 1: Verify prerequisites
print_info "Checking prerequisites..."

# Check if kubectl is available
if ! command -v kubectl &> /dev/null; then
    print_error "kubectl not found. Please install kubectl first."
    exit 1
fi

# Check if connected to a cluster
if ! kubectl cluster-info &> /dev/null; then
    print_error "Cannot connect to Kubernetes cluster. Please configure kubectl."
    exit 1
fi

print_info "✓ kubectl configured and connected"

# Check if KubeRay operator is installed
if ! kubectl get crd rayclusters.ray.io &> /dev/null; then
    print_error "KubeRay operator not found. Please install it first:"
    echo "  helm repo add kuberay https://ray-project.github.io/kuberay-helm/"
    echo "  helm repo update"
    echo "  helm install kuberay-operator kuberay/kuberay-operator --version 1.0.0"
    exit 1
fi

print_info "✓ KubeRay operator installed"

# Check GPU nodes
GPU_NODES=$(kubectl get nodes -o json | jq -r '.items[] | select(.status.allocatable."nvidia.com/gpu" != null) | .metadata.name' | wc -l)
if [ "$GPU_NODES" -lt 2 ]; then
    print_warning "Only $GPU_NODES GPU node(s) found. This deployment expects 2 nodes with 8 GPUs each."
    read -p "Continue anyway? (y/n) " -n 1 -r
    echo
    if [[ ! $REPLY =~ ^[Yy]$ ]]; then
        exit 1
    fi
else
    print_info "✓ Found $GPU_NODES GPU nodes"
fi

# Step 2: Create HuggingFace secret
print_info "Creating HuggingFace token secret..."

kubectl delete secret huggingface-secret -n $NAMESPACE 2>/dev/null || true
kubectl create secret generic huggingface-secret \
    --from-literal=token="$HF_TOKEN" \
    -n $NAMESPACE

print_info "✓ Secret created"

# Step 3: Deploy RayService
print_info "Deploying RayService..."

# Use the simple version for easier deployment
kubectl apply -f rayservice-deepseek-simple.yaml

print_info "✓ RayService deployed"

# Step 4: Wait for pods to be ready
print_info "Waiting for Ray head pod to be ready..."

kubectl wait --for=condition=ready pod \
    -l ray.io/node-type=head \
    -l ray.io/cluster=deepseek-rayservice-simple \
    -n $NAMESPACE \
    --timeout=300s

print_info "✓ Ray head pod is ready"

print_info "Waiting for Ray worker pods to be ready (this may take 10-15 minutes for model download)..."

kubectl wait --for=condition=ready pod \
    -l ray.io/node-type=worker \
    -l ray.io/cluster=deepseek-rayservice-simple \
    -n $NAMESPACE \
    --timeout=900s

print_info "✓ All Ray worker pods are ready"

# Step 5: Check RayService status
print_info "Checking RayService status..."

kubectl get rayservice deepseek-rayservice-simple -n $NAMESPACE

# Step 6: Display access information
print_info "============================================"
print_info "Deployment Complete!"
print_info "============================================"
echo ""
print_info "To access the Ray Dashboard:"
echo "  kubectl port-forward -n $NAMESPACE svc/deepseek-serve-simple 8265:8265"
echo "  Open http://localhost:8265 in your browser"
echo ""
print_info "To access the Model API:"
echo "  kubectl port-forward -n $NAMESPACE svc/deepseek-serve-simple 8000:8000"
echo ""
print_info "Test the API with:"
echo '  curl -X POST http://localhost:8000/v1/completions \'
echo '    -H "Content-Type: application/json" \'
echo '    -d '"'"'{"model": "deepseek-ai/deepseek-coder-33b-instruct", "prompt": "def fibonacci(n):", "max_tokens": 100}'"'"
echo ""
print_info "View logs:"
echo "  kubectl logs -f -n $NAMESPACE -l ray.io/node-type=head"
echo ""
print_info "Check GPU usage:"
echo "  kubectl exec -it -n $NAMESPACE \$(kubectl get pod -n $NAMESPACE -l ray.io/node-type=worker -o jsonpath='{.items[0].metadata.name}') -- nvidia-smi"
echo ""
print_info "Delete deployment:"
echo "  kubectl delete -f rayservice-deepseek-simple.yaml"
echo "  kubectl delete secret huggingface-secret -n $NAMESPACE"
