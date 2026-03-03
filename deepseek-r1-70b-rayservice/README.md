# DeepSeek R1 (70B) on Kubernetes with KubeRay

This example deploys `deepseek-ai/DeepSeek-R1-Distill-Llama-70B` via Ray Serve's built-in OpenAI-compatible API (`ray.serve.llm`), backed by vLLM with tensor parallelism across 8 GPUs per replica, on a Crusoe Managed Kubernetes cluster with a GPU nodepool. You can adjust the number of nodes, and number of gpus per node, by editing the spec of the ray service in the yaml file. Most Crusoe GPU SKUs have 8 GPUs per node, apart from GB200 which has 4.

**Hardware requirement:** 2 or more worker nodes, each with 8× NVIDIA H100/A100 (80 GB) GPUs. (adjust yaml file accordingly)

---

## Prerequisites

- CMK cluster with GPU nodes (NVIDIA device plugin or GPU Operator installed by selecting appropriate addons at cluster creation time)
- `helm` ≥ 3.x and `kubectl` configured against your cluster. [Instructions for installing Helm](https://helm.sh/docs/intro/install/).
- (not currently required) A [HuggingFace](https://huggingface.co/settings/tokens) token with access to `deepseek-ai/DeepSeek-R1-Distill-Llama-70B`

---

## 1. Install or Upgrade the KubeRay Operator

### CRDs

You need an up-to-date KubeRay version for this example to work - this example is tested with 1.5.1. Helm does not upgrade CRDs automatically when you run `helm upgrade` for KubeRay, so check your current KubeRay operator version with `helm list -A|grep -i kuberay` and if you need to helm upgrade it, then also do the step of upgrading the CRDs. If this is your first installatin of KubeRay then the correct CRDs will automatically be installed.

```bash
kubectl apply --server-side -k \
  "github.com/ray-project/kuberay/ray-operator/config/crd?ref=v1.5.1"
```

This installs/upgrades the three CRDs:
- `rayclusters.ray.io`
- `rayjobs.ray.io`
- `rayservices.ray.io`

### Operator

**Fresh install:**

```bash
helm repo add kuberay https://ray-project.github.io/kuberay-helm/
helm repo update

helm install kuberay-operator kuberay/kuberay-operator \
  --namespace kuberay-system \
  --create-namespace \
  --version 1.5.1
```

**Upgrade an existing installation:**

```bash
helm repo update

helm upgrade kuberay-operator kuberay/kuberay-operator \
  --namespace kuberay-system \
  --version 1.5.1
```

Verify the operator is running:

```bash
kubectl -n kuberay-system get pods
```

---

## 2. Update the HuggingFace Token

At the time of writing, the DeepSeek model is not gated by an HF token so this part doesn't seem to matter, but if you want to try other models, it probably will.  
The manifest (`ray-service.llm-serve.yaml`) contains a `Secret` with a placeholder token. Replace it before applying the yaml, by editing the `stringData.hf_token` field in the yaml file directly.

---

## 3. Deploy the RayService

```bash
kubectl apply -f ray-service.llm-serve.yaml
```

This creates:
- A `RayService` named `ray-serve-llm` in the `default` namespace
- A `RayCluster` (head + 2 GPU worker nodes) managed by KubeRay
- The `hf-token` secret

### Monitor rollout

```bash
# Overall RayService status (wait for READY)
kubectl get rayservice ray-serve-llm -w

# Pods
kubectl get pods -l ray.io/cluster -w

# Head node logs (Ray Serve startup)
kubectl logs -f -l ray.io/node-type=head --container ray-head

# Worker logs (model download + vLLM init)
kubectl logs -f -l ray.io/node-type=worker --container ray-worker
```

Model download is ~140 GB; initial startup takes several minutes. The service is ready when `kubectl get rayservice ray-serve-llm` shows `READY: True`.

---

## 4. Access the API

KubeRay creates two services for `ray-serve-llm`:

| Service | Ports |
|---|---|
| `ray-serve-llm-head-svc` | 8265 (dashboard), 6379 (GCS), 10001 (client) |
| `ray-serve-llm-serve-svc` | 8000 (Serve / OpenAI API) |

### Option A — Port forwarding (quickest for local testing)

```bash
# OpenAI-compatible API
kubectl port-forward svc/ray-serve-llm-serve-svc 8000:8000

# Ray dashboard (separate terminal)
kubectl port-forward svc/ray-serve-llm-head-svc 8265:8265
```

API is then available at `http://localhost:8000`.
Dashboard at `http://localhost:8265`.

### Option B — LoadBalancer service

Patch the serve service to type `LoadBalancer. In CMK, Load Balancers are controlled by feature flags and quotas, so contact Crusoe if you haven't used them before:

```bash
kubectl patch svc ray-serve-llm-serve-svc \
  -p '{"spec": {"type": "LoadBalancer"}}'
```

Wait for an external IP to be assigned:

```bash
kubectl get svc ray-serve-llm-serve-svc -w
```

Once assigned, use that IP in place of `localhost:8000` in all commands below.

---

## 5. Test with curl

All examples use `http://localhost:8000` (port-forward) — substitute the LoadBalancer IP/hostname if using Option B.

### List available models

```bash
curl http://localhost:8000/v1/models
```

### Basic chat completion

```bash
curl http://localhost:8000/v1/chat/completions \
  -H "Content-Type: application/json" \
  -d '{
    "model": "deepseek-r1-distill-llama-70b",
    "messages": [
      {"role": "user", "content": "What is the capital of France?"}
    ],
    "max_tokens": 512
  }'
```

### Streaming response

```bash
curl http://localhost:8000/v1/chat/completions \
  -H "Content-Type: application/json" \
  -d '{
    "model": "deepseek-r1-distill-llama-70b",
    "messages": [
      {"role": "user", "content": "Solve step by step: if 3x + 7 = 22, what is x?"}
    ],
    "max_tokens": 2048,
    "stream": true
  }'
```

### Multi-turn conversation with system prompt

```bash
curl http://localhost:8000/v1/chat/completions \
  -H "Content-Type: application/json" \
  -d '{
    "model": "deepseek-r1-distill-llama-70b",
    "messages": [
      {"role": "system", "content": "You are a concise assistant. Answer briefly."},
      {"role": "user", "content": "Explain gradient descent."},
      {"role": "assistant", "content": "Gradient descent minimizes a loss function by iteratively stepping in the direction of the negative gradient."},
      {"role": "user", "content": "How does learning rate affect it?"}
    ],
    "max_tokens": 1024,
    "temperature": 0.6
  }'
```

### Reasoning-heavy prompt

DeepSeek-R1 emits `<think>...</think>` tokens before its final answer. Stream this to observe the chain of thought in real time:

```bash
curl http://localhost:8000/v1/chat/completions \
  -H "Content-Type: application/json" \
  -d '{
    "model": "deepseek-r1-distill-llama-70b",
    "messages": [
      {"role": "user", "content": "A bat and a ball cost $1.10 in total. The bat costs $1.00 more than the ball. How much does the ball cost?"}
    ],
    "max_tokens": 4096,
    "temperature": 0.6,
    "stream": true
  }'
```

> **Tip:** Use `temperature` 0.5–0.7 for reasoning tasks. Avoid `temperature: 0` — it can produce repetitive output with R1 models.

---

## 6. Cleanup

```bash
kubectl delete -f ray-service.llm-serve.yaml
```

To also remove the CRDs and operator:

```bash
helm uninstall kuberay-operator -n kuberay-system
kubectl delete -k "github.com/ray-project/kuberay/ray-operator/config/crd?ref=v1.5.1"
```

---

## References

- [KubeRay Helm chart](https://github.com/ray-project/kuberay/tree/master/helm-chart/kuberay-operator)
- [Ray Serve LLM docs](https://docs.ray.io/en/latest/serve/llm/serving-llms.html)
- [vLLM documentation](https://docs.vllm.ai/)
- [DeepSeek-R1-Distill-Llama-70B on HuggingFace](https://huggingface.co/deepseek-ai/DeepSeek-R1-Distill-Llama-70B)
