//
//  TemporalStabilityWindow.swift
//  AR-Lighting-Study
//

//  Provides controls for thresholds and smoothing used by temporal light stabilization.
//  It edits the corresponding settings stored in AppModel.
import SwiftUI

struct TemporalStabilityWindow: View {
    @Environment(AppModel.self) private var appModel

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 16) {
                Text("Zeitliche Stabilisierung")
                    .font(.title2.weight(.semibold))

                Text(appModel.estimatedLightWarmupFreezeStatus)
                    .font(.caption.monospacedDigit())
                    .foregroundStyle(.secondary)

                thresholdControls
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(24)
        }
    }

    private var thresholdControls: some View {
        VStack(alignment: .leading, spacing: 16) {
            VStack(alignment: .leading, spacing: 4) {
                HStack {
                    Text("Positions-Schwelle")
                    Spacer()
                    Text("\(Int((appModel.stableLightPositionMinimumChange * 100).rounded())) cm")
                        .font(.caption.monospacedDigit())
                }

                Slider(
                    value: stableLightPositionMinimumChangeSliderValue,
                    in: 0.01...1.0,
                    step: 0.01
                )

                Text(appModel.stableLightPositionDebugStatus)
                    .font(.caption.monospacedDigit())
                    .foregroundStyle(.secondary)
            }

            VStack(alignment: .leading, spacing: 4) {
                HStack {
                    Text("Richtungs-Schwelle")
                    Spacer()
                    Text("\(appModel.stableLightDirectionMinimumChangeDegrees, format: .number.precision(.fractionLength(1)))°")
                        .font(.caption.monospacedDigit())
                }

                Slider(
                    value: stableLightDirectionMinimumChangeDegreesSliderValue,
                    in: 0.0...30.0,
                    step: 0.5
                )
            }

            VStack(alignment: .leading, spacing: 4) {
                HStack {
                    Text("Farb-Schwelle")
                    Spacer()
                    Text(appModel.stableLightColorMinimumChange, format: .number.precision(.fractionLength(2)))
                        .font(.caption.monospacedDigit())
                }

                Slider(
                    value: stableLightColorMinimumChangeSliderValue,
                    in: 0.0...0.25,
                    step: 0.01
                )

                HStack {
                    Text("Intensitaets-Schwelle")
                    Spacer()
                    Text("\(Int((appModel.stableLightIntensityMinimumRelativeChange * 100).rounded()))%")
                        .font(.caption.monospacedDigit())
                }

                Slider(
                    value: stableLightIntensityMinimumRelativeChangeSliderValue,
                    in: 0.0...0.5,
                    step: 0.01
                )

                HStack {
                    Text("Softness-Schwelle")
                    Spacer()
                    Text(appModel.stableLightShadowSoftnessMinimumChange, format: .number.precision(.fractionLength(2)))
                        .font(.caption.monospacedDigit())
                }

                Slider(
                    value: stableLightShadowSoftnessMinimumChangeSliderValue,
                    in: 0.0...0.3,
                    step: 0.01
                )
            }
        }
        .disabled(!appModel.isTemporalLightStabilizationEnabled)
    }

    private var stableLightPositionMinimumChangeSliderValue: Binding<Float> {
        Binding(
            get: { min(max(appModel.stableLightPositionMinimumChange, 0.01), 1.0) },
            set: { appModel.stableLightPositionMinimumChange = min(max($0, 0.01), 1.0) }
        )
    }

    private var stableLightColorMinimumChangeSliderValue: Binding<Float> {
        Binding(
            get: { min(max(appModel.stableLightColorMinimumChange, 0.0), 0.25) },
            set: { appModel.stableLightColorMinimumChange = min(max($0, 0.0), 0.25) }
        )
    }

    private var stableLightDirectionMinimumChangeDegreesSliderValue: Binding<Float> {
        Binding(
            get: { min(max(appModel.stableLightDirectionMinimumChangeDegrees, 0.0), 30.0) },
            set: { appModel.stableLightDirectionMinimumChangeDegrees = min(max($0, 0.0), 30.0) }
        )
    }

    private var stableLightIntensityMinimumRelativeChangeSliderValue: Binding<Float> {
        Binding(
            get: { min(max(appModel.stableLightIntensityMinimumRelativeChange, 0.0), 0.5) },
            set: { appModel.stableLightIntensityMinimumRelativeChange = min(max($0, 0.0), 0.5) }
        )
    }

    private var stableLightShadowSoftnessMinimumChangeSliderValue: Binding<Float> {
        Binding(
            get: { min(max(appModel.stableLightShadowSoftnessMinimumChange, 0.0), 0.3) },
            set: { appModel.stableLightShadowSoftnessMinimumChange = min(max($0, 0.0), 0.3) }
        )
    }
}
