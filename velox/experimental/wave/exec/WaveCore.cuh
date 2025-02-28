/*
 * Copyright (c) Facebook, Inc. and its affiliates.
 *
 * Licensed under the Apache License, Version 2.0 (the "License");
 * you may not use this file except in compliance with the License.
 * You may obtain a copy of the License at
 *
 *     http://www.apache.org/licenses/LICENSE-2.0
 *
 * Unless required by applicable law or agreed to in writing, software
 * distributed under the License is distributed on an "AS IS" BASIS,
 * WITHOUT WARRANTIES OR CONDITIONS OF ANY KIND, either express or implied.
 * See the License for the specific language governing permissions and
 * limitations under the License.
 */
#pragma once

#include "velox/experimental/wave/common/Scan.cuh"
#include "velox/experimental/wave/exec/ExprKernel.h"
#include "velox/experimental/wave/vector/Operand.h"

namespace facebook::velox::wave {

template <typename T>
inline T* __device__ gridStatus(const WaveShared* shared, int32_t gridState) {
  return reinterpret_cast<T*>(
      roundUp(
          reinterpret_cast<uintptr_t>(
              &shared->status
                   [shared->numBlocks - (shared->blockBase / kBlockSize)]),
          8) +
      gridState);
}

template <typename T>
inline T* __device__
gridStatus(const WaveShared* shared, const InstructionStatus& status) {
  return gridStatus<T>(shared, status.gridState);
}

template <typename T>
inline T* __device__ laneStatus(
    const WaveShared* shared,
    const InstructionStatus& status,
    int32_t nthBlock) {
  return reinterpret_cast<T*>(
      roundUp(
          reinterpret_cast<uintptr_t>(shared->status) +
              shared->numBlocks * sizeof(BlockStatus),
          8) +
      status.gridStateSize + status.blockState * shared->numBlocks);
}

inline bool __device__ laneActive(ErrorCode code) {
  return static_cast<uint8_t>(code) <=
      static_cast<uint8_t>(ErrorCode::kContinue);
}

template <typename T>
__device__ inline T& flatValue(void* base, int32_t blockBase) {
  return reinterpret_cast<T*>(base)[blockBase + threadIdx.x];
}

/// Returns true if operand is non null. Sets 'value' to the value of the
/// operand.
template <typename T>
__device__ __forceinline__ bool operandOrNull(
    Operand** operands,
    OperandIndex opIdx,
    int32_t blockBase,
    T& value) {
  auto op = operands[opIdx];
  int32_t index = threadIdx.x;
  if (auto indicesInOp = op->indices) {
    auto indices = indicesInOp[blockBase / kBlockSize];
    if (indices) {
      index = indices[index];
      if (index == kNullIndex) {
        return false;
      }
    } else {
      index += blockBase;
    }
  } else {
    index = (index + blockBase) & op->indexMask;
  }
  if (op->nulls && op->nulls[index] == kNull) {
    return false;
  }
  value = reinterpret_cast<const T*>(op->base)[index];
  return true;
}

template <bool kMayWrap, typename T>
bool __device__ __forceinline__ valueOrNull(
    Operand** operands,
    OperandIndex opIdx,
    int32_t blockBase,
    T& value) {
  auto op = operands[opIdx];
  int32_t index = threadIdx.x;
  if (!kMayWrap) {
    index = (index + blockBase) & op->indexMask;
    if (op->nulls && op->nulls[index] == kNull) {
      return false;
    }
    value = reinterpret_cast<const T*>(op->base)[index];
    return true;
  }
  if (auto indicesInOp = op->indices) {
    auto indices = indicesInOp[blockBase / kBlockSize];
    if (indices) {
      index = indices[index];
      if (index == kNullIndex) {
        return false;
      }
    } else {
      index += blockBase;
    }
  } else {
    index = (index + blockBase) & op->indexMask;
  }
  if (op->nulls && op->nulls[index] == kNull) {
    return false;
  }
  value = reinterpret_cast<const T*>(op->base)[index];
  return true;
}

template <bool kMayWrap, typename T>
void __device__ __forceinline__ loadValueOrNull(
    Operand** operands,
    OperandIndex opIdx,
    int32_t blockBase,
    T& value,
    uint32_t& nulls) {
  nulls = (nulls & ~(1U << (opIdx & 31))) |
      (static_cast<uint32_t>(
           valueOrNull<kMayWrap>(operands, opIdx, blockBase, value))
       << (opIdx & 31));
}

template <bool kMayWrap, typename T>
T __device__ __forceinline__
nonNullOperand(Operand** operands, OperandIndex opIdx, int32_t blockBase) {
  auto op = operands[opIdx];
  int32_t index = threadIdx.x;
  if (!kMayWrap) {
    index = (index + blockBase) & op->indexMask;
    return reinterpret_cast<const T*>(op->base)[index];
  }
  if (auto indicesInOp = op->indices) {
    auto indices = indicesInOp[blockBase / kBlockSize];
    if (indices) {
      index = indices[index];
    } else {
      index += blockBase;
    }
  } else {
    index = (index + blockBase) & op->indexMask;
  }
  return reinterpret_cast<const T*>(op->base)[index];
}

bool __device__ __forceinline__
setRegisterNull(uint32_t& flags, int8_t bit, bool isNull) {
  if (isNull) {
    flags &= ~(1 << bit);
  }
  return isNull;
}

bool __device__ __forceinline__ isRegisterNull(uint32_t flags, int8_t bit) {
  return 0 == (flags & (1 << bit));
}

template <typename T>
__device__ inline T&
flatOperand(Operand** operands, OperandIndex opIdx, int32_t blockBase) {
  auto* op = operands[opIdx];
  if (op->nulls) {
    op->nulls[blockBase + threadIdx.x] = kNotNull;
  }
  return reinterpret_cast<T*>(op->base)[blockBase + threadIdx.x];
}

/// Clears 'bit' from 'flags' if notNull is false. Returns true if bit cleared.
bool __device__ __forceinline__
setNullRegister(uint32_t& flags, int8_t bit, bool notNull) {
  if (!notNull) {
    flags &= ~(1 << bit);
  }
  return !notNull;
}

/// Sets the lane's result to null for opIdx.
__device__ inline void
resultNull(Operand** operands, OperandIndex opIdx, int32_t blockBase) {
  auto* op = operands[opIdx];
  op->nulls[blockBase + threadIdx.x] = kNull;
}

__device__ inline void setNull(
    Operand** operands,
    OperandIndex opIdx,
    int32_t blockBase,
    bool isNull) {
  auto* op = operands[opIdx];
  op->nulls[blockBase + threadIdx.x] = isNull ? kNull : kNotNull;
}

template <typename T>
__device__ inline T&
flatResult(Operand** operands, OperandIndex opIdx, int32_t blockBase) {
  auto* op = operands[opIdx];
  if (op->nulls) {
    op->nulls[blockBase + threadIdx.x] = kNotNull;
  }
  return reinterpret_cast<T*>(op->base)[blockBase + threadIdx.x];
}

template <typename T>
__device__ inline T& flatResult(Operand* op, int32_t blockBase) {
  return flatResult<T>(&op, 0, blockBase);
}

#define PROGRAM_PREAMBLE(blockOffset)                                          \
  extern __shared__ char sharedChar[];                                         \
  WaveShared* shared = reinterpret_cast<WaveShared*>(sharedChar);              \
  int programIndex = params.programIdx[blockIdx.x + blockOffset];              \
  auto* program = params.programs[programIndex];                               \
  if (threadIdx.x == 0) {                                                      \
    shared->operands = params.operands[programIndex];                          \
    shared->status = &params.status                                            \
                          [blockIdx.x + blockOffset -                          \
                           params.blockBase[blockIdx.x + blockOffset]];        \
    shared->numRows = shared->status->numRows;                                 \
    shared->blockBase = (blockIdx.x + blockOffset -                            \
                         params.blockBase[blockIdx.x + blockOffset]) *         \
        blockDim.x;                                                            \
    shared->states = params.operatorStates[programIndex];                      \
    shared->numBlocks = params.numBlocks;                                      \
    shared->numRowsPerThread = params.numRowsPerThread;                        \
    shared->streamIdx = params.streamIdx;                                      \
    shared->isContinue = params.startPC != nullptr;                            \
    shared->hasContinue = false;                                               \
    shared->stop = false;                                                      \
  }                                                                            \
  __syncthreads();                                                             \
  auto blockBase = shared->blockBase;                                          \
  auto operands = shared->operands;                                            \
  ErrorCode laneStatus;                                                        \
  Instruction* instruction;                                                    \
  if (!shared->isContinue) {                                                   \
    instruction = program->instructions;                                       \
    laneStatus =                                                               \
        threadIdx.x < shared->numRows ? ErrorCode::kOk : ErrorCode::kInactive; \
  } else {                                                                     \
    auto start = params.startPC[programIndex];                                 \
    if (start == ~0) {                                                         \
      return; /* no continue in this program*/                                 \
    }                                                                          \
    instruction = program->instructions + start;                               \
    laneStatus = shared->status->errors[threadIdx.x];                          \
  }

#define GENERATED_PREAMBLE(blockOffset)                                        \
  extern __shared__ char sharedChar[];                                         \
  WaveShared* shared = reinterpret_cast<WaveShared*>(sharedChar);              \
  int programIndex = params.programIdx[blockIdx.x + blockOffset];              \
  if (threadIdx.x == 0) {                                                      \
    shared->operands = params.operands[programIndex];                          \
    shared->status = &params.status                                            \
                          [blockIdx.x + blockOffset -                          \
                           params.blockBase[blockIdx.x + blockOffset]];        \
    shared->numRows = shared->status->numRows;                                 \
    shared->blockBase = (blockIdx.x + blockOffset -                            \
                         params.blockBase[blockIdx.x + blockOffset]) *         \
        blockDim.x;                                                            \
    shared->states = params.operatorStates[programIndex];                      \
    shared->numBlocks = params.numBlocks;                                      \
    shared->numRowsPerThread = params.numRowsPerThread;                        \
    shared->streamIdx = params.streamIdx;                                      \
    shared->isContinue = params.startPC != nullptr;                            \
    if (shared->isContinue) {                                                  \
      shared->startLabel = params.startPC[programIndex];                       \
    }                                                                          \
    shared->extraWraps = params.extraWraps;                                    \
    shared->numExtraWraps = params.numExtraWraps;                              \
    shared->hasContinue = false;                                               \
    shared->stop = false;                                                      \
  }                                                                            \
  __syncthreads();                                                             \
  auto blockBase = shared->blockBase;                                          \
  auto operands = shared->operands;                                            \
  ErrorCode laneStatus;                                                        \
  if (!shared->isContinue) {                                                   \
    laneStatus =                                                               \
        threadIdx.x < shared->numRows ? ErrorCode::kOk : ErrorCode::kInactive; \
  } else {                                                                     \
    laneStatus = shared->status->errors[threadIdx.x];                          \
  }

#define PROGRAM_EPILOGUE()                          \
  if (threadIdx.x == 0) {                           \
    shared->status->numRows = shared->numRows;      \
  }                                                 \
  shared->status->errors[threadIdx.x] = laneStatus; \
  __syncthreads();

__device__ __forceinline__ void filterKernel(
    const IFilter& filter,
    Operand** operands,
    int32_t blockBase,
    WaveShared* shared,
    ErrorCode& laneStatus) {
  bool isPassed = laneActive(laneStatus);
  if (isPassed) {
    if (!operandOrNull(operands, filter.flags, blockBase, isPassed)) {
      isPassed = false;
    }
  }
  uint32_t bits = __ballot_sync(0xffffffff, isPassed);
  if ((threadIdx.x & (kWarpThreads - 1)) == 0) {
    reinterpret_cast<int32_t*>(&shared->data)[threadIdx.x / kWarpThreads] =
        __popc(bits);
  }
  __syncthreads();
  if (threadIdx.x < kWarpThreads) {
    constexpr int32_t kNumWarps = kBlockSize / kWarpThreads;
    uint32_t cnt = threadIdx.x < kNumWarps
        ? reinterpret_cast<int32_t*>(&shared->data)[threadIdx.x]
        : 0;
    uint32_t sum;
    using Scan = WarpScan<uint32_t, kBlockSize / kWarpThreads>;
    Scan().exclusiveSum(cnt, sum);
    if (threadIdx.x < kNumWarps) {
      if (threadIdx.x == kNumWarps - 1) {
        shared->numRows = cnt + sum;
      }
      reinterpret_cast<int32_t*>(&shared->data)[threadIdx.x] = sum;
    }
  }
  __syncthreads();
  if (bits & (1 << (threadIdx.x & (kWarpThreads - 1)))) {
    auto* indices = reinterpret_cast<int32_t*>(operands[filter.indices]->base);
    auto start = blockBase +
        reinterpret_cast<int32_t*>(&shared->data)[threadIdx.x / kWarpThreads];
    auto bit = start +
        __popc(bits & lowMask<uint32_t>(threadIdx.x & (kWarpThreads - 1)));
    indices[bit] = blockBase + threadIdx.x;
  }
  laneStatus =
      threadIdx.x < shared->numRows ? ErrorCode::kOk : ErrorCode::kInactive;
  __syncthreads();
}

__device__ __forceinline__ void filterKernel(
    bool flag,
    Operand** operands,
    OperandIndex indicesIdx,
    int32_t blockBase,
    WaveShared* shared,
    ErrorCode& laneStatus) {
  bool isPassed = flag && laneActive(laneStatus);
  uint32_t bits = __ballot_sync(0xffffffff, isPassed);
  if ((threadIdx.x & (kWarpThreads - 1)) == 0) {
    reinterpret_cast<int32_t*>(&shared->data)[threadIdx.x / kWarpThreads] =
        __popc(bits);
  }
  __syncthreads();
  if (threadIdx.x < kWarpThreads) {
    constexpr int32_t kNumWarps = kBlockSize / kWarpThreads;
    uint32_t cnt = threadIdx.x < kNumWarps
        ? reinterpret_cast<int32_t*>(&shared->data)[threadIdx.x]
        : 0;
    uint32_t sum;
    using Scan = WarpScan<uint32_t, kBlockSize / kWarpThreads>;
    Scan().exclusiveSum(cnt, sum);
    if (threadIdx.x < kNumWarps) {
      if (threadIdx.x == kNumWarps - 1) {
        shared->numRows = cnt + sum;
      }
      reinterpret_cast<int32_t*>(&shared->data)[threadIdx.x] = sum;
    }
  }
  __syncthreads();
  if (bits & (1 << (threadIdx.x & (kWarpThreads - 1)))) {
    auto* indices = reinterpret_cast<int32_t*>(operands[indicesIdx]->base);
    auto start = blockBase +
        reinterpret_cast<int32_t*>(&shared->data)[threadIdx.x / kWarpThreads];
    auto bit = start +
        __popc(bits & lowMask<uint32_t>(threadIdx.x & (kWarpThreads - 1)));
    indices[bit] = blockBase + threadIdx.x;
  }
  laneStatus =
      threadIdx.x < shared->numRows ? ErrorCode::kOk : ErrorCode::kInactive;
  __syncthreads();
}

__device__ void __forceinline__ wrapKernel(
    const IWrap& wrap,
    Operand** operands,
    int32_t blockBase,
    int32_t numRows,
    void* shared) {
  Operand* op = operands[wrap.indices];
  auto* filterIndices = reinterpret_cast<int32_t*>(op->base);
  if (filterIndices[blockBase + numRows - 1] == numRows + blockBase - 1) {
    // There is no cardinality change.
    return;
  }

  struct WrapState {
    int32_t* indices;
  };

  auto* state = reinterpret_cast<WrapState*>(shared);
  bool rowActive = threadIdx.x < numRows;
  for (auto column = 0; column < wrap.numColumns; ++column) {
    if (threadIdx.x == 0) {
      auto opIndex = wrap.columns[column];
      auto* op = operands[opIndex];
      int32_t** opIndices = &op->indices[blockBase / kBlockSize];
      if (!*opIndices) {
        *opIndices = filterIndices + blockBase;
        state->indices = nullptr;
      } else {
        state->indices = *opIndices;
      }
    }
    __syncthreads();
    // Every thread sees the decision on thred 0 above.
    if (!state->indices) {
      continue;
    }
    int32_t newIndex;
    if (rowActive) {
      newIndex =
          state->indices[filterIndices[blockBase + threadIdx.x] - blockBase];
    }
    // All threads hit this.
    __syncthreads();
    if (rowActive) {
      state->indices[threadIdx.x] = newIndex;
    }
  }
  __syncthreads();
}

__device__ void __forceinline__ wrapKernel(
    const OperandIndex* wraps,
    int32_t numWraps,
    OperandIndex indicesIdx,
    Operand** operands,
    int32_t blockBase,
    WaveShared* shared) {
  Operand* op = operands[indicesIdx];
  auto* filterIndices = reinterpret_cast<int32_t*>(op->base);
  if (filterIndices[blockBase + shared->numRows - 1] ==
      shared->numRows + blockBase - 1) {
    // There is no cardinality change.
    return;
  }

  struct WrapState {
    int32_t* indices;
  };

  auto* state = reinterpret_cast<WrapState*>(&shared->data);
  bool rowActive = threadIdx.x < shared->numRows;
  int32_t totalWrap = numWraps + shared->numExtraWraps;
  for (auto column = 0; column < totalWrap; ++column) {
    if (threadIdx.x == 0) {
      auto opIndex = column < numWraps ? wraps[column]
                                       : shared->extraWraps + column - numWraps;
      auto* op = operands[opIndex];
      int32_t** opIndices = &op->indices[blockBase / kBlockSize];
      if (!*opIndices) {
        *opIndices = filterIndices + blockBase;
        state->indices = nullptr;
      } else {
        state->indices = *opIndices;
      }
    }
    __syncthreads();
    // Every thread sees the decision on thred 0 above.
    if (!state->indices) {
      continue;
    }
    int32_t newIndex;
    if (rowActive) {
      newIndex =
          state->indices[filterIndices[blockBase + threadIdx.x] - blockBase];
    }
    // All threads hit this.
    __syncthreads();
    if (rowActive) {
      state->indices[threadIdx.x] = newIndex;
    }
  }
  __syncthreads();
}

template <typename T>
__device__ inline T opFunc_kPlus(T left, T right) {
  return left + right;
}

template <typename T, typename OpFunc>
__device__ __forceinline__ void binaryOpKernel(
    OpFunc func,
    IBinary& instr,
    Operand** operands,
    int32_t blockBase,
    void* shared,
    ErrorCode& laneStatus) {
  if (!laneActive(laneStatus)) {
    return;
  }
  T left;
  T right;
  if (operandOrNull(operands, instr.left, blockBase, left) &&
      operandOrNull(operands, instr.right, blockBase, right)) {
    flatResult<decltype(func(left, right))>(operands, instr.result, blockBase) =
        func(left, right);
  } else {
    resultNull(operands, instr.result, blockBase);
  }
}

template <typename T>
__device__ T value(Operand* operands, OperandIndex opIdx) {
  // Obsolete signature. call sites must be changed.
  //    assert(false);
  *(long*)0 = 0;
  return T{};
}

} // namespace facebook::velox::wave
