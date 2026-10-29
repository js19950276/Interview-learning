import CoreML
import Foundation

extension GameCore {
    /// P3:端上网络评估——CoreML 模型替换远程推理(spec §10.4)。
    /// 加载失败 → 抛错,由调用方回退启发式(绝不静默用坏模型)。
    /// MLModel 按苹果文档线程安全但未标注 Sendable;MCTS 在后台线程调用,
    /// 用 @unchecked 包装(创建后只读)。
    nonisolated final class MLModelBox: @unchecked Sendable {
        let model: MLModel
        init(_ model: MLModel) { self.model = model }
    }

    /// 复用输入缓冲(创建后只读持有,写入只在 MCTS 单线程内发生)。
    nonisolated final class MLArrayBox: @unchecked Sendable {
        let array: MLMultiArray
        init(_ array: MLMultiArray) { self.array = array }
    }

    nonisolated struct CoreMLEvaluation: MCTSEvaluator {
        private let box: MLModelBox
        private let catalog: VerifiedGameDataCatalog

        init(catalog: VerifiedGameDataCatalog, bundle: Bundle = .main) throws {
            guard let url = bundle.url(forResource: "BrassNet", withExtension: "mlmodelc") else {
                throw CoreMLEvaluationError.modelMissing
            }
            self.box = MLModelBox(try MLModel(contentsOf: url))
            self.catalog = catalog
            self.inputBox = MLArrayBox(try MLMultiArray(
                shape: [1, NSNumber(value: NeuralProtocol.featureDim)], dataType: .float32
            ))
        }

        func utilities(
            state: GameState, incomeTrack: [IncomeTrack.Entry]
        ) throws -> [PlayerID: Double] {
            // 终局叶:排名效用精确已知,不走网络。
            if state.turnPhase == .ended, let standings = state.finalStandings {
                return HeuristicEvaluator.standingsUtilities(standings: standings, players: state.players)
            }
            let output = try predict(state: state)
            var utilities: [PlayerID: Double] = [:]
            for (seat, player) in state.players.enumerated() {
                let index = min(seat, output.value.count - 1)
                utilities[player.id] = Double(output.value[index])
            }
            return utilities
        }

        func priors(
            for payloads: [PlayerIntent.Payload],
            state: GameState,
            catalog: VerifiedGameDataCatalog
        ) throws -> [Double] {
            let layout = StateEncoder.makeLayout(catalog: catalog)
            let output = try predict(state: state)
            let kinds = ActionKind.allCases
            var weights: [Double] = []
            weights.reserveCapacity(payloads.count)
            for payload in payloads {
                guard let kind = RemoteEvaluation.kindIndex(of: payload, order: kinds) else {
                    weights.append(0.0)
                    continue
                }
                var weight = Double(output.policyA[kind])
                if let definitionID = RemoteEvaluation.cardDefinition(of: payload, state: state),
                   let cardIndex = layout.cardIndex[definitionID] {
                    weight *= Double(output.policyB[cardIndex])
                }
                weights.append(weight)
            }
            let total = weights.reduce(0, +)
            guard total > 0 else { return weights }
            return weights.map { $0 / total }
        }

        private struct Output {
            var policyA: [Float]
            var policyB: [Float]
            var value: [Float]
        }

        /// 复用输入缓冲(避免每次预测重建 MLMultiArray);
        /// 数据经 dataPointer 单次 memcpy 写入——NSNumber 逐元素装箱慢一个量级。
        private let inputBox: MLArrayBox

        private func predict(state: GameState) throws -> Output {
            let features = StateEncoder.encode(state: state, catalog: catalog)
            features.withUnsafeBufferPointer { source in
                inputBox.array.dataPointer.withMemoryRebound(
                    to: Float.self, capacity: features.count
                ) { destination in
                    destination.update(from: source.baseAddress!, count: features.count)
                }
            }
            let featuresValue = try MLDictionaryFeatureProvider(dictionary: ["features": inputBox.array])
            let prediction = try box.model.prediction(from: featuresValue)
            guard let a = prediction.featureValue(for: "policyA")?.multiArrayValue,
                  let b = prediction.featureValue(for: "policyB")?.multiArrayValue,
                  let v = prediction.featureValue(for: "value")?.multiArrayValue
            else { throw CoreMLEvaluationError.outputMissing }
            return Output(
                policyA: (0..<a.count).map { Float(truncating: a[$0]) },
                policyB: (0..<b.count).map { Float(truncating: b[$0]) },
                value: (0..<v.count).map { Float(truncating: v[$0]) }
            )
        }
    }

    nonisolated enum CoreMLEvaluationError: Swift.Error, Equatable, Sendable {
        case modelMissing
        case outputMissing
    }
}
