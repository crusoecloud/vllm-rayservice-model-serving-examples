"""
DeepSeek Model Deployment with Ray Serve and vLLM
This script defines the Ray Serve deployment for serving DeepSeek models.
"""

import os
from typing import Dict, Any
from ray import serve
from vllm import LLM, SamplingParams


@serve.deployment(
    name="DeepSeekModel",
    autoscaling_config={
        "min_replicas": 1,
        "max_replicas": 1,
        "target_num_ongoing_requests_per_replica": 5,
    },
    max_concurrent_queries=100,
)
class DeepSeekDeployment:
    def __init__(self, model: str, tensor_parallel_size: int = 8,
                 max_model_len: int = 4096, gpu_memory_utilization: float = 0.95):
        """
        Initialize the DeepSeek model with vLLM.

        Args:
            model: HuggingFace model ID (e.g., "deepseek-ai/deepseek-coder-33b-instruct")
            tensor_parallel_size: Number of GPUs to use for tensor parallelism
            max_model_len: Maximum sequence length
            gpu_memory_utilization: GPU memory utilization ratio
        """
        # Ensure HuggingFace token is available
        hf_token = os.getenv("HF_TOKEN")
        if not hf_token:
            raise ValueError("HF_TOKEN environment variable must be set")

        # Initialize vLLM engine with DeepSeek model
        self.llm = LLM(
            model=model,
            tensor_parallel_size=tensor_parallel_size,
            max_model_len=max_model_len,
            gpu_memory_utilization=gpu_memory_utilization,
            trust_remote_code=True,
            download_dir="/root/.cache/huggingface",
            tokenizer_mode="auto",
            dtype="float16",  # or "bfloat16" for H100
            # Enable FlashAttention for better performance on H100
            enforce_eager=False,
        )

        self.model_name = model
        print(f"DeepSeek model {model} loaded successfully with {tensor_parallel_size} GPUs")

    async def __call__(self, request: Dict[str, Any]) -> Dict[str, Any]:
        """
        Handle inference requests.

        Expected request format:
        {
            "prompt": "Your prompt here",
            "max_tokens": 512,
            "temperature": 0.7,
            "top_p": 0.9,
            "top_k": 50,
            "stream": false
        }
        """
        # Extract parameters from request
        prompt = request.get("prompt", "")
        if not prompt:
            return {"error": "No prompt provided"}

        # Sampling parameters
        sampling_params = SamplingParams(
            temperature=request.get("temperature", 0.7),
            top_p=request.get("top_p", 0.9),
            top_k=request.get("top_k", 50),
            max_tokens=request.get("max_tokens", 512),
            stop=request.get("stop", None),
        )

        # Generate response
        try:
            outputs = self.llm.generate([prompt], sampling_params)
            generated_text = outputs[0].outputs[0].text

            return {
                "model": self.model_name,
                "prompt": prompt,
                "generated_text": generated_text,
                "finish_reason": outputs[0].outputs[0].finish_reason,
            }
        except Exception as e:
            return {"error": str(e)}


# Create deployment binding
deployment = DeepSeekDeployment.bind()
