//
//  OrientationGizmoView.swift
//  StageViewCore
//
//  Unified DCC-style corner gizmo for 3D viewports.
//  Shows camera orientation with RGB = XYZ color convention.
//

import SwiftUI
import simd

/// A screen-space orientation gizmo that rotates with camera orientation.
public struct OrientationGizmoView: View {
	/// Camera rotation quaternion
	public let cameraRotation: simd_quatf

	/// Size of the gizmo in points
	public var size: CGFloat

	/// Whether this is Z-up coordinate system
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
		VStack(alignment: .leading, spacing: 4) {
			Canvas { context, canvasSize in
				let center = CGPoint(x: canvasSize.width / 2, y: canvasSize.height / 2)
				let axisLength = min(canvasSize.width, canvasSize.height) * 0.35

				// Apply camera rotation (inverse to show world orientation)
				let invRotation = cameraRotation.inverse

				// World axes in camera space
				let xAxis = rotatePoint(SIMD3<Float>(1, 0, 0), by: invRotation)
				let yAxis = rotatePoint(SIMD3<Float>(0, 1, 0), by: invRotation)
				let zAxis = rotatePoint(SIMD3<Float>(0, 0, 1), by: invRotation)

				let upAxisTag = isZUp ? "Z" : "Y"

				// Sort axes by Z (depth) for proper drawing order
				let axes: [(axis: SIMD3<Float>, color: Color, label: String)] = [
					(xAxis, .red, "X"),
					(yAxis, .green, "Y"),
					(zAxis, .blue, "Z"),
				].sorted { $0.axis.z < $1.axis.z }  // Draw back-to-front

				for (axis, color, label) in axes {
					let isUp = label == upAxisTag

					// Project to 2D (simple orthographic - ignore Z)
					let endPoint = CGPoint(
						x: center.x + CGFloat(axis.x) * axisLength,
						y: center.y - CGFloat(axis.y) * axisLength  // Flip Y for screen coords
					)

					// Draw axis line
					var path = Path()
					path.move(to: center)
					path.addLine(to: endPoint)

					// Style for the "Up" axis vs others
					// let baseOpacity = Double(max(0.3, (axis.z + 1) / 2))
					// let lineWidth = isUp ? (axis.z > 0 ? 5.0 : 4.0) : (axis.z > 0 ? 2.5 : 1.5)
					let baseOpacity = 0.7
					let lineWidth = 2.0

					context.stroke(
						path,
						with: .color(color.opacity(baseOpacity)),
						lineWidth: lineWidth
					)

					// Draw arrowhead
					let arrowSize: CGFloat = isUp ? 10 : 7
					let direction = CGPoint(
						x: endPoint.x - center.x,
						y: endPoint.y - center.y
					)
					let length = sqrt(
						direction.x * direction.x + direction.y * direction.y
					)
					if length > 0 {
						let norm = CGPoint(x: direction.x / length, y: direction.y / length)
						let perp = CGPoint(x: -norm.y, y: norm.x)

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

						context.fill(arrowPath, with: .color(color.opacity(baseOpacity)))
					}

					// Draw axis label
					if axis.z > -0.3 {
						let labelPos = CGPoint(
							x: endPoint.x + CGFloat(axis.x) * 12,
							y: endPoint.y - CGFloat(axis.y) * 12
						)
						context.draw(
							Text(label)
								.font(
									.system(
										size: isUp ? 13 : 11,
										weight: isUp ? .heavy : .bold,
										design: .monospaced
									)
								)
								.foregroundColor(color),
							at: labelPos,
							anchor: .center
						)
					}
				}

				// Draw origin sphere
				let originSize: CGFloat = 8
				context.fill(
					Circle().path(
						in: CGRect(
							x: center.x - originSize / 2,
							y: center.y - originSize / 2,
							width: originSize,
							height: originSize
						)
					),
					with: .color(.white)
				)
			}
			.frame(width: size, height: size)
			.padding(8)
			#if os(visionOS)
				.background(.ultraThinMaterial, in: .circle)
			#elseif os(macOS)
				.modifier(HydraToolbarMaterialModifier())
			#else
				.glassEffect()
			#endif
			.foregroundStyle(.secondary)
		}
	}

	/// Rotate a point by a quaternion
	private func rotatePoint(_ point: SIMD3<Float>, by quat: simd_quatf) -> SIMD3<
		Float
	> {
		let p = simd_quatf(ix: point.x, iy: point.y, iz: point.z, r: 0)
		let rotated = quat * p * quat.inverse
		return SIMD3<Float>(rotated.imag.x, rotated.imag.y, rotated.imag.z)
	}
}

#if os(macOS)
	private struct HydraToolbarMaterialModifier: ViewModifier {
		func body(content: Content) -> some View {
			if #available(macOS 26.0, *) {
				content.glassEffect()
			} else {
				content.background(.ultraThinMaterial, in: .circle)
			}
		}
	}
#endif
