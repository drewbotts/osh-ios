import SwiftUI

// MARK: - SchemaTreeView
//
// A decoded SWE schema rendered as nested disclosure groups.
//
// Replaces a raw JSON dump, which was honest but unreadable: a Tempest
// observation schema is 5.8 KB of text to answer "what units is the wind in".
// The tree shows the same information as structure — a record's fields, a
// vector's coordinates, an array's element type — with each component's
// identifying metadata on the row rather than three lines below it.

struct SchemaTreeView: View {

    let schema: SWESchemaDecoder.DatastreamSchema

    var body: some View {
        ComponentRow(name: schema.recordSchema.name.isEmpty ? "record" : schema.recordSchema.name,
                     component: schema.recordSchema,
                     path: FieldPath(components: []),
                     encoding: schema.recordEncoding)
    }
}

// MARK: - ComponentRow

/// One component, and its children when it has any.
///
/// Recursive rather than flattened so a DataArray's element type stays visibly
/// *inside* the array. A flat list of leaf paths would read as though a video's
/// three colour channels were fields of the record.
private struct ComponentRow: View {

    let name: String
    let component: DataComponent
    let path: FieldPath
    let encoding: DecodedBinaryEncoding?

    var body: some View {
        if children.isEmpty {
            leaf
        } else {
            DisclosureGroup {
                ForEach(Array(children.enumerated()), id: \.offset) { _, child in
                    ComponentRow(name: child.name,
                                 component: child.component,
                                 path: path.appending(child.name),
                                 encoding: encoding)
                }
            } label: {
                leaf
            }
        }
    }

    private var leaf: some View {
        VStack(alignment: .leading, spacing: 2) {
            HStack(spacing: 6) {
                Text(name)
                    .font(.callout.monospaced())
                Text(typeName)
                    .font(.caption2)
                    .padding(.horizontal, 5)
                    .padding(.vertical, 1)
                    .background(Color.secondary.opacity(0.15), in: Capsule())
                    .foregroundStyle(.secondary)
                Spacer(minLength: 0)
                if let wire {
                    Text(wire)
                        .font(.caption2.monospaced())
                        .foregroundStyle(.tertiary)
                }
            }

            if let label = component.label, label != name {
                Text(label)
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            if !metadata.isEmpty {
                Text(metadata.joined(separator: " · "))
                    .font(.caption2)
                    .foregroundStyle(.tertiary)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
        .padding(.vertical, 1)
    }

    // MARK: Children

    private var children: [DataField] {
        switch component {
        case let record as DataRecord:   return record.fields
        case let vector as SWEVector:    return vector.coordinates
        case let choice as SWEDataChoice: return choice.items
        case let array as SWEDataArray:
            return [DataField(name: array.elementTypeName, component: array.elementType)]
        case let matrix as SWEMatrix:
            return [DataField(name: matrix.elementTypeName, component: matrix.elementType)]
        default: return []
        }
    }

    // MARK: Presentation

    private var typeName: String {
        switch component {
        case is DataRecord:     return "Record"
        case is SWEVector:      return "Vector"
        case is SWEDataArray:   return "Array"
        case is SWEMatrix:      return "Matrix"
        case is SWEDataChoice:  return "Choice"
        case is Quantity:       return "Quantity"
        case is SWECount:       return "Count"
        case is SWEText:        return "Text"
        case is SWECategory:    return "Category"
        case is SWEBoolean:     return "Boolean"
        case is TimeStamp, is SWETime: return "Time"
        case is QuantityRange:  return "QuantityRange"
        case is CountRange:     return "CountRange"
        case is CategoryRange:  return "CategoryRange"
        case is TimeRange:      return "TimeRange"
        case is SWEGeometry:    return "Geometry"
        default:                return "Component"
        }
    }

    /// The binary encoding's view of this component: its dataType, or the
    /// codec when the whole component arrives as one compressed block.
    private var wire: String? {
        guard let member = encoding?.member(for: path) else { return nil }
        switch member.kind {
        case .component(let dataType, _, _, _):
            return dataType.rawValue.split(separator: "/").last.map(String.init)
        case .block(let compression, _, _, _, _):
            return compression.map { "block \($0)" } ?? "block"
        }
    }

    /// The bits a viewer actually needs to interpret a value: units, the
    /// vocabulary a token comes from, the frame a coordinate is measured in.
    private var metadata: [String] {
        var parts: [String] = []

        switch component {
        case let quantity as Quantity:
            if !quantity.uom.isEmpty { parts.append("uom \(quantity.uom)") }
            else if quantity.uomHref != nil { parts.append("uom ISO-8601") }
            if let frame = quantity.refFrame { parts.append("frame \(shortened(frame))") }
            if let axis = quantity.axisId { parts.append("axis \(axis)") }
            if let intervals = quantity.constraint?.intervals, let first = intervals.first {
                parts.append("range \(first[0])…\(first[1])")
            }
        case let range as QuantityRange:
            if !range.uom.isEmpty { parts.append("uom \(range.uom)") }
        case let category as SWECategory:
            if let space = category.codeSpace { parts.append("codeSpace \(shortened(space))") }
            if let values = category.constraint?.values {
                parts.append("one of \(values.prefix(4).joined(separator: ", "))")
            }
        case let time as SWETime:
            if let frame = time.refFrame { parts.append("trs \(shortened(frame))") }
        case let stamp as TimeStamp:
            if let frame = stamp.refFrame { parts.append("trs \(shortened(frame))") }
        case let vector as SWEVector:
            if let frame = vector.refFrame { parts.append("frame \(shortened(frame))") }
            if let local = vector.localFrame { parts.append("local \(shortened(local))") }
        case let array as SWEDataArray:
            parts.append(sizeDescription(array.elementCount))
        case let matrix as SWEMatrix:
            parts.append(sizeDescription(matrix.elementCount))
        default:
            break
        }

        if let definition = component.definition { parts.append(shortened(definition)) }
        if let nilValues = nilValueCount, nilValues > 0 {
            parts.append("\(nilValues) nil value\(nilValues == 1 ? "" : "s")")
        }
        return parts
    }

    private func sizeDescription(_ count: SWECount) -> String {
        if let value = count.value { return "\(value) elements" }
        if let ref = count.ref { return "size from #\(ref)" }
        return "variable size"
    }

    private var nilValueCount: Int? {
        switch component {
        case let quantity as Quantity: return quantity.nilValues?.count
        case let count as SWECount:    return count.nilValues?.count
        case let text as SWEText:      return text.nilValues?.count
        case let category as SWECategory: return category.nilValues?.count
        case let time as SWETime:      return time.nilValues?.count
        default: return nil
        }
    }

    /// URIs are the interoperable part and far too long to read in a row, so
    /// only the distinguishing tail is shown.
    private func shortened(_ uri: String) -> String {
        uri.split(separator: "/").last.map(String.init) ?? uri
    }
}
