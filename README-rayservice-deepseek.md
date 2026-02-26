# DeepSeek Model Deployment on Kubernetes with KubeRay

This repository contains configuration files for deploying a DeepSeek LLM model on Kubernetes using the KubeRay operator with 16 NVIDIA H100 GPUs (8 GPUs per worker node across 2 nodes).

## Prerequisites

1. **Kubernetes cluster** with:
   - KubeRay operator installed
   - At least 2 worker nodes with 8x NVIDIA H100 GPUs each
   - NVIDIA GPU operator or device plugin installed
   - Storage provisioner for persistent volumes (optional)

2. **HuggingFace Access Token**:
   - Create an account at https://huggingface.co
   - Generate an access token at https://huggingface.co/settings/tokens
   - Ensure you have accepted the DeepSeek model license

3. **kubectl** configured to access your cluster

## Files

- `rayservice-deepseek.yaml` - RayService manifest with GPU configuration
- `deployment.py` - Ray Serve deployment script using vLLM
- `README-rayservice-deepseek.md` - This file

## Configuration Steps

### 1. Update HuggingFace Token

Replace `YOUR_HUGGINGFACE_TOKEN_HERE` in the Secret section of `rayservice-deepseek.yaml`:

```bash
# Option 1: Edit the YAML file directly
sed -i "s/YOUR_HUGGINGFACE_TOKEN_HERE/hf_YOUR_ACTUAL_TOKEN/" rayservice-deepseek.yaml

# Option 2: Create the secret separately
kubectl create secret generic huggingface-secret \
  --from-literal=token=hf_YOUR_ACTUAL_TOKEN \
  -n default
```

### 2. Choose Your DeepSeek Model

Edit the `serveConfigV2` section in `rayservice-deepseek.yaml` to select your model:

Available models:
- `deepseek-ai/deepseek-coder-33b-instruct` (default, coding-focused)
- `deepseek-ai/deepseek-llm-67b-chat` (general chat)
- `deepseek-ai/DeepSeek-V2` (latest, requires more resources)
- `deepseek-ai/DeepSeek-V3` (if available)

### 3. Adjust GPU Node Affinity (if needed)

Update the node affinity section in the worker spec to match your H100 GPU product name:

```yaml
nodeAffinity:
  requiredDuringSchedulingIgnoredDuringExecution:
    nodeSelectorTerms:
    - matchExpressions:
      - key: nvidia.com/gpu.product
        operator: In
        values:
        - NVIDIA-H100-80GB-HBM3  # Update to match your GPU model
```

To find your GPU product name:
```bash
kubectl get nodes -o json | jq '.items[].status.allocatable | keys[] | select(. | startswith("nvidia"))'
kubectl describe node <node-name> | grep -i gpu
```

## Deployment

### 1. Create a ConfigMap for the Deployment Script

```bash
kubectl create configmap deepseek-deployment \
  --from-file=deployment.py \
  -n default
```

Alternatively, build the deployment script into a custom Docker image or use Ray's working_dir feature.

### 2. Deploy the RayService

```bash
kubectl apply -f rayservice-deepseek.yaml
```

### 3. Monitor Deployment

```bash
# Check RayService status
kubectl get rayservice deepseek-rayservice -n default

# Check pods
kubectl get pods -n default -l ray.io/cluster=deepseek-rayservice

# View logs from head node
kubectl logs -f -n default -l ray.io/node-type=head

# View Ray dashboard
kubectl port-forward -n default svc/deepseek-serve 8265:8265
# Open http://localhost:8265
```

### 4. Verify GPU Allocation

```bash
# Check GPU allocation on worker pods
kubectl exec -it <worker-pod-name> -n default -- nvidia-smi

# Verify Ray can see the GPUs
kubectl exec -it <head-pod-name> -n default -- python -c "import ray; ray.init(); print(ray.available_resources())"
```

## Usage

### Access the Model API

```bash
# Port forward the serve endpoint
kubectl port-forward -n default svc/deepseek-serve 8000:8000
```

### Send Inference Requests

```bash
# Using curl
curl -X POST http://localhost:8000/ \
  -H "Content-Type: application/json" \
  -d '{
    "prompt": "Write a Python function to calculate fibonacci numbers",
    "max_tokens": 512,
    "temperature": 0.7,
    "top_p": 0.9
  }'
```

```python
# Using Python
import requests

response = requests.post(
    "http://localhost:8000/",
    json={
        "prompt": "Explain how transformers work in deep learning",
        "max_tokens": 1024,
        "temperature": 0.7,
        "top_p": 0.95
    }
)

print(response.json()["generated_text"])
```

### OpenAI-Compatible API (Optional)

To use an OpenAI-compatible API, modify `deployment.py` to use vLLM's OpenAI server:

```python
from vllm.entrypoints.openai.api_server import run_server
```

Or deploy vLLM directly:
```bash
kubectl exec -it <head-pod-name> -- \
  python -m vllm.entrypoints.openai.api_server \
  --model deepseek-ai/deepseek-coder-33b-instruct \
  --tensor-parallel-size 8 \
  --host 0.0.0.0 \
  --port 8000
```

## Scaling and Performance Tuning

### Tensor Parallelism

The configuration uses `tensor_parallel_size: 8` to distribute the model across 8 GPUs on a single worker. For the second worker:

- Increase `num_replicas` in the serve config to use both workers
- Each replica will use 8 GPUs
- Total: 2 replicas × 8 GPUs = 16 GPUs

### Memory Optimization

Adjust in `deployment.py`:
```python
gpu_memory_utilization: 0.95  # Increase if you have memory issues
max_model_len: 4096          # Reduce for longer sequences
```

### Batch Size

Modify vLLM settings for throughput:
```python
self.llm = LLM(
    model=model,
    max_num_batched_tokens=8192,  # Adjust based on GPU memory
    max_num_seqs=256,             # Maximum batch size
    ...
)
```

## Troubleshooting

### Pods Not Scheduling

```bash
# Check node resources
kubectl describe nodes | grep -A 5 "Allocated resources"

# Check GPU availability
kubectl get nodes -o custom-columns=NAME:.metadata.name,GPUs:.status.allocatable."nvidia\.com/gpu"

# Check pod events
kubectl describe pod <pod-name> -n default
```

### Out of Memory Errors

- Reduce `gpu_memory_utilization` to 0.85 or 0.9
- Decrease `max_model_len`
- Reduce `max_num_batched_tokens`
- Check if the model fits on 8 H100s (67B models typically need ~134GB)

### Model Download Issues

```bash
# Check if HF_TOKEN is set correctly
kubectl exec -it <pod-name> -- env | grep HF_TOKEN

# Manually test HuggingFace access
kubectl exec -it <pod-name> -- python3 -c "from huggingface_hub import login; login(token='YOUR_TOKEN')"
```

### Worker Pods on Same Node

If topology spread isn't working:
```bash
# Check node labels
kubectl get nodes --show-labels

# Manually add node affinity
kubectl label nodes <node-1> gpu-zone=zone-1
kubectl label nodes <node-2> gpu-zone=zone-2
```

Then update the worker spec to use the label.

## Cleanup

```bash
# Delete the RayService
kubectl delete -f rayservice-deepseek.yaml

# Delete the secret
kubectl delete secret huggingface-secret -n default

# Delete the configmap (if created)
kubectl delete configmap deepseek-deployment -n default
```

## Advanced Configuration

### Using Multiple Worker Groups

For heterogeneous GPU setups or different model configurations:

```yaml
workerGroupSpecs:
- groupName: gpu-workers-a100
  replicas: 2
  rayStartParams:
    num-gpus: '8'
  template:
    spec:
      containers:
      - name: ray-worker
        resources:
          limits:
            nvidia.com/gpu: "8"
      affinity:
        nodeAffinity:
          requiredDuringSchedulingIgnoredDuringExecution:
            nodeSelectorTerms:
            - matchExpressions:
              - key: nvidia.com/gpu.product
                operator: In
                values:
                - NVIDIA-A100-SXM4-80GB
```

### Persistent Model Caching

To avoid re-downloading the model on pod restarts:

```yaml
volumes:
- name: hf-cache
  persistentVolumeClaim:
    claimName: huggingface-cache-pvc
```

Create PVC:
```bash
kubectl apply -f - <<EOF
apiVersion: v1
kind: PersistentVolumeClaim
metadata:
  name: huggingface-cache-pvc
  namespace: default
spec:
  accessModes:
  - ReadWriteMany
  resources:
    requests:
      storage: 500Gi
  storageClassName: your-storage-class
EOF
```

## Monitoring

### Prometheus Metrics

Ray exposes metrics at `http://<head-node>:8265/metrics`

```bash
kubectl port-forward -n default svc/deepseek-serve 8265:8265
curl http://localhost:8265/metrics
```

### GPU Metrics

Use NVIDIA DCGM exporter for GPU metrics:
```bash
helm install dcgm-exporter nvidia/dcgm-exporter --namespace gpu-operator
```

## References

- [KubeRay Documentation](https://docs.ray.io/en/latest/cluster/kubernetes/index.html)
- [vLLM Documentation](https://docs.vllm.ai/)
- [DeepSeek Models](https://huggingface.co/deepseek-ai)
- [Ray Serve Documentation](https://docs.ray.io/en/latest/serve/index.html)
