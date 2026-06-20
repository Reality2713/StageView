import Foundation

/// Literal values used by StageView's generated viewport material assets.
public enum ViewportMaterialValue: Sendable, Equatable {
    case color3(Float, Float, Float)
}

public struct ViewportGridMaterialSpec: Sendable, Equatable {
    public enum Theme: Sendable, Equatable {
        case dark
        case light
    }

    public var theme: Theme
    public var minorSpacing: Float
    public var majorSpacing: Float
    public var minorLineOpacity: Float
    public var majorLineOpacity: Float
    public var axisLineOpacity: Float
    public var baselineFillOpacity: Float
    public var minorThickness: Float
    public var majorThickness: Float
    public var axisThickness: Float
    public var minorDepthFactor: Float
    public var majorDepthFactor: Float
    public var minorThicknessMaximum: Float
    public var majorThicknessMaximum: Float
    public var fadeStart: Float
    public var fadeEnd: Float
    public var fogDensity: Float
    public var fogMaximum: Float
    public var lineOpacityScale: Float
    public var floorHalfExtent: Float
    public var xAxisColor: ViewportMaterialValue
    public var zAxisColor: ViewportMaterialValue
    public var minorColor: ViewportMaterialValue
    public var majorColor: ViewportMaterialValue

    public init(
        theme: Theme = .dark,
        minorSpacing: Float = 0.1,
        majorSpacing: Float = 1.0,
        minorLineOpacity: Float = 0.22,
        majorLineOpacity: Float = 0.50,
        axisLineOpacity: Float = 0.80,
        baselineFillOpacity: Float = 0.03,
        minorThickness: Float = 0.0032,
        majorThickness: Float = 0.0082,
        axisThickness: Float = 0.0102,
        minorDepthFactor: Float = 0.002,
        majorDepthFactor: Float = 0.0017,
        minorThicknessMaximum: Float = 0.016,
        majorThicknessMaximum: Float = 0.032,
        fadeStart: Float = 4.0,
        fadeEnd: Float = 20.0,
        fogDensity: Float = 0.065,
        fogMaximum: Float = 0.90,
        lineOpacityScale: Float = 0.99,
        floorHalfExtent: Float = 8.0,
        xAxisColor: ViewportMaterialValue? = nil,
        zAxisColor: ViewportMaterialValue? = nil,
        minorColor: ViewportMaterialValue? = nil,
        majorColor: ViewportMaterialValue? = nil
    ) {
        self.theme = theme
        self.minorSpacing = minorSpacing
        self.majorSpacing = majorSpacing
        self.minorLineOpacity = minorLineOpacity
        self.majorLineOpacity = majorLineOpacity
        self.axisLineOpacity = axisLineOpacity
        self.baselineFillOpacity = baselineFillOpacity
        self.minorThickness = minorThickness
        self.majorThickness = majorThickness
        self.axisThickness = axisThickness
        self.minorDepthFactor = minorDepthFactor
        self.majorDepthFactor = majorDepthFactor
        self.minorThicknessMaximum = minorThicknessMaximum
        self.majorThicknessMaximum = majorThicknessMaximum
        self.fadeStart = fadeStart
        self.fadeEnd = fadeEnd
        self.fogDensity = fogDensity
        self.fogMaximum = fogMaximum
        self.lineOpacityScale = lineOpacityScale
        self.floorHalfExtent = floorHalfExtent
        self.xAxisColor = xAxisColor ?? Self.defaultXAxisColor(for: theme)
        self.zAxisColor = zAxisColor ?? Self.defaultZAxisColor(for: theme)
        self.minorColor = minorColor ?? Self.defaultMinorColor(for: theme)
        self.majorColor = majorColor ?? Self.defaultMajorColor(for: theme)
    }

    public static func defaultMinorColor(for theme: Theme) -> ViewportMaterialValue {
        switch theme {
        case .dark: return .color3(0.34, 0.37, 0.42)
        case .light: return .color3(0.55, 0.58, 0.62)
        }
    }

    public static func defaultMajorColor(for theme: Theme) -> ViewportMaterialValue {
        switch theme {
        case .dark: return .color3(0.50, 0.53, 0.57)
        case .light: return .color3(0.42, 0.45, 0.49)
        }
    }

    public static func defaultXAxisColor(for theme: Theme) -> ViewportMaterialValue {
        switch theme {
        case .dark: return .color3(0.32, 0.58, 0.87)
        case .light: return .color3(0.33, 0.57, 0.82)
        }
    }

    public static func defaultZAxisColor(for theme: Theme) -> ViewportMaterialValue {
        switch theme {
        case .dark: return .color3(0.72, 0.49, 0.31)
        case .light: return .color3(0.69, 0.48, 0.33)
        }
    }
}

/// Generated viewport USD material asset.
///
/// `StageView` uses this lightweight value to expose the generated USDA text
/// and canonical paths for viewport grid scenes without depending on OpenUSDKit.
public struct GeneratedMaterialAsset: Sendable, Equatable {
    public var name: String
    public var graph: ViewportMaterialGraph
    public var usda: String
    public var defaultSceneFileName: String
    public var defaultPrimPath: String
    public var materialPath: String

    public init(
        name: String,
        graph: ViewportMaterialGraph,
        usda: String,
        defaultSceneFileName: String = "Scene.usda",
        defaultPrimPath: String = "/Root",
        materialPath: String
    ) {
        self.name = name
        self.graph = graph
        self.usda = usda
        self.defaultSceneFileName = defaultSceneFileName
        self.defaultPrimPath = defaultPrimPath
        self.materialPath = materialPath
    }
}

/// Produces a concrete USD asset from a typed material spec.
///
/// Asset recipes are higher-level than graph recipes: they own both graph
/// creation and scene/file emission. Use them for reusable sample assets,
/// renderer fixtures, and examples that need a complete USD file.
public protocol MaterialAssetRecipe: Sendable {
    associatedtype Spec: Sendable

    static var recipeName: String { get }

    func makeAsset(from spec: Spec) throws -> GeneratedMaterialAsset
}

/// Generic disk writer for generated material assets.
///
/// The generator intentionally performs no USD interpretation. It delegates all
/// semantic decisions to a ``MaterialAssetRecipe`` and only handles filesystem
/// creation plus atomic text writing.
public enum MaterialAssetGenerator {
    @discardableResult
    public static func write<R: MaterialAssetRecipe>(
        _ recipe: R,
        spec: R.Spec,
        to outputURL: URL
    ) throws -> GeneratedMaterialAsset {
        let asset = try recipe.makeAsset(from: spec)
        try FileManager.default.createDirectory(
            at: outputURL.deletingLastPathComponent(),
            withIntermediateDirectories: true
        )
        try asset.usda.write(to: outputURL, atomically: true, encoding: .utf8)
        return asset
    }
}

/// Emits the StageView viewport grid as a complete USDA scene.
///
/// This writes a double-sided plane bound to a RealityKit unlit material graph.
public struct ViewportGridMaterialAssetRecipe: MaterialAssetRecipe {
    public static let recipeName = "viewport-grid-asset"

    public init() {}

    public func makeAsset(from spec: ViewportGridMaterialSpec) throws -> GeneratedMaterialAsset {
        let graph = ViewportMaterialGraph.viewportGrid(from: spec)
        let usda = ViewportGridUSDAEmitter.emit(spec: spec)
        return GeneratedMaterialAsset(
            name: "ViewportGrid",
            graph: graph,
            usda: usda,
            materialPath: "/Root/Looks/ViewportGridMaterial"
        )
    }
}

/// Lightweight semantic graph for generated StageView viewport material assets.
public struct ViewportMaterialGraph: Sendable, Equatable {
    public var name: String
    public var parameters: [ViewportMaterialParameter]
    public var surfaceNodeID: String

    public init(
        name: String,
        parameters: [ViewportMaterialParameter],
        surfaceNodeID: String
    ) {
        self.name = name
        self.parameters = parameters
        self.surfaceNodeID = surfaceNodeID
    }

    public static func viewportGrid(from spec: ViewportGridMaterialSpec) -> ViewportMaterialGraph {
        ViewportMaterialGraph(
            name: "ViewportGrid",
            parameters: [
                .init(id: "minorSpacing", value: .float(spec.minorSpacing)),
                .init(id: "majorSpacing", value: .float(spec.majorSpacing)),
                .init(id: "minorThickness", value: .float(spec.minorThickness)),
                .init(id: "majorThickness", value: .float(spec.majorThickness)),
                .init(id: "axisThickness", value: .float(spec.axisThickness)),
                .init(id: "minorLineOpacity", value: .float(spec.minorLineOpacity)),
                .init(id: "majorLineOpacity", value: .float(spec.majorLineOpacity)),
                .init(id: "axisLineOpacity", value: .float(spec.axisLineOpacity)),
                .init(id: "baselineFillOpacity", value: .float(spec.baselineFillOpacity)),
                .init(id: "fadeStart", value: .float(spec.fadeStart)),
                .init(id: "fadeEnd", value: .float(spec.fadeEnd)),
                .init(id: "fogDensity", value: .float(spec.fogDensity)),
                .init(id: "fogMaximum", value: .float(spec.fogMaximum)),
                .init(id: "lineOpacityScale", value: .float(spec.lineOpacityScale)),
                .init(id: "floorHalfExtent", value: .float(spec.floorHalfExtent)),
                .init(id: "minorColor", value: .init(spec.minorColor)),
                .init(id: "majorColor", value: .init(spec.majorColor)),
                .init(id: "xAxisColor", value: .init(spec.xAxisColor)),
                .init(id: "zAxisColor", value: .init(spec.zAxisColor)),
            ],
            surfaceNodeID: "UnlitSurface"
        )
    }
}

public struct ViewportMaterialParameter: Sendable, Equatable {
    public var id: String
    public var value: ViewportMaterialParameterValue

    public init(id: String, value: ViewportMaterialParameterValue) {
        self.id = id
        self.value = value
    }
}

public enum ViewportMaterialParameterValue: Sendable, Equatable {
    case float(Float)
    case color3(Float, Float, Float)

    public init(_ value: ViewportMaterialValue) {
        switch value {
        case .color3(let r, let g, let b):
            self = .color3(r, g, b)
        }
    }
}

private enum ViewportGridUSDAEmitter {
    static func emit(spec: ViewportGridMaterialSpec) -> String {
        let halfExtent = usd(spec.floorHalfExtent)
        let topY = usd(0.0005)
        let bottomY = usd(-0.0005)

        var lines: [String] = []
        lines.append("#usda 1.0")
        lines.append("(")
        lines.append("    customLayerData = {")
        lines.append("        string creator = \"StageView ViewportGridMaterialAssetRecipe\"")
        lines.append("    }")
        lines.append("    defaultPrim = \"Root\"")
        lines.append("    metersPerUnit = 1")
        lines.append("    upAxis = \"Y\"")
        lines.append(")")
        lines.append("")
        lines.append("def Xform \"Root\"")
        lines.append("{")
        lines.append(contentsOf: indentBlock(meshBlock(name: "GridPlaneFront", y: topY, halfExtent: halfExtent, frontFacing: true), by: "    "))
        lines.append("")
        lines.append(contentsOf: indentBlock(meshBlock(name: "GridPlaneBack", y: bottomY, halfExtent: halfExtent, frontFacing: false), by: "    "))
        lines.append("")
        lines.append("    def Scope \"Looks\"")
        lines.append("    {")
        lines.append(contentsOf: indentBlock(materialBlock(spec: spec), by: "        "))
        lines.append("    }")
        lines.append("}")
        lines.append("")
        return lines.joined(separator: "\n")
    }

    private static func indentBlock(_ block: String, by prefix: String) -> [String] {
        block
            .split(separator: "\n", omittingEmptySubsequences: false)
            .map { line in
                line.isEmpty ? "" : prefix + line
            }
    }

    private static func meshBlock(name: String, y: String, halfExtent: String, frontFacing: Bool) -> String {
        let indices = frontFacing ? "[0, 1, 2, 3]" : "[0, 3, 2, 1]"
        let normal = frontFacing ? "(0, 1, 0)" : "(0, -1, 0)"
        return """
def Mesh "\(name)" (
    prepend apiSchemas = ["MaterialBindingAPI"]
)
{
    rel material:binding = </Root/Looks/ViewportGridMaterial>
    int[] faceVertexCounts = [4]
    int[] faceVertexIndices = \(indices)
    normal3f[] normals = [\(normal)] (
        interpolation = "uniform"
    )
    point3f[] points = [(-\(halfExtent), \(y), -\(halfExtent)), (\(halfExtent), \(y), -\(halfExtent)), (\(halfExtent), \(y), \(halfExtent)), (-\(halfExtent), \(y), \(halfExtent))]
    texCoord2f[] primvars:st = [(0, 0), (1, 0), (1, 1), (0, 1)] (
        interpolation = "vertex"
    )
    uniform token subdivisionScheme = "none"
}
"""
    }

    private static func materialBlock(spec: ViewportGridMaterialSpec) -> String {
        var blocks: [String] = []
        blocks.append("""
def Material "ViewportGridMaterial"
{
    token outputs:mtlx:surface.connect = </Root/Looks/ViewportGridMaterial/UnlitSurface.outputs:out>
    token outputs:realitykit:vertex

""")

        blocks.append(shader(
            "UnlitSurface",
            id: "ND_realitykit_unlit_surfaceshader",
            [
                "color3f inputs:color.connect = </Root/Looks/ViewportGridMaterial/LineColor.outputs:out>",
                "float inputs:opacity.connect = </Root/Looks/ViewportGridMaterial/Opacity.outputs:out>",
                "token outputs:out"
            ]
        ))

        blocks.append(shader(
            "WorldPosition",
            id: "ND_position_vector3",
            [
                "string inputs:space = \"world\"",
                "vector3f outputs:out"
            ]
        ))

        blocks.append(shader(
            "WorldPositionChannels",
            id: "ND_separate3_vector3",
            [
                "vector3f inputs:in.connect = </Root/Looks/ViewportGridMaterial/WorldPosition.outputs:out>",
                "float outputs:outx",
                "float outputs:outy",
                "float outputs:outz"
            ]
        ))

        blocks.append(contentsOf: scaledFractionalBlocks(axis: "X", label: "Minor", sourceOutput: "outx", scale: 1 / spec.minorSpacing))
        blocks.append(contentsOf: scaledFractionalBlocks(axis: "Z", label: "Minor", sourceOutput: "outz", scale: 1 / spec.minorSpacing))
        blocks.append(contentsOf: scaledFractionalBlocks(axis: "X", label: "Major", sourceOutput: "outx", scale: 1 / spec.majorSpacing))
        blocks.append(contentsOf: scaledFractionalBlocks(axis: "Z", label: "Major", sourceOutput: "outz", scale: 1 / spec.majorSpacing))

        blocks.append(shader("WorldToView", id: "ND_realitykit_surface_world_to_view", ["matrix44d outputs:worldToView"]))
        blocks.append(shader(
            "ViewPosition",
            id: "ND_transformmatrix_vector3M4",
            [
                "vector3f inputs:in.connect = </Root/Looks/ViewportGridMaterial/WorldPosition.outputs:out>",
                "matrix44d inputs:mat.connect = </Root/Looks/ViewportGridMaterial/WorldToView.outputs:worldToView>",
                "vector3f outputs:out"
            ]
        ))
        blocks.append(shader(
            "ViewPositionChannels",
            id: "ND_separate3_vector3",
            [
                "vector3f inputs:in.connect = </Root/Looks/ViewportGridMaterial/ViewPosition.outputs:out>",
                "float outputs:outx",
                "float outputs:outy",
                "float outputs:outz"
            ]
        ))
        blocks.append(shader(
            "ViewDepth",
            id: "ND_absval_float",
            [
                "float inputs:in.connect = </Root/Looks/ViewportGridMaterial/ViewPositionChannels.outputs:outz>",
                "float outputs:out"
            ]
        ))

        blocks.append(contentsOf: thicknessBlocks(
            label: "Minor",
            baseThickness: spec.minorThickness,
            depthFactor: spec.minorDepthFactor,
            clamp: spec.minorThicknessMaximum
        ))
        blocks.append(contentsOf: thicknessBlocks(
            label: "Major",
            baseThickness: spec.majorThickness,
            depthFactor: spec.majorDepthFactor,
            clamp: spec.majorThicknessMaximum
        ))
        blocks.append(shader(
            "AxisThickness",
            id: "ND_add_float",
            [
                "float inputs:in1.connect = </Root/Looks/ViewportGridMaterial/MajorThickness.outputs:out>",
                "float inputs:in2 = \(usd(spec.axisThickness - spec.majorThickness))",
                "float outputs:out"
            ]
        ))

        blocks.append(contentsOf: stepMaskBlocks(axis: "X", label: "Minor"))
        blocks.append(contentsOf: stepMaskBlocks(axis: "Z", label: "Minor"))
        blocks.append(contentsOf: stepMaskBlocks(axis: "X", label: "Major"))
        blocks.append(contentsOf: stepMaskBlocks(axis: "Z", label: "Major"))

        blocks.append(contentsOf: axisMaskBlocks(axis: "X", sourceOutput: "outx"))
        blocks.append(contentsOf: axisMaskBlocks(axis: "Z", sourceOutput: "outz"))

        blocks.append(shader("MinorGridMask", id: "ND_max_float", [
            "float inputs:in1.connect = </Root/Looks/ViewportGridMaterial/MinorXMask.outputs:out>",
            "float inputs:in2.connect = </Root/Looks/ViewportGridMaterial/MinorZMask.outputs:out>",
            "float outputs:out"
        ]))
        blocks.append(shader("MajorGridMask", id: "ND_max_float", [
            "float inputs:in1.connect = </Root/Looks/ViewportGridMaterial/MajorXMask.outputs:out>",
            "float inputs:in2.connect = </Root/Looks/ViewportGridMaterial/MajorZMask.outputs:out>",
            "float outputs:out"
        ]))

        blocks.append(shader("FogRaw", id: "ND_multiply_float", [
            "float inputs:in1.connect = </Root/Looks/ViewportGridMaterial/ViewDepth.outputs:out>",
            "float inputs:in2 = \(usd(spec.fogDensity))",
            "float outputs:out"
        ]))
        blocks.append(shader("FogAmount", id: "ND_min_float", [
            "float inputs:in1.connect = </Root/Looks/ViewportGridMaterial/FogRaw.outputs:out>",
            "float inputs:in2 = \(usd(spec.fogMaximum))",
            "float outputs:out"
        ]))
        blocks.append(shader("FogFactor", id: "ND_subtract_float", [
            "float inputs:in1 = 1",
            "float inputs:in2.connect = </Root/Looks/ViewportGridMaterial/FogAmount.outputs:out>",
            "float outputs:out"
        ]))

        for name in ["MinorMaskVisible", "MajorMaskVisible", "AxisXVisible", "AxisZVisible"] {
            let source = name.replacingOccurrences(of: "Visible", with: "")
            blocks.append(shader(name, id: "ND_multiply_float", [
                "float inputs:in1.connect = </Root/Looks/ViewportGridMaterial/\(source).outputs:out>",
                "float inputs:in2.connect = </Root/Looks/ViewportGridMaterial/FogFactor.outputs:out>",
                "float outputs:out"
            ]))
        }

        blocks.append(contentsOf: colorBlocks(label: "Minor", maskNode: "MinorMaskVisible", color: spec.minorColor))
        blocks.append(contentsOf: colorBlocks(label: "Major", maskNode: "MajorMaskVisible", color: spec.majorColor))
        blocks.append(contentsOf: axisColorBlocks(axis: "X", maskNode: "AxisXVisible", color: spec.xAxisColor))
        blocks.append(contentsOf: axisColorBlocks(axis: "Z", maskNode: "AxisZVisible", color: spec.zAxisColor))

        blocks.append(shader("RedMinorMajor", id: "ND_add_float", [
            "float inputs:in1.connect = </Root/Looks/ViewportGridMaterial/MinorRed.outputs:out>",
            "float inputs:in2.connect = </Root/Looks/ViewportGridMaterial/MajorRed.outputs:out>",
            "float outputs:out"
        ]))
        blocks.append(shader("GreenMinorMajor", id: "ND_add_float", [
            "float inputs:in1.connect = </Root/Looks/ViewportGridMaterial/MinorGreen.outputs:out>",
            "float inputs:in2.connect = </Root/Looks/ViewportGridMaterial/MajorGreen.outputs:out>",
            "float outputs:out"
        ]))
        blocks.append(shader("BlueMinorMajor", id: "ND_add_float", [
            "float inputs:in1.connect = </Root/Looks/ViewportGridMaterial/MinorBlue.outputs:out>",
            "float inputs:in2.connect = </Root/Looks/ViewportGridMaterial/MajorBlue.outputs:out>",
            "float outputs:out"
        ]))
        blocks.append(shader("RedChannel", id: "ND_add_float", [
            "float inputs:in1.connect = </Root/Looks/ViewportGridMaterial/RedMinorMajor.outputs:out>",
            "float inputs:in2.connect = </Root/Looks/ViewportGridMaterial/AxisZRed.outputs:out>",
            "float outputs:out"
        ]))
        blocks.append(shader("GreenMinorMajorAxisX", id: "ND_add_float", [
            "float inputs:in1.connect = </Root/Looks/ViewportGridMaterial/GreenMinorMajor.outputs:out>",
            "float inputs:in2.connect = </Root/Looks/ViewportGridMaterial/AxisXGreen.outputs:out>",
            "float outputs:out"
        ]))
        blocks.append(shader("GreenChannel", id: "ND_add_float", [
            "float inputs:in1.connect = </Root/Looks/ViewportGridMaterial/GreenMinorMajorAxisX.outputs:out>",
            "float inputs:in2.connect = </Root/Looks/ViewportGridMaterial/AxisZGreen.outputs:out>",
            "float outputs:out"
        ]))
        blocks.append(shader("BlueChannel", id: "ND_add_float", [
            "float inputs:in1.connect = </Root/Looks/ViewportGridMaterial/BlueMinorMajor.outputs:out>",
            "float inputs:in2.connect = </Root/Looks/ViewportGridMaterial/AxisXBlue.outputs:out>",
            "float outputs:out"
        ]))
        blocks.append(shader("LineColor", id: "ND_combine3_color3", [
            "float inputs:in1.connect = </Root/Looks/ViewportGridMaterial/RedChannel.outputs:out>",
            "float inputs:in2.connect = </Root/Looks/ViewportGridMaterial/GreenChannel.outputs:out>",
            "float inputs:in3.connect = </Root/Looks/ViewportGridMaterial/BlueChannel.outputs:out>",
            "color3f outputs:out"
        ]))

        blocks.append(shader("AnyVisibleMinorMajor", id: "ND_max_float", [
            "float inputs:in1.connect = </Root/Looks/ViewportGridMaterial/MinorMaskVisible.outputs:out>",
            "float inputs:in2.connect = </Root/Looks/ViewportGridMaterial/MajorMaskVisible.outputs:out>",
            "float outputs:out"
        ]))
        blocks.append(shader("AnyVisibleAxis", id: "ND_max_float", [
            "float inputs:in1.connect = </Root/Looks/ViewportGridMaterial/AxisXVisible.outputs:out>",
            "float inputs:in2.connect = </Root/Looks/ViewportGridMaterial/AxisZVisible.outputs:out>",
            "float outputs:out"
        ]))
        blocks.append(shader("AnyVisibleLine", id: "ND_max_float", [
            "float inputs:in1.connect = </Root/Looks/ViewportGridMaterial/AnyVisibleMinorMajor.outputs:out>",
            "float inputs:in2.connect = </Root/Looks/ViewportGridMaterial/AnyVisibleAxis.outputs:out>",
            "float outputs:out"
        ]))
        blocks.append(shader("LineOpacityScaled", id: "ND_multiply_float", [
            "float inputs:in1.connect = </Root/Looks/ViewportGridMaterial/AnyVisibleLine.outputs:out>",
            "float inputs:in2 = \(usd(spec.lineOpacityScale))",
            "float outputs:out"
        ]))
        blocks.append(shader("Opacity", id: "ND_add_float", [
            "float inputs:in1 = \(usd(spec.baselineFillOpacity))",
            "float inputs:in2.connect = </Root/Looks/ViewportGridMaterial/LineOpacityScaled.outputs:out>",
            "float outputs:out"
        ]))

        blocks.append("}")
        return blocks.joined(separator: "\n\n")
    }

    private static func scaledFractionalBlocks(axis: String, label: String, sourceOutput: String, scale: Float) -> [String] {
        [
            shader("\(label)\(axis)Scaled", id: "ND_multiply_float", [
                "float inputs:in1.connect = </Root/Looks/ViewportGridMaterial/WorldPositionChannels.outputs:\(sourceOutput)>",
                "float inputs:in2 = \(usd(scale))",
                "float outputs:out"
            ]),
            shader("\(label)\(axis)Fractional", id: "ND_realitykit_fractional_float", [
                "float inputs:in.connect = </Root/Looks/ViewportGridMaterial/\(label)\(axis)Scaled.outputs:out>",
                "float outputs:out"
            ]),
            shader("\(label)\(axis)Inverse", id: "ND_subtract_float", [
                "float inputs:in1 = 1",
                "float inputs:in2.connect = </Root/Looks/ViewportGridMaterial/\(label)\(axis)Fractional.outputs:out>",
                "float outputs:out"
            ])
        ]
    }

    private static func thicknessBlocks(label: String, baseThickness: Float, depthFactor: Float, clamp: Float) -> [String] {
        [
            shader("\(label)DepthThickness", id: "ND_multiply_float", [
                "float inputs:in1.connect = </Root/Looks/ViewportGridMaterial/ViewDepth.outputs:out>",
                "float inputs:in2 = \(usd(depthFactor))",
                "float outputs:out"
            ]),
            shader("\(label)ThicknessUnclamped", id: "ND_add_float", [
                "float inputs:in1 = \(usd(baseThickness))",
                "float inputs:in2.connect = </Root/Looks/ViewportGridMaterial/\(label)DepthThickness.outputs:out>",
                "float outputs:out"
            ]),
            shader("\(label)Thickness", id: "ND_min_float", [
                "float inputs:in1.connect = </Root/Looks/ViewportGridMaterial/\(label)ThicknessUnclamped.outputs:out>",
                "float inputs:in2 = \(usd(clamp))",
                "float outputs:out"
            ])
        ]
    }

    private static func stepMaskBlocks(axis: String, label: String) -> [String] {
        [
            shader("\(label)\(axis)Fwidth", id: "ND_MTL_fwidth_float", [
                "float inputs:p.connect = </Root/Looks/ViewportGridMaterial/\(label)\(axis)Scaled.outputs:out>",
                "float outputs:out"
            ]),
            shader("\(label)\(axis)LowEdge", id: "ND_subtract_float", [
                "float inputs:in1.connect = </Root/Looks/ViewportGridMaterial/\(label)Thickness.outputs:out>",
                "float inputs:in2.connect = </Root/Looks/ViewportGridMaterial/\(label)\(axis)Fwidth.outputs:out>",
                "float outputs:out"
            ]),
            shader("\(label)\(axis)HighEdge", id: "ND_add_float", [
                "float inputs:in1.connect = </Root/Looks/ViewportGridMaterial/\(label)Thickness.outputs:out>",
                "float inputs:in2.connect = </Root/Looks/ViewportGridMaterial/\(label)\(axis)Fwidth.outputs:out>",
                "float outputs:out"
            ]),
            shader("\(label)\(axis)LowStep", id: "ND_smoothstep_float", [
                "float inputs:in.connect = </Root/Looks/ViewportGridMaterial/\(label)\(axis)Fractional.outputs:out>",
                "float inputs:low.connect = </Root/Looks/ViewportGridMaterial/\(label)\(axis)LowEdge.outputs:out>",
                "float inputs:high.connect = </Root/Looks/ViewportGridMaterial/\(label)\(axis)HighEdge.outputs:out>",
                "float outputs:out"
            ]),
            shader("\(label)\(axis)HighStep", id: "ND_smoothstep_float", [
                "float inputs:in.connect = </Root/Looks/ViewportGridMaterial/\(label)\(axis)Inverse.outputs:out>",
                "float inputs:low.connect = </Root/Looks/ViewportGridMaterial/\(label)\(axis)LowEdge.outputs:out>",
                "float inputs:high.connect = </Root/Looks/ViewportGridMaterial/\(label)\(axis)HighEdge.outputs:out>",
                "float outputs:out"
            ]),
            shader("\(label)\(axis)LowMask", id: "ND_subtract_float", [
                "float inputs:in1 = 1",
                "float inputs:in2.connect = </Root/Looks/ViewportGridMaterial/\(label)\(axis)LowStep.outputs:out>",
                "float outputs:out"
            ]),
            shader("\(label)\(axis)HighMask", id: "ND_subtract_float", [
                "float inputs:in1 = 1",
                "float inputs:in2.connect = </Root/Looks/ViewportGridMaterial/\(label)\(axis)HighStep.outputs:out>",
                "float outputs:out"
            ]),
            shader("\(label)\(axis)Mask", id: "ND_max_float", [
                "float inputs:in1.connect = </Root/Looks/ViewportGridMaterial/\(label)\(axis)LowMask.outputs:out>",
                "float inputs:in2.connect = </Root/Looks/ViewportGridMaterial/\(label)\(axis)HighMask.outputs:out>",
                "float outputs:out"
            ])
        ]
    }

    private static func axisMaskBlocks(axis: String, sourceOutput: String) -> [String] {
        [
            shader("Axis\(axis)Abs", id: "ND_absval_float", [
                "float inputs:in.connect = </Root/Looks/ViewportGridMaterial/WorldPositionChannels.outputs:\(sourceOutput)>",
                "float outputs:out"
            ]),
            shader("Axis\(axis)Fwidth", id: "ND_MTL_fwidth_float", [
                "float inputs:p.connect = </Root/Looks/ViewportGridMaterial/WorldPositionChannels.outputs:\(sourceOutput)>",
                "float outputs:out"
            ]),
            shader("Axis\(axis)LowEdge", id: "ND_subtract_float", [
                "float inputs:in1.connect = </Root/Looks/ViewportGridMaterial/AxisThickness.outputs:out>",
                "float inputs:in2.connect = </Root/Looks/ViewportGridMaterial/Axis\(axis)Fwidth.outputs:out>",
                "float outputs:out"
            ]),
            shader("Axis\(axis)HighEdge", id: "ND_add_float", [
                "float inputs:in1.connect = </Root/Looks/ViewportGridMaterial/AxisThickness.outputs:out>",
                "float inputs:in2.connect = </Root/Looks/ViewportGridMaterial/Axis\(axis)Fwidth.outputs:out>",
                "float outputs:out"
            ]),
            shader("Axis\(axis)ThresholdStep", id: "ND_smoothstep_float", [
                "float inputs:in.connect = </Root/Looks/ViewportGridMaterial/Axis\(axis)Abs.outputs:out>",
                "float inputs:low.connect = </Root/Looks/ViewportGridMaterial/Axis\(axis)LowEdge.outputs:out>",
                "float inputs:high.connect = </Root/Looks/ViewportGridMaterial/Axis\(axis)HighEdge.outputs:out>",
                "float outputs:out"
            ]),
            shader("Axis\(axis)Mask", id: "ND_subtract_float", [
                "float inputs:in1 = 1",
                "float inputs:in2.connect = </Root/Looks/ViewportGridMaterial/Axis\(axis)ThresholdStep.outputs:out>",
                "float outputs:out"
            ])
        ]
    }

    private static func colorBlocks(label: String, maskNode: String, color: ViewportMaterialValue) -> [String] {
        let rgb = color3Components(from: color)
        return [
            shader("\(label)Red", id: "ND_multiply_float", [
                "float inputs:in1.connect = </Root/Looks/ViewportGridMaterial/\(maskNode).outputs:out>",
                "float inputs:in2 = \(usd(rgb.0))",
                "float outputs:out"
            ]),
            shader("\(label)Green", id: "ND_multiply_float", [
                "float inputs:in1.connect = </Root/Looks/ViewportGridMaterial/\(maskNode).outputs:out>",
                "float inputs:in2 = \(usd(rgb.1))",
                "float outputs:out"
            ]),
            shader("\(label)Blue", id: "ND_multiply_float", [
                "float inputs:in1.connect = </Root/Looks/ViewportGridMaterial/\(maskNode).outputs:out>",
                "float inputs:in2 = \(usd(rgb.2))",
                "float outputs:out"
            ])
        ]
    }

    private static func axisColorBlocks(axis: String, maskNode: String, color: ViewportMaterialValue) -> [String] {
        let rgb = color3Components(from: color)
        return [
            shader("Axis\(axis)Red", id: "ND_multiply_float", [
                "float inputs:in1.connect = </Root/Looks/ViewportGridMaterial/\(maskNode).outputs:out>",
                "float inputs:in2 = \(usd(rgb.0))",
                "float outputs:out"
            ]),
            shader("Axis\(axis)Green", id: "ND_multiply_float", [
                "float inputs:in1.connect = </Root/Looks/ViewportGridMaterial/\(maskNode).outputs:out>",
                "float inputs:in2 = \(usd(rgb.1))",
                "float outputs:out"
            ]),
            shader("Axis\(axis)Blue", id: "ND_multiply_float", [
                "float inputs:in1.connect = </Root/Looks/ViewportGridMaterial/\(maskNode).outputs:out>",
                "float inputs:in2 = \(usd(rgb.2))",
                "float outputs:out"
            ])
        ]
    }

    private static func shader(_ name: String, id: String, _ body: [String]) -> String {
        let bodyLines = body.map { "    \($0)" }.joined(separator: "\n")
        return """
def Shader "\(name)"
{
    uniform token info:id = "\(id)"
\(bodyLines)
}
"""
    }

    private static func color3Components(from value: ViewportMaterialValue) -> (Float, Float, Float) {
        switch value {
        case .color3(let r, let g, let b):
            return (r, g, b)
        }
    }

    private static func usd(_ value: Float) -> String {
        let number = Double(value)
        if number.rounded() == number {
            return String(format: "%.0f", number)
        }
        return String(format: "%.6f", number)
            .replacingOccurrences(of: #"0+$"#, with: "", options: .regularExpression)
            .replacingOccurrences(of: #"\.$"#, with: "", options: .regularExpression)
    }
}
