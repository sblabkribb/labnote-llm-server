#!/bin/bash
# This script sets up the complete AI backend environment, including DPO training dependencies.
set -e

# --- 1. System & Prerequisite Setup ---
echo ">>> (Step 1/6) Updating package lists and installing prerequisites..."
apt-get update > /dev/null
apt-get install -y curl > /dev/null
pip install -q huggingface_hub[cli]
echo ">>> Prerequisites are up to date."

# --- 2. Redis Stack Server Setup ---
echo ">>> (Step 2/6) Setting up Redis Stack Server..."
if ! command -v redis-stack-server &> /dev/null;
then
    echo "    - Installing Redis..."
    curl -fsSL https://packages.redis.io/gpg | gpg --dearmor -o /usr/share/keyrings/redis-archive-keyring.gpg
    echo "deb [signed-by=/usr/share/keyrings/redis-archive-keyring.gpg] https://packages.redis.io/deb $(lsb_release -cs) main" | tee /etc/apt/sources.list.d/redis.list > /dev/null
    apt-get update > /dev/null
    apt-get install -y redis-stack-server > /dev/null
fi
if ! pgrep -f redis-stack-server > /dev/null;
then
    redis-stack-server --daemonize yes
    echo ">>> Redis Stack Server started."
else
    echo ">>> Redis is already running."
fi

# --- 3. Ollama and Embedding Model Setup ---
echo ">>> (Step 3/6) Setting up Ollama and embedding model..."
if ! command -v ollama &> /dev/null;
then
    echo "    - Installing Ollama..."
    curl -fsSL https://ollama.com/install.sh | sh
fi
if ! pgrep -f "ollama serve" > /dev/null;
then
    echo "    - Starting Ollama server in background..."
    ollama serve &
    sleep 5 # Give it a moment to initialize
fi

echo "    - Verifying and pulling 'nomic-embed-text' model..."
ollama pull nomic-embed-text > /dev/null
echo ">>> Ollama server and embedding model are ready."

# --- 4. Main LLM Setup (Inference & DPO) ---
echo ">>> (Step 4/6) Setting up main LLMs for Inference and DPO..."

# DPO Base Model (Hugging Face Transformers format)
DPO_MODEL_PATH="/models/hf/Llama3-OpenBioLLM-8B"
echo "    - Checking for DPO base model at ${DPO_MODEL_PATH}..."
if [ ! -d "${DPO_MODEL_PATH}" ]; then
    echo "    - DPO base model not found. Downloading from Hugging Face (aaditya/Llama3-OpenBioLLM-8B)..."
    # Updated: Corrected repo_id from BioMistral to aaditya
    huggingface-cli download aaditya/Llama3-OpenBioLLM-8B --local-dir "${DPO_MODEL_PATH}" --local-dir-use-symlinks False
    echo "    - DPO base model downloaded."
else
    echo "    - DPO base model already exists."
fi

# Inference Model (Ollama GGUF format)
INFERENCE_MODEL_NAME="biollama3"
GGUF_MODEL_FILE_PATH="/models/gguf/llama3-openbiollm-8b.Q4_K_M.gguf" # [수정됨] 정확한 파일명 지정
echo "    - Checking for Inference model '${INFERENCE_MODEL_NAME}'..."
if ! ollama list | grep -q "${INFERENCE_MODEL_NAME}"; then
    if [ ! -f "${GGUF_MODEL_FILE_PATH}" ]; then
        echo "    - GGUF model file not found. Downloading from Hugging Face (MoMonir/Llama3-OpenBioLLM-8B-GGUF)..."
        # [수정됨] mradermacher -> MoMonir, 그리고 다운로드할 파일명 명시
        huggingface-cli download MoMonir/Llama3-OpenBioLLM-8B-GGUF \
            llama3-openbiollm-8b.Q4_K_M.gguf \
            --local-dir /models/gguf --local-dir-use-symlinks False
    fi
    
    echo "    - Creating Modelfile for '${INFERENCE_MODEL_NAME}'..."
    cat <<'EOF' > /models/Modelfile
FROM /models/gguf/llama3-openbiollm-8b.Q4_K_M.gguf
TEMPLATE """<|begin_of_text|><|start_header_id|>system<|end_header_id|>

{{ .System }}<|eot_id|><|start_header_id|>user<|end_header_id|>

{{ .Prompt }}<|eot_id|><|start_header_id|>assistant<|end_header_id|>
"""
PARAMETER stop "<|eot_id|>"
PARAMETER stop "<|end_of_text|>"
EOF
    
    echo "    - Creating custom model with Ollama..."
    ollama create "${INFERENCE_MODEL_NAME}" -f /models/Modelfile
    echo ">>> Inference LLM '${INFERENCE_MODEL_NAME}' is ready."
else
    echo ">>> Inference LLM '${INFERENCE_MODEL_NAME}' already exists."
fi

# --- 4.5. Additional LLM Setup ---
echo ">>> (Step 4.5/6) Setting up additional LLM models..."
ADDITIONAL_MODELS=("mixtral" "llama3:70b")
for model in "${ADDITIONAL_MODELS[@]}"; do
    if ! ollama list | grep -q "${model}"; then
        echo "    - Model '${model}' not found. Downloading now..."
        ollama pull "${model}"
    else
        echo "    - Model '${model}' already exists. Skipping download."
    fi
done
echo ">>> Additional LLMs are ready."

# --- 5. Environment and Backend Dependencies Setup ---
echo ">>> (Step 5/6) Setting up .env file and installing backend dependencies..."
# `labnote-ai-backend` 디렉터리가 존재할 경우에만 들어감
if [ -d "labnote-ai-backend" ]; then
    cd labnote-ai-backend
else
    # repository 루트에 있을 경우를 대비
    echo "    - Already in the project root."
fi


# Create .env file
echo "    - Creating .env file..."
cat << EOF > .env
# Backend Server Configuration
REDIS_URL="redis://localhost:6379/0"
OLLAMA_BASE_URL="http://127.0.0.1:11434"

# Model Configuration
EMBEDDING_MODEL="nomic-embed-text"
LLM_MODEL="${INFERENCE_MODEL_NAME}" # For inference via Ollama

# DPO Training Configuration
BASE_MODEL_PATH="${DPO_MODEL_PATH}" # For DPO training script
NEW_MODEL_NAME="biollama3-v2-dpo"
EOF

echo "    - Installing Python dependencies from requirements.txt..."
pip install -r requirements.txt > /dev/null
echo ">>> Backend dependencies installed and .env file created."

# 시작 스크립트가 루트에서 실행될 경우를 대비해 다시 상위 디렉토리로 이동하지 않음

# --- 6. Final Instructions ---
echo ">>> (Step 6/6) Setup complete!"

echo "
--- Next Steps ---"
echo "1. Start the FastAPI Backend Server:"
echo "   cd labnote-ai-backend"
echo "   uvicorn main:app --host 0.0.0.0 --port 8000"
echo "
2. To run the DPO training pipeline (optional):"
echo "   cd labnote-ai-backend"
echo "   python scripts/run_dpo_training.py"
echo "------------------"