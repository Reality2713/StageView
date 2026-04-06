import Foundation
import SwiftUI
import simd

// MARK: - Anchored Overlay API (New)

/// The primary entry point for viewport overlay configuration.
///
/// Use `ViewportOverlayCollection` to declaratively specify which overlays appear
/// and where they are anchored. Built-ins and external accessories participate
/// in the same coordinated layout surface.
///
/// Example:
/// ```swift
/// let overlays = ViewportOverlayCollection()
///     .orientationGizmo(anchor: .bottomLeading)
///     .scaleIndicator(anchor: .top)
///     .hostAccessory(anchor: .topLeading)
/// ```
public typealias ViewportOverlayConfiguration = ViewportOverlayCollection

// MARK: - Built-in Components

public struct DynamicScaleReference: Equatable {
	public let meters: Double
	public let label: String
	public let barWidthPoints: Double

	public init(meters: Double, label: String, barWidthPoints: Double) {
		self.meters = meters
		self.label = label
		self.barWidthPoints = barWidthPoints
	}

	public static func compute(
		referenceDepthMeters: Double,
		horizontalFOVDegrees: Double,
		viewportWidthPoints: Double,
		barWidthPoints: Double,
		minBarWidthPoints: Double = 56,
		maxBarWidthPoints: Double = 132
	) -> DynamicScaleReference? {
		guard referenceDepthMeters.isFinite, referenceDepthMeters > 0 else {
			return nil
		}
		guard horizontalFOVDegrees.isFinite, horizontalFOVDegrees > 1,
			horizontalFOVDegrees < 179
		else { return nil }
		guard viewportWidthPoints.isFinite, viewportWidthPoints > 1 else {
			return nil
		}
		guard barWidthPoints.isFinite, barWidthPoints > 1 else { return nil }
		guard minBarWidthPoints.isFinite, minBarWidthPoints > 1 else { return nil }
		guard maxBarWidthPoints.isFinite, maxBarWidthPoints >= minBarWidthPoints else {
			return nil
		}

		let fovRadians = horizontalFOVDegrees * .pi / 180.0
		let visibleWidthMeters = 2.0 * referenceDepthMeters * tan(fovRadians / 2.0)
		guard visibleWidthMeters.isFinite, visibleWidthMeters > 0 else {
			return nil
		}

		let metersPerPoint = visibleWidthMeters / viewportWidthPoints
		guard metersPerPoint.isFinite, metersPerPoint > 0 else { return nil }

		let targetMeters = metersPerPoint * barWidthPoints
		guard targetMeters.isFinite, targetMeters > 0 else { return nil }

		let snappedMeters = snappedMetricStep(
			near: targetMeters,
			metersPerPoint: metersPerPoint,
			preferredBarWidthPoints: barWidthPoints,
			minBarWidthPoints: minBarWidthPoints,
			maxBarWidthPoints: maxBarWidthPoints
		)
		let resolvedBarWidthPoints = snappedMeters / metersPerPoint
		guard resolvedBarWidthPoints.isFinite, resolvedBarWidthPoints > 0 else {
			return nil
		}

		return .init(
			meters: snappedMeters,
			label: formatMetric(snappedMeters),
			barWidthPoints: resolvedBarWidthPoints
		)
	}

	private static func snappedMetricStep(
		near targetMeters: Double,
		metersPerPoint: Double,
		preferredBarWidthPoints: Double,
		minBarWidthPoints: Double,
		maxBarWidthPoints: Double
	) -> Double {
		let candidates = niceMetricCandidates(around: targetMeters)
		let boundedCandidates = candidates.filter { candidate in
			let width = candidate / metersPerPoint
			return width >= minBarWidthPoints && width <= maxBarWidthPoints
		}
		let pool = boundedCandidates.isEmpty ? candidates : boundedCandidates
		return pool.min { lhs, rhs in
			let lhsDistance = Swift.abs((lhs / metersPerPoint) - preferredBarWidthPoints)
			let rhsDistance = Swift.abs((rhs / metersPerPoint) - preferredBarWidthPoints)
			if lhsDistance == rhsDistance {
				return lhs < rhs
			}
			return lhsDistance < rhsDistance
		} ?? snapToNiceMetricStep(targetMeters)
	}

	private static func niceMetricCandidates(around value: Double) -> [Double] {
		let clamped = min(1_000_000.0, max(0.000_001, value))
		let exponent = Int(floor(log10(clamped)))
		let multipliers: [Double] = [1, 2, 5]
		return (-2...2)
			.flatMap { offset -> [Double] in
				let magnitude = pow(10.0, Double(exponent + offset))
				return multipliers.map { $0 * magnitude }
			}
			.sorted()
	}

	private static func snapToNiceMetricStep(_ value: Double) -> Double {
		let clamped = min(1_000_000.0, max(0.000_001, value))
		let exponent = floor(log10(clamped))
		let magnitude = pow(10.0, exponent)
		let normalized = clamped / magnitude
		let candidates: [Double] = [1, 2, 5, 10]
		let nearest =
			candidates.min { lhs, rhs in
				Swift.abs(lhs - normalized) < Swift.abs(rhs - normalized)
			} ?? 1.0
		return nearest * magnitude
	}

	private static func formatMetric(_ meters: Double) -> String {
		let value: Double
		let unit: String
		if meters < 0.01 {
			value = meters * 1000
			unit = "mm"
		} else if meters < 1.0 {
			value = meters * 100
			unit = "cm"
		} else if meters < 1000 {
			value = meters
			unit = "m"
		} else {
			value = meters / 1000
			unit = "km"
		}
		return "\(compact(value))\(unit)"
	}

	private static func compact(_ value: Double) -> String {
		if value >= 100 || Swift.abs(value.rounded() - value) < 0.001 {
			return String(format: "%.0f", value)
		}
		if value >= 10 {
			return String(format: "%.1f", value)
		}
		return String(format: "%.2f", value)
			.replacingOccurrences(
				of: #"(\.\d*?)0+$"#,
				with: "$1",
				options: .regularExpression
			)
			.replacingOccurrences(of: #"\.$"#, with: "", options: .regularExpression)
	}
}

public struct StageViewBuiltInOverlayVisibility {
	public var showsOrientationGizmo: Bool
	public var showsScaleIndicator: Bool

	public init(
		showsOrientationGizmo: Bool = true,
		showsScaleIndicator: Bool = true
	) {
		self.showsOrientationGizmo = showsOrientationGizmo
		self.showsScaleIndicator = showsScaleIndicator
	}
}

public struct StageViewOverlaySnapshot {
	public var builtInVisibility: StageViewBuiltInOverlayVisibility
	public var cameraRotation: simd_quatf?
	public var horizontalFOVDegrees: Double
	public var isZUp: Bool
	public var referenceDepthMeters: Double?

	public init(
		builtInVisibility: StageViewBuiltInOverlayVisibility = .init(),
		cameraRotation: simd_quatf? = nil,
		horizontalFOVDegrees: Double = 60,
		isZUp: Bool = false,
		referenceDepthMeters: Double? = nil
	) {
		self.builtInVisibility = builtInVisibility
		self.cameraRotation = cameraRotation
		self.horizontalFOVDegrees = horizontalFOVDegrees
		self.isZUp = isZUp
		self.referenceDepthMeters = referenceDepthMeters
	}

	public var showsBuiltInContent: Bool {
		builtInVisibility.showsOrientationGizmo
			|| builtInVisibility.showsScaleIndicator
	}
}

public struct ScaleIndicatorView: View {
	let referenceDepthMeters: Double
	let viewportWidthPoints: Double
	let barWidth: Double
	let horizontalFOVDegrees: Double

	public init(
		referenceDepthMeters: Double,
		viewportWidthPoints: Double,
		barWidth: Double = 88,
		horizontalFOVDegrees: Double = 60
	) {
		self.referenceDepthMeters = referenceDepthMeters
		self.viewportWidthPoints = viewportWidthPoints
		self.barWidth = barWidth
		self.horizontalFOVDegrees = horizontalFOVDegrees
	}

	public var body: some View {
		if let scale = DynamicScaleReference.compute(
			referenceDepthMeters: referenceDepthMeters,
			horizontalFOVDegrees: horizontalFOVDegrees,
			viewportWidthPoints: viewportWidthPoints,
			barWidthPoints: barWidth
		) {
			VStack(spacing: 3) {
				Text(scale.label)
					.font(.caption)
					.monospaced()
				
				ZStack(alignment: .center) {
					Rectangle()
						.fill(.primary)
						.frame(width: scale.barWidthPoints, height: 1.5)

					HStack {
						Rectangle()
							.fill(.primary)
							.frame(width: 1.5, height: 8)
						Spacer(minLength: 0)
						Rectangle()
							.fill(.primary)
							.frame(width: 1.5, height: 8)
					}
					.frame(width: scale.barWidthPoints)
				}
			}
			.padding(.horizontal, 10)
			.padding(.bottom, 6)
			.stageViewOverlayMaterial(in: RoundedRectangle(cornerRadius: 8))
		}
	}
}

public struct OrientationGizmoView: View {
	public let cameraRotation: simd_quatf
	public var size: CGFloat
	public var isZUp: Bool

	public init(
		cameraRotation: simd_quatf,
		size: CGFloat = 80,
		isZUp: Bool = false
	) {
		self.cameraRotation = cameraRotation
		self.size = size
		self.isZUp = isZUp
	}

	public var body: some View {
		Canvas { context, canvasSize in
			let center = CGPoint(x: canvasSize.width / 2, y: canvasSize.height / 2)
			let axisLength = min(canvasSize.width, canvasSize.height) * 0.35
			let invRotation = cameraRotation.inverse
			let xAxis = rotatePoint(SIMD3<Float>(1, 0, 0), by: invRotation)
			let yAxis = rotatePoint(SIMD3<Float>(0, 1, 0), by: invRotation)
			let zAxis = rotatePoint(SIMD3<Float>(0, 0, 1), by: invRotation)
			let upAxisTag = isZUp ? "Z" : "Y"

			let axes: [(axis: SIMD3<Float>, color: Color, label: String)] = [
				(xAxis, .red, "X"),
				(yAxis, .green, "Y"),
				(zAxis, .blue, "Z"),
			].sorted { $0.axis.z < $1.axis.z }

			for (axis, color, label) in axes {
				let isUp = label == upAxisTag
				let endPoint = CGPoint(
					x: center.x + CGFloat(axis.x) * axisLength,
					y: center.y - CGFloat(axis.y) * axisLength
				)

				let arrowSize: CGFloat = isUp ? 7 : 5
				let direction = CGPoint(
					x: endPoint.x - center.x,
					y: endPoint.y - center.y
				)
				let length = sqrt(direction.x * direction.x + direction.y * direction.y)
				if length > 0 {
					let norm = CGPoint(x: direction.x / length, y: direction.y / length)
					let perp = CGPoint(x: -norm.y, y: norm.x)

					// Shorten the axis line to make room for the arrow
					let lineEndPoint = CGPoint(
						x: endPoint.x - norm.x * arrowSize,
						y: endPoint.y - norm.y * arrowSize
					)

					var linePath = Path()
					linePath.move(to: center)
					linePath.addLine(to: lineEndPoint)
					context.stroke(
						linePath,
						with: .color(color),
						lineWidth: 1.5
					)

					var arrowPath = Path()
					arrowPath.move(to: endPoint)
					arrowPath.addLine(
						to: CGPoint(
							x: endPoint.x - norm.x * arrowSize + perp.x * arrowSize * 0.5,
							y: endPoint.y - norm.y * arrowSize + perp.y * arrowSize * 0.5
						)
					)
					arrowPath.addLine(
						to: CGPoint(
							x: endPoint.x - norm.x * arrowSize - perp.x * arrowSize * 0.5,
							y: endPoint.y - norm.y * arrowSize - perp.y * arrowSize * 0.5
						)
					)
					arrowPath.closeSubpath()
					context.fill(arrowPath, with: .color(color))
				}

				if axis.z > -0.3 {
					let labelPosition = CGPoint(
						x: endPoint.x + CGFloat(axis.x) * 11,
						y: endPoint.y - CGFloat(axis.y) * 11
					)
					context.draw(
						Text(label)
							.font(
								.system(
									size: isUp ? 12 : 10,
									weight: isUp ? .heavy : .bold,
									design: .monospaced
								)
							)
							.foregroundColor(color),
						at: labelPosition,
						anchor: .center
					)
				}
			}
		}
		.frame(width: size, height: size)
		.padding(4)
		.stageViewOverlayMaterial(in: .circle)
	}

	private func rotatePoint(_ point: SIMD3<Float>, by quat: simd_quatf) -> SIMD3<
		Float
	> {
		let rotated = quat.act(point)
		return SIMD3<Float>(rotated.x, rotated.y, rotated.z)
	}
}

public struct StageViewOverlayMaterialModifier<S: Shape>: ViewModifier {
	let shape: S

	public init(shape: S) {
		self.shape = shape
	}

	public func body(content: Content) -> some View {
		#if os(visionOS)
			content.background(.ultraThinMaterial, in: shape)
		#elseif os(macOS)
			if #available(macOS 26.0, *) {
				content.glassEffect(in: shape)
			} else {
				content.background(.ultraThinMaterial, in: shape)
			}
		#else
			if #available(iOS 26.0, *) {
				content.glassEffect(in: shape)
			} else {
				content.background(.ultraThinMaterial, in: shape)
			}
		#endif
	}
}

extension View {
	public func stageViewOverlayMaterial<S: Shape>(in shape: S) -> some View {
		modifier(StageViewOverlayMaterialModifier(shape: shape))
	}
}

extension SIMD4 where Scalar == Float {
	var isFinite: Bool {
		x.isFinite && y.isFinite && z.isFinite && w.isFinite
	}
}
