#!/bin/bash
# Test script for DeepSeek RayService API
# Make sure to port-forward first: kubectl port-forward -n default svc/deepseek-serve-simple 8000:8000

API_URL="${API_URL:-http://localhost:8000}"

echo "Testing DeepSeek API at $API_URL"
echo "================================"

# Test 1: Simple completion
echo -e "\n1. Testing simple code completion..."
curl -X POST "$API_URL/v1/completions" \
  -H "Content-Type: application/json" \
  -d '{
    "model": "deepseek-ai/deepseek-coder-33b-instruct",
    "prompt": "def fibonacci(n):\n    \"\"\"Calculate fibonacci number\"\"\"",
    "max_tokens": 200,
    "temperature": 0.2,
    "stop": ["\n\n"]
  }' | jq '.'

# Test 2: Chat completion (if using OpenAI-compatible API)
echo -e "\n2. Testing chat completion..."
curl -X POST "$API_URL/v1/chat/completions" \
  -H "Content-Type: application/json" \
  -d '{
    "model": "deepseek-ai/deepseek-coder-33b-instruct",
    "messages": [
      {"role": "system", "content": "You are a helpful coding assistant."},
      {"role": "user", "content": "Write a Python function to reverse a string"}
    ],
    "max_tokens": 300,
    "temperature": 0.7
  }' | jq '.'

# Test 3: Code explanation
echo -e "\n3. Testing code explanation..."
curl -X POST "$API_URL/v1/completions" \
  -H "Content-Type: application/json" \
  -d '{
    "model": "deepseek-ai/deepseek-coder-33b-instruct",
    "prompt": "# Explain this code:\n# def quick_sort(arr):\n#     if len(arr) <= 1:\n#         return arr\n#     pivot = arr[len(arr) // 2]\n#     left = [x for x in arr if x < pivot]\n#     middle = [x for x in arr if x == pivot]\n#     right = [x for x in arr if x > pivot]\n#     return quick_sort(left) + middle + quick_sort(right)\n\nExplanation:",
    "max_tokens": 400,
    "temperature": 0.3
  }' | jq '.'

# Test 4: Stream completion
echo -e "\n4. Testing streaming completion..."
curl -X POST "$API_URL/v1/completions" \
  -H "Content-Type: application/json" \
  -d '{
    "model": "deepseek-ai/deepseek-coder-33b-instruct",
    "prompt": "Write a Python class for a binary search tree with insert and search methods:\n\nclass BinarySearchTree:",
    "max_tokens": 500,
    "temperature": 0.5,
    "stream": true
  }'

# Test 5: Check model info
echo -e "\n\n5. Getting model information..."
curl -X GET "$API_URL/v1/models" | jq '.'

# Test 6: Health check
echo -e "\n6. Health check..."
curl -X GET "$API_URL/health" | jq '.'

echo -e "\n================================"
echo "API tests complete!"
