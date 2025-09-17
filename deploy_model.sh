#!/bin/bash
# DPO 학습 완료 후 모델 변환, 등록, .env 업데이트를 자동화하는 스크립트

# --- 설정 (필요에 따라 수정) ---
set -e # 오류 발생 시 스크립트 즉시 중단

# llama.cpp 프로젝트 경로 (직접 클론하고 빌드해야 함)
# 예: LLAMA_CPP_PATH="/root/llama.cpp"
LLAMA_CPP_PATH="/root/llama.cpp"

# DPO 학습으로 생성된 모델이 저장된 경로
TRAINED_MODEL_DIR="../biollama3-v2-dpo"

# GGUF로 변환된 모델을 저장할 경로
GGUF_OUTPUT_DIR="./gguf_models"

# Ollama에 등록할 새 모델의 이름 (태그 포함)
NEW_OLLAMA_MODEL_NAME="biollama3:dpo-v2"

# 양자화(Quantization) 방식 (예: Q4_K_M, Q5_K_M 등)
QUANTIZE_METHOD="Q4_K_M"

# --- 스크립트 시작 ---
echo "🚀 DPO 모델 배포 자동화를 시작합니다."

# 1. GGUF 변환 및 양자화
echo "Step 1/4: llama.cpp를 사용하여 모델을 GGUF로 변환 및 양자화합니다..."
mkdir -p "${GGUF_OUTPUT_DIR}"
GGUF_FILE_PATH="${GGUF_OUTPUT_DIR}/llama3-openbiollm-8b.${QUANTIZE_METHOD}.gguf"

# FP16 GGUF로 변환
python3 "${LLAMA_CPP_PATH}/convert-hf-to-gguf.py" "${TRAINED_MODEL_DIR}" \
  --outfile "${GGUF_FILE_PATH}.fp16" \
  --outtype f16

# 지정된 방식으로 양자화
"${LLAMA_CPP_PATH}/build/bin/quantize" "${GGUF_FILE_PATH}.fp16" "${GGUF_FILE_PATH}" "${QUANTIZE_METHOD}"

echo "✅ GGUF 변환 완료: ${GGUF_FILE_PATH}"

# 2. Modelfile 동적 생성
echo "Step 2/4: 새 모델을 위한 Modelfile을 생성합니다..."
MODLEFILE_PATH="${GGUF_OUTPUT_DIR}/Modelfile"
cat <<EOF > "${MODLEFILE_PATH}"
FROM ${GGUF_FILE_PATH}
TEMPLATE """<|begin_of_text|><|start_header_id|>system<|end_header_id|>

{{ .System }}<|eot_id|><|start_header_id|>user<|end_header_id|>

{{ .Prompt }}<|eot_id|><|start_header_id|>assistant<|end_header_id|>
"""
PARAMETER stop "<|eot_id|>"
PARAMETER stop "<|end_of_text|>"
EOF
echo "✅ Modelfile 생성 완료: ${MODLEFILE_PATH}"

# 3. Ollama에 새 모델 등록
echo "Step 3/4: Ollama에 '${NEW_OLLAMA_MODEL_NAME}' 모델을 생성합니다..."
ollama create "${NEW_OLLAMA_MODEL_NAME}" -f "${MODLEFILE_PATH}"
echo "✅ Ollama 모델 등록 완료."

# 4. .env 파일의 LLM_MODEL 업데이트
echo "Step 4/4: .env 파일의 LLM_MODEL을 새 버전으로 업데이트합니다..."
ENV_FILE="../.env"
if [ -f "$ENV_FILE" ]; then
    # 기존 .env 파일 백업
    cp "$ENV_FILE" "$ENV_FILE.bak"
    # LLM_MODEL 값을 새로운 모델 이름으로 변경 (sed 명령어 활용)
    sed -i -e "s/^LLM_MODEL=.*/LLM_MODEL=${NEW_OLLAMA_MODEL_NAME}/" "$ENV_FILE"
    echo "✅ .env 파일 업데이트 완료. 이전 설정은 .env.bak 파일에 백업되었습니다."
else
    echo "⚠️ 경고: .env 파일을 찾을 수 없어 업데이트하지 못했습니다."
fi

echo "🎉 모든 배포 과정이 성공적으로 완료되었습니다!"
