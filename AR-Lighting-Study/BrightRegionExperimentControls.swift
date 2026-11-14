//
//  BrightRegionExperimentControls.swift
//  AR-Lighting-Study
//
//  Presents controls for Bright Region analysis presets and estimated-light settings.
//  User changes are written to AppModel and can trigger a new analysis.

import SwiftUI
import Foundation

struct BrightRegionExperimentControls: View {
    @Environment(AppModel.self) private var appModel
    @State private var selectedPresetID: String?
    @State private var dominanceScoreMode = BrightRegionDominanceScoreMode.totalLuminance
    @State private var distanceScoreMode = BrightRegionDistanceScoreMode.off
    @State private var directionMode = BrightRegionDirectionMode.luminanceWeighted
    @State private var colorMode = BrightRegionColorMode.average
    @State private var lightSourceOriginMode = BrightRegionLightSourceOriginMode.geometryHitOrSceneProbe
    @State private var isGeometryIgnored = false
    @State private var isHeightPriorEnabled = false
    @State private var shadowSoftnessMode = BrightRegionShadowSoftnessMode.both
    @State private var estimatedLightWhiteMix: Float = 0.7
    @State private var estimatedDirectionalLightLuxMultiplier: Float = 1

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            VStack(alignment: .leading, spacing: 6) {
                Text("Lichtset")
                    .font(.caption)
                    .foregroundStyle(.secondary)

                HStack(spacing: 8) {
                    Picker("Lichtset", selection: $selectedPresetID) {
                        ForEach(BrightRegionTestPreset.all) { preset in
                            Text(preset.title).tag(Optional(preset.id))
                        }
                        Text("Other").tag(String?.none)
                    }

                    Button("Anwenden") {
                        applySelectedPreset()
                    }
                    .buttonStyle(.borderedProminent)
                    .disabled(selectedPresetID == nil)
                }

                if let selectedPreset {
                    Text(presetSummary(selectedPreset))
                        .font(.caption.monospaced())
                        .foregroundStyle(.secondary)
                        .lineLimit(2)
                }
            }
            .padding(.bottom, 6)

            Text("Lichtmodell")
                .font(.caption)
                .foregroundStyle(.secondary)

            Picker("Dominanz", selection: $dominanceScoreMode) {
                ForEach(BrightRegionDominanceScoreMode.allCases) { mode in
                    Text(mode.title).tag(mode)
                }
            }
            .pickerStyle(.segmented)

            Picker("Distance", selection: $distanceScoreMode) {
                ForEach(BrightRegionDistanceScoreMode.allCases) { mode in
                    Text(mode.title).tag(mode)
                }
            }
            .pickerStyle(.segmented)

            Picker("Richtung", selection: $directionMode) {
                ForEach(BrightRegionDirectionMode.allCases) { mode in
                    Text(mode.title).tag(mode)
                }
            }
            .pickerStyle(.segmented)

            Picker("Farbe", selection: $colorMode) {
                ForEach(BrightRegionColorMode.allCases) { mode in
                    Text(mode.title).tag(mode)
                }
            }
            .pickerStyle(.segmented)

            Picker("Ursprung", selection: $lightSourceOriginMode) {
                ForEach(BrightRegionLightSourceOriginMode.allCases) { mode in
                    Text(mode.title).tag(mode)
                }
            }
            .pickerStyle(.segmented)

            Toggle("Geometrie ignorieren", isOn: $isGeometryIgnored)
                .toggleStyle(.switch)

            Toggle("Hoehenprior", isOn: $isHeightPriorEnabled)
                .toggleStyle(.switch)

            VStack(alignment: .leading, spacing: 4) {
                HStack {
                    Text("Weiss-Mischung")
                    Spacer()
                    Text("\(Int((estimatedLightWhiteMix * 100).rounded()))%")
                        .font(.callout.monospacedDigit())
                }

                Slider(
                    value: estimatedLightWhiteMixSliderValue,
                    in: 0...1,
                    step: 0.05
                )

                HStack {
                    Text("Farbe")
                    Spacer()
                    Text("Neutral")
                    Spacer()
                    Text("Weiss")
                }
                .font(.caption2.monospacedDigit())
                .foregroundStyle(.secondary)
            }

            Picker("Schattenweichheit", selection: $shadowSoftnessMode) {
                    ForEach(BrightRegionShadowSoftnessMode.allCases) { mode in
                        Text(mode.title).tag(mode)
                    }
                }
            .pickerStyle(.segmented)

            VStack(alignment: .leading, spacing: 4) {
                HStack {
                    Text("Geschaetztes Licht")
                    Spacer()
                    Text("\(estimatedDirectionalLightLuxMultiplier, format: .number.precision(.fractionLength(2)))x")
                        .font(.callout.monospacedDigit())
                }

                Slider(
                    value: estimatedDirectionalLightLuxMultiplierSliderValue,
                    in: -1...log10(20)
                )

                HStack {
                    Text("0.1x")
                    Spacer()
                    Text("1x")
                    Spacer()
                    Text("20x")
                }
                .font(.caption2.monospacedDigit())
                .foregroundStyle(.secondary)

                Text(
                    "Basis \(Int(appModel.brightRegionEstimatedDirectionalLightLux.rounded())) lux | angepasst \(Int(appModel.brightRegionAdjustedDirectionalLightLux.rounded())) lux"
                )
                .font(.caption.monospacedDigit())
                .foregroundStyle(.secondary)
            }

            Button("Änderungen anwenden") {
                applyCurrentLightModelSettings()
            }
            .buttonStyle(.borderedProminent)

            HStack(spacing: 8) {
                Button("Licht neu schaetzen") {
                    appModel.environmentProbeReader.recomputeEstimatedLight(appModel: appModel)
                }
                .buttonStyle(.borderedProminent)
                .disabled(!appModel.canRecomputeBrightRegionLight || appModel.isSequentialLightUpdateRunning)

                Button(appModel.isSequentialLightUpdateRunning ? "Sequenz stoppen" : "1 Hz Sequenz starten") {
                    toggleSequentialLightUpdates()
                }
                .buttonStyle(.bordered)
                .disabled(!appModel.hasEnvironmentProbeTexture && !appModel.isSequentialLightUpdateRunning)

                Text("\(appModel.brightRegionDominanceScoreMode.title) | Distance: \(appModel.brightRegionDistanceScoreMode.title) | \(appModel.brightRegionDirectionMode.title) | Farbe: \(appModel.brightRegionColorMode.title) | \(appModel.brightRegionLightSourceOriginMode.title)")
                    .font(.caption.monospaced())
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
            }

            Text(appModel.sequentialLightUpdateStatus)
                .font(.caption.monospacedDigit())
                .foregroundStyle(appModel.isSequentialLightUpdateRunning ? .primary : .secondary)

        }
        .onAppear {
            loadFromAppModel()
        }
        .onChange(of: appModel.activeBrightRegionTestPresetID) { _, newValue in
            selectedPresetID = newValue
            loadFromAppModel()
        }
    }

    private var estimatedDirectionalLightLuxMultiplierSliderValue: Binding<Double> {
        Binding(
            get: {
                log10(Double(max(estimatedDirectionalLightLuxMultiplier, 0.1)))
            },
            set: { value in
                estimatedDirectionalLightLuxMultiplier = Float(pow(10, value))
            }
        )
    }

    private var estimatedLightWhiteMixSliderValue: Binding<Double> {
        Binding(
            get: {
                Double(min(max(estimatedLightWhiteMix, 0), 1))
            },
            set: { value in
                estimatedLightWhiteMix = Float(min(max(value, 0), 1))
            }
        )
    }

    private var selectedPreset: BrightRegionTestPreset? {
        BrightRegionTestPreset.all.first { $0.id == selectedPresetID }
    }

    private func applySelectedPreset() {
        guard let selectedPreset else { return }

        appModel.applyBrightRegionTestPreset(selectedPreset)
        appModel.restartEstimatedLightWarmupUpdatesIfNeeded()
        loadFromAppModel()
        recomputeCurrentProbe()
    }

    private func applyCurrentLightModelSettings() {
        appModel.brightRegionDominanceScoreMode = dominanceScoreMode
        appModel.brightRegionDistanceScoreMode = distanceScoreMode
        appModel.brightRegionDirectionMode = directionMode
        appModel.brightRegionColorMode = colorMode
        appModel.brightRegionLightSourceOriginMode = lightSourceOriginMode
        appModel.isBrightRegionGeometryIgnored = isGeometryIgnored
        appModel.isBrightRegionHeightPriorEnabled = isHeightPriorEnabled
        appModel.brightRegionShadowSoftnessMode = shadowSoftnessMode
        appModel.brightRegionEstimatedLightWhiteMix = estimatedLightWhiteMix
        appModel.brightRegionEstimatedDirectionalLightLuxMultiplier = estimatedDirectionalLightLuxMultiplier
        appModel.usesFixedDirectionalShadowOrthographicScale = shadowSoftnessMode == .orthographicScale
        if shadowSoftnessMode == .orthographicScale {
            appModel.brightRegionEstimatedLightShadowProjectionMode = .fixed
        }
        appModel.markBrightRegionTestPresetAsCustom()
        appModel.resetEstimatedLightWarmupFreeze()
        appModel.restartEstimatedLightWarmupUpdatesIfNeeded()
        recomputeCurrentProbe()
    }

    private func recomputeCurrentProbe() {
        if appModel.isSequentialLightUpdateRunning {
            appModel.brightRegionMaskStatus = "Änderungen übernommen; die laufende Sequenz verwendet sie beim nächsten Update."
        } else if appModel.canRecomputeBrightRegionLight {
            appModel.environmentProbeReader.recomputeEstimatedLight(appModel: appModel)
        } else if appModel.hasEnvironmentProbeTexture {
            appModel.environmentProbeReader.refreshEnvironmentProbeAnalysis(appModel: appModel)
        } else {
            appModel.brightRegionMaskStatus = "Änderungen übernommen; für die Neuberechnung wird eine Environment Probe benötigt."
        }
    }

    private func loadFromAppModel() {
        selectedPresetID = appModel.activeBrightRegionTestPresetID
        dominanceScoreMode = appModel.brightRegionDominanceScoreMode
        distanceScoreMode = appModel.brightRegionDistanceScoreMode
        directionMode = appModel.brightRegionDirectionMode
        colorMode = appModel.brightRegionColorMode
        lightSourceOriginMode = appModel.brightRegionLightSourceOriginMode
        isGeometryIgnored = appModel.isBrightRegionGeometryIgnored
        isHeightPriorEnabled = appModel.isBrightRegionHeightPriorEnabled
        shadowSoftnessMode = appModel.brightRegionShadowSoftnessMode
        estimatedLightWhiteMix = appModel.brightRegionEstimatedLightWhiteMix
        estimatedDirectionalLightLuxMultiplier = appModel.brightRegionEstimatedDirectionalLightLuxMultiplier
    }

    private func presetSummary(_ preset: BrightRegionTestPreset) -> String {
        let lightDescription = preset.lightSummary
        return "\(preset.dominanceScoreMode.title) | Distance: \(preset.distanceScoreMode.title) | Geom: \(preset.ignoresGeometry ? "aus" : "an") | Weiss \(Int((preset.whiteMix * 100).rounded()))% | \(lightDescription)"
    }

    private func toggleSequentialLightUpdates() {
        if appModel.isSequentialLightUpdateRunning {
            appModel.environmentProbeReader.stopSequentialLightUpdates(appModel: appModel)
        } else {
            appModel.environmentProbeReader.startSequentialLightUpdates(appModel: appModel, interval: .seconds(1))
        }
    }

    private func restartSequentialLightUpdates(interval: Duration) {
        appModel.environmentProbeReader.stopSequentialLightUpdates(appModel: appModel)
        Task { @MainActor in
            try? await Task.sleep(for: .milliseconds(80))
            appModel.environmentProbeReader.startSequentialLightUpdates(appModel: appModel, interval: interval)
        }
    }

}

struct EstimatedLightTuningWindow: View {
    @Environment(AppModel.self) private var appModel
    @State private var selectedPresetID: String?
    @State private var lightType = BrightRegionEstimatedLightType.directional
    @State private var directionalLightCount = 1
    @State private var castsOnlyDominantDirectionalShadow = true
    @State private var projectionMode = BrightRegionShadowProjectionMode.fixed
    @State private var maximumDistance: Float = 5
    @State private var depthBias: Float = 0.8
    @State private var fixedZNear: Float = 0.1
    @State private var fixedZFar: Float = 8
    @State private var fixedOrthographicScale: Float = 4
    @State private var spotInnerAngleInDegrees: Float = 35
    @State private var spotOuterAngleInDegrees: Float = 155
    @State private var spotAttenuationRadius: Float = 8
    @State private var spotAttenuationFalloffExponent: Float = 0.5
    @State private var spotDepthBias: Float = 0.8
    @State private var spotLightCount = 1
    @State private var castsOnlyDominantSpotShadow = true
    @State private var spotIntensityDistributionMode = BrightRegionSpotLightIntensityDistributionMode.dividedByLightCount
    @State private var isSpotLightShadowPositionClampEnabled = true
    @State private var spotLightShadowPositionMaxDistance: Float = 2.5

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            HStack {
                VStack(alignment: .leading, spacing: 4) {
                    Text("Licht-Menue")
                        .font(.title2)
                        .fontWeight(.semibold)

                    Text(currentSummary)
                        .font(.caption.monospacedDigit())
                        .foregroundStyle(.secondary)
                }

                Spacer()
            }

            VStack(alignment: .leading, spacing: 6) {
                Text("Lichtset")
                    .font(.caption)
                    .foregroundStyle(.secondary)

                HStack(spacing: 8) {
                    Picker("Lichtset", selection: $selectedPresetID) {
                        ForEach(BrightRegionTestPreset.all) { preset in
                            Text(preset.title).tag(Optional(preset.id))
                        }
                        Text("Other").tag(String?.none)
                    }

                    Button("Anwenden") {
                        applySelectedPreset()
                    }
                    .buttonStyle(.borderedProminent)
                    .disabled(selectedPresetID == nil)
                }
            }

            Picker("Lichttyp", selection: $lightType) {
                ForEach(BrightRegionEstimatedLightType.allCases) { type in
                    Text(type.title).tag(type)
                }
            }
            .pickerStyle(.segmented)

            VStack(alignment: .leading, spacing: 12) {
                switch lightType {
                case .directional:
                    directionalControls
                case .spot:
                    spotControls
                }
            }

            HStack(spacing: 8) {
                Button("Aktuelle Werte laden") {
                    loadFromAppModel()
                }
                .buttonStyle(.bordered)

                Spacer()

                Button("Bestaetigen") {
                    applyToAppModel()
                }
                .buttonStyle(.borderedProminent)
            }
        }
        .frame(width: 460, alignment: .topLeading)
        .padding(24)
        .onAppear {
            loadFromAppModel()
        }
        .onChange(of: appModel.activeBrightRegionTestPresetID) { _, newValue in
            selectedPresetID = newValue
        }
    }

    @ViewBuilder
    private var directionalControls: some View {
        Picker("Anzahl Lichter", selection: $directionalLightCount) {
            ForEach(1...4, id: \.self) { count in
                Text("\(count)").tag(count)
            }
        }
        .pickerStyle(.segmented)

        Toggle("Nur dominante Schatten", isOn: $castsOnlyDominantDirectionalShadow)
            .toggleStyle(.switch)

        Picker("Shadow Projection", selection: $projectionMode) {
            ForEach(BrightRegionShadowProjectionMode.allCases) { mode in
                Text(mode.title).tag(mode)
            }
        }
        .pickerStyle(.segmented)

        TuningSlider(
            title: "Depth Bias",
            value: $depthBias,
            range: 0...2,
            step: 0.05,
            fractionLength: 2
        )

        switch projectionMode {
        case .automatic:
            TuningSlider(
                title: "Maximum Distance",
                value: $maximumDistance,
                range: 0.5...20,
                step: 0.5,
                fractionLength: 1,
                suffix: "m"
            )
        case .fixed:
            TuningSlider(
                title: "Z Near",
                value: $fixedZNear,
                range: 0.01...2,
                step: 0.01,
                fractionLength: 2,
                suffix: "m"
            )

            TuningSlider(
                title: "Z Far",
                value: $fixedZFar,
                range: 1...30,
                step: 0.5,
                fractionLength: 1,
                suffix: "m"
            )

            TuningSlider(
                title: "Orthographic Scale",
                value: $fixedOrthographicScale,
                range: 0.5...12,
                step: 0.25,
                fractionLength: 2
            )
        }
    }

    private var spotControls: some View {
        VStack(alignment: .leading, spacing: 12) {
            Picker("Anzahl Lichter", selection: $spotLightCount) {
                ForEach(1...4, id: \.self) { count in
                    Text("\(count)").tag(count)
                }
            }
            .pickerStyle(.segmented)

            Toggle("Nur dominante Schatten", isOn: $castsOnlyDominantSpotShadow)
                .toggleStyle(.switch)

            Toggle("Spot-Position begrenzen", isOn: $isSpotLightShadowPositionClampEnabled)
                .toggleStyle(.switch)

            TuningSlider(
                title: "Max. Spot-Abstand",
                value: $spotLightShadowPositionMaxDistance,
                range: 0.5...8.0,
                step: 0.1,
                fractionLength: 1,
                suffix: "m"
            )
            .disabled(!isSpotLightShadowPositionClampEnabled)

            Picker("Intensitaet", selection: $spotIntensityDistributionMode) {
                ForEach(BrightRegionSpotLightIntensityDistributionMode.allCases) { mode in
                    Text(mode.title).tag(mode)
                }
            }
            .pickerStyle(.segmented)

            TuningSlider(
                title: "Inner Angle",
                value: $spotInnerAngleInDegrees,
                range: 1...120,
                step: 1,
                fractionLength: 0,
                suffix: " deg"
            )

            TuningSlider(
                title: "Outer Angle",
                value: $spotOuterAngleInDegrees,
                range: 1...160,
                step: 1,
                fractionLength: 0,
                suffix: " deg"
            )

            TuningSlider(
                title: "Attenuation Radius",
                value: $spotAttenuationRadius,
                range: 0.2...12,
                step: 0.1,
                fractionLength: 1,
                suffix: "m"
            )

            TuningSlider(
                title: "Falloff Exponent",
                value: $spotAttenuationFalloffExponent,
                range: 0.1...6,
                step: 0.1,
                fractionLength: 1
            )

            TuningSlider(
                title: "Depth Bias",
                value: $spotDepthBias,
                range: 0...2,
                step: 0.05,
                fractionLength: 2
            )
        }
    }

    private var currentSummary: String {
        switch appModel.brightRegionEstimatedLightType {
        case .directional:
            switch appModel.brightRegionEstimatedLightShadowProjectionMode {
            case .automatic:
                "Live: Directional x\(appModel.brightRegionEstimatedDirectionalLightCount) | Automatic | max \(appModel.brightRegionEstimatedLightShadowMaximumDistance.formatted(.number.precision(.fractionLength(1)))) | bias \(appModel.brightRegionEstimatedLightShadowDepthBias.formatted(.number.precision(.fractionLength(2))))"
            case .fixed:
                "Live: Directional x\(appModel.brightRegionEstimatedDirectionalLightCount) | Fixed | near \(appModel.brightRegionEstimatedLightShadowFixedZNear.formatted(.number.precision(.fractionLength(2)))) | far \(appModel.brightRegionEstimatedLightShadowFixedZFar.formatted(.number.precision(.fractionLength(1)))) | scale \(appModel.brightRegionEstimatedLightShadowFixedOrthographicScale.formatted(.number.precision(.fractionLength(2)))) | bias \(appModel.brightRegionEstimatedLightShadowDepthBias.formatted(.number.precision(.fractionLength(2))))"
            }
        case .spot:
            "Live: Spot x\(appModel.brightRegionEstimatedSpotLightCount) | inner \(appModel.brightRegionEstimatedSpotLightInnerAngleInDegrees.formatted(.number.precision(.fractionLength(0)))) | outer \(appModel.brightRegionEstimatedSpotLightOuterAngleInDegrees.formatted(.number.precision(.fractionLength(0)))) | radius \(appModel.brightRegionEstimatedSpotLightAttenuationRadius.formatted(.number.precision(.fractionLength(1)))) | falloff \(appModel.brightRegionEstimatedSpotLightAttenuationFalloffExponent.formatted(.number.precision(.fractionLength(1)))) | bias \(appModel.brightRegionEstimatedSpotLightDepthBias.formatted(.number.precision(.fractionLength(2))))"
        }
    }

    private func loadFromAppModel() {
        selectedPresetID = appModel.activeBrightRegionTestPresetID
        lightType = appModel.brightRegionEstimatedLightType
        directionalLightCount = appModel.brightRegionEstimatedDirectionalLightCount
        castsOnlyDominantDirectionalShadow = appModel.castsOnlyDominantEstimatedDirectionalLightShadow
        projectionMode = appModel.brightRegionEstimatedLightShadowProjectionMode
        maximumDistance = appModel.brightRegionEstimatedLightShadowMaximumDistance
        depthBias = appModel.brightRegionEstimatedLightShadowDepthBias
        fixedZNear = appModel.brightRegionEstimatedLightShadowFixedZNear
        fixedZFar = appModel.brightRegionEstimatedLightShadowFixedZFar
        fixedOrthographicScale = appModel.brightRegionEstimatedLightShadowFixedOrthographicScale
        spotInnerAngleInDegrees = appModel.brightRegionEstimatedSpotLightInnerAngleInDegrees
        spotOuterAngleInDegrees = appModel.brightRegionEstimatedSpotLightOuterAngleInDegrees
        spotAttenuationRadius = appModel.brightRegionEstimatedSpotLightAttenuationRadius
        spotAttenuationFalloffExponent = appModel.brightRegionEstimatedSpotLightAttenuationFalloffExponent
        spotDepthBias = appModel.brightRegionEstimatedSpotLightDepthBias
        spotLightCount = appModel.brightRegionEstimatedSpotLightCount
        castsOnlyDominantSpotShadow = appModel.castsOnlyDominantEstimatedSpotLightShadow
        spotIntensityDistributionMode = appModel.brightRegionSpotLightIntensityDistributionMode
        isSpotLightShadowPositionClampEnabled = appModel.isEstimatedSpotLightShadowPositionClampEnabled
        spotLightShadowPositionMaxDistance = appModel.estimatedSpotLightShadowPositionMaxDistance
    }

    private func applyToAppModel() {
        let sanitizedZNear = min(fixedZNear, fixedZFar - 0.01)
        let sanitizedZFar = max(fixedZFar, sanitizedZNear + 0.01)
        let sanitizedSpotInnerAngle = min(spotInnerAngleInDegrees, spotOuterAngleInDegrees - 1)
        let sanitizedSpotOuterAngle = max(spotOuterAngleInDegrees, sanitizedSpotInnerAngle + 1)

        appModel.brightRegionEstimatedLightType = lightType
        appModel.brightRegionEstimatedDirectionalLightCount = min(max(directionalLightCount, 1), 4)
        appModel.castsOnlyDominantEstimatedDirectionalLightShadow = castsOnlyDominantDirectionalShadow
        appModel.brightRegionEstimatedLightShadowProjectionMode = projectionMode
        appModel.brightRegionEstimatedLightShadowMaximumDistance = maximumDistance
        appModel.brightRegionEstimatedLightShadowDepthBias = depthBias
        appModel.brightRegionEstimatedLightShadowFixedZNear = sanitizedZNear
        appModel.brightRegionEstimatedLightShadowFixedZFar = sanitizedZFar
        appModel.brightRegionEstimatedLightShadowFixedOrthographicScale = fixedOrthographicScale
        if appModel.brightRegionShadowSoftnessMode == .orthographicScale {
            appModel.usesFixedDirectionalShadowOrthographicScale = true
        }
        appModel.brightRegionEstimatedSpotLightInnerAngleInDegrees = sanitizedSpotInnerAngle
        appModel.brightRegionEstimatedSpotLightOuterAngleInDegrees = sanitizedSpotOuterAngle
        appModel.brightRegionEstimatedSpotLightAttenuationRadius = spotAttenuationRadius
        appModel.brightRegionEstimatedSpotLightAttenuationFalloffExponent = spotAttenuationFalloffExponent
        appModel.brightRegionEstimatedSpotLightDepthBias = spotDepthBias
        appModel.brightRegionEstimatedSpotLightCount = min(max(spotLightCount, 1), 4)
        appModel.castsOnlyDominantEstimatedSpotLightShadow = castsOnlyDominantSpotShadow
        appModel.brightRegionSpotLightIntensityDistributionMode = spotIntensityDistributionMode
        appModel.isEstimatedSpotLightShadowPositionClampEnabled = isSpotLightShadowPositionClampEnabled
        appModel.estimatedSpotLightShadowPositionMaxDistance = spotLightShadowPositionMaxDistance
        appModel.markBrightRegionTestPresetAsCustom()
    }

    private var selectedPreset: BrightRegionTestPreset? {
        BrightRegionTestPreset.all.first { $0.id == selectedPresetID }
    }

    private func applySelectedPreset() {
        guard let selectedPreset else { return }

        appModel.applyBrightRegionTestPreset(selectedPreset)
        appModel.restartEstimatedLightWarmupUpdatesIfNeeded()
        loadFromAppModel()
        if appModel.canRecomputeBrightRegionLight {
            appModel.environmentProbeReader.recomputeEstimatedLight(appModel: appModel)
        }
    }
}

private struct TuningSlider: View {
    let title: String
    @Binding var value: Float
    let range: ClosedRange<Float>
    let step: Float
    let fractionLength: Int
    let suffix: String

    init(
        title: String,
        value: Binding<Float>,
        range: ClosedRange<Float>,
        step: Float,
        fractionLength: Int,
        suffix: String = ""
    ) {
        self.title = title
        self._value = value
        self.range = range
        self.step = step
        self.fractionLength = fractionLength
        self.suffix = suffix
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            HStack {
                Text(title)
                Spacer()
                Text("\(value.formatted(.number.precision(.fractionLength(fractionLength))))\(suffix)")
                    .font(.callout.monospacedDigit())
            }

            Slider(
                value: Binding(
                    get: { Double(value) },
                    set: { value = Float($0) }
                ),
                in: Double(range.lowerBound)...Double(range.upperBound),
                step: Double(step)
            )
        }
    }
}
