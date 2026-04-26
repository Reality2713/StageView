import RealityKit

// MARK: - Constants

/// Entity names injected by RealityKit during USD import that have no USD prim counterpart.
/// Confirmed: `usdPrimitiveAxis` is injected as a child of Sphere/Cone/Capsule/Cylinder prims.
let realityKitInternalNames: Set<String> = [
	"usdPrimitiveAxis",
]

// MARK: - PrimPathMapping

/// Bidirectional prim path ↔ entity ID mapping built from an imported entity tree.
///
/// Paths stored here are "entity paths" reconstructed from the entity hierarchy.
/// They match the entity tree structure, which differs from USD prim paths when
/// `UsdGeomScope` prims are present — Scope prims are transparent and do not
/// appear as entities. See `Docs/ImportSession-Algorithm-Spec.md` for full rules.
public struct PrimPathMapping: Sendable {
	/// Entity path string → RealityKit entity ID.
	public let primPathToEntityID: [String: Entity.ID]
	/// RealityKit entity ID → entity path string.
	public let entityIDToPrimPath: [Entity.ID: String]

	public init(primPathToEntityID: [String: Entity.ID], entityIDToPrimPath: [Entity.ID: String]) {
		self.primPathToEntityID = primPathToEntityID
		self.entityIDToPrimPath = entityIDToPrimPath
	}
}

// MARK: - Standalone Build Function

/// Build a bidirectional prim path ↔ entity mapping by walking the imported entity tree.
///
/// `Entity(contentsOf:)` produces a hierarchy that mirrors the USD prim tree with
/// two exceptions:
/// - **UsdGeomScope** prims are transparent — they do not appear as entities, and
///   their children are hoisted to the nearest non-Scope ancestor.
/// - **RealityKit-injected** entities (`usdPrimitiveAxis` on sphere/cone/capsule/cylinder)
///   have no USD prim counterpart and are excluded from the mapping.
///
/// The returned paths are "entity paths" that match the entity hierarchy structure.
/// For USD files without Scope prims the entity paths and USD prim paths are identical.
///
/// - Parameter root: The root entity returned by `Entity(contentsOf:)`.
/// - Returns: A `PrimPathMapping` with O(1) lookup dictionaries.
public func buildPrimPathMapping(root: Entity) -> PrimPathMapping {
	var primToID: [String: Entity.ID] = [:]
	var idToPrim: [Entity.ID: String] = [:]

	func walk(_ entity: Entity, parentPrimPath: String) {
		guard !realityKitInternalNames.contains(entity.name) else { return }

		let primPath: String
		if entity.name.isEmpty {
			primPath = parentPrimPath
		} else {
			let primName = _stripDuplicateSuffix(entity.name, amongSiblingsOf: entity)
			primPath = parentPrimPath.isEmpty ? "/\(primName)" : "\(parentPrimPath)/\(primName)"
		}

		if !entity.name.isEmpty {
			primToID[primPath] = entity.id
			idToPrim[entity.id] = primPath
			entity.components.set(USDPrimPathComponent(primPath: primPath))
		}

		for child in entity.children {
			walk(child, parentPrimPath: primPath)
		}
	}

	for child in root.children {
		walk(child, parentPrimPath: "")
	}

	return PrimPathMapping(primPathToEntityID: primToID, entityIDToPrimPath: idToPrim)
}

// MARK: - Internal Helpers

/// Strip RealityKit's `_N` duplicate suffix when other siblings share the base name.
func _stripDuplicateSuffix(_ name: String, amongSiblingsOf entity: Entity) -> String {
	guard let lastUnderscore = name.lastIndex(of: "_") else { return name }
	let suffixStart = name.index(after: lastUnderscore)
	guard suffixStart < name.endIndex,
		name[suffixStart...].allSatisfy(\.isNumber) else { return name }

	let baseName = String(name[..<lastUnderscore])
	guard let parent = entity.parent else { return name }
	let hasSiblingWithBaseName = parent.children.contains { sibling in
		sibling.id != entity.id && (sibling.name == baseName || sibling.name.hasPrefix(baseName + "_"))
	}
	return hasSiblingWithBaseName ? baseName : name
}
