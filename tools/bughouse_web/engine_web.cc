// Hivemind's unchanged MCTS calls this backend. Asyncify suspends C++ while
// ONNX Runtime Web evaluates the tensors, without blocking the page.
#include "nn/engine.h"
#include <emscripten.h>

struct Engine::OrtState {
    const float* input = nullptr;
    std::vector<float> value, policyA, policyB, wdl, movesLeft;
};

EM_ASYNC_JS(int, infer_web, (const float* input, int batch, float* value,
                           float* policyA, float* policyB, float* wdl, float* movesLeft), {
    try {
        await Module.infer(input, batch, value, policyA, policyB, wdl, movesLeft);
        return 1;
    } catch (error) {
        Module.inferenceError = String(error);
        return 0;
    }
});

Engine::Engine(int deviceId, int batchSize)
    : m_deviceId(deviceId), m_batchSize(batchSize), m_ort(std::make_unique<OrtState>()) {
    m_ort->value.resize(batchSize);
    m_ort->policyA.resize(batchSize * NB_POLICY_VALUES());
    m_ort->policyB.resize(batchSize * NB_POLICY_VALUES());
    m_ort->wdl.resize(batchSize * 3);
    m_ort->movesLeft.resize(batchSize);
}
Engine::~Engine() = default;
const char* Engine::backendName() { return "ONNX Runtime Web"; }
bool Engine::loadNetwork(const std::string&, const std::string&) { return true; }
bool Engine::enqueueInferenceHalf(const __half* input, size_t) {
    m_ort->input = input;
    return true;
}
bool Engine::synchronizeInferenceHalf(HalfInferenceOutputs& out, size_t) {
    if (!infer_web(m_ort->input, m_batchSize, m_ort->value.data(),
                   m_ort->policyA.data(), m_ort->policyB.data(),
                   m_ort->wdl.data(), m_ort->movesLeft.data())) return false;
    out.value = m_ort->value.data();
    out.policyA = m_ort->policyA.data();
    out.policyB = m_ort->policyB.data();
    out.wdl = m_ort->wdl.data();
    out.movesLeft = m_ort->movesLeft.data();
    return true;
}
