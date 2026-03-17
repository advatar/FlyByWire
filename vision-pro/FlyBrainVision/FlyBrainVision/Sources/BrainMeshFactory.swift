import CoreGraphics
import ImageIO
import RealityKit
import UIKit

enum BrainMeshFactory {
    @MainActor
    static func makeEntity() throws -> ModelEntity {
        let voxels = try BrainImageVoxelizer.makeVoxels()
        let warmVoxels = voxels.filter { !$0.isAccent }
        let accentVoxels = voxels.filter(\.isAccent)

        var descriptors: [MeshDescriptor] = []
        var materials: [any Material] = []

        if !warmVoxels.isEmpty {
            descriptors.append(makeDescriptor(from: warmVoxels))
            materials.append(
                SimpleMaterial(
                    color: UIColor(red: 0.88, green: 0.82, blue: 0.70, alpha: 0.96),
                    roughness: 0.28,
                    isMetallic: false
                )
            )
        }

        if !accentVoxels.isEmpty {
            descriptors.append(makeDescriptor(from: accentVoxels))
            materials.append(
                SimpleMaterial(
                    color: UIColor(red: 0.47, green: 0.68, blue: 0.30, alpha: 0.98),
                    roughness: 0.18,
                    isMetallic: false
                )
            )
        }

        let mesh = try MeshResource.generate(from: descriptors)

        let entity = ModelEntity(mesh: mesh, materials: materials)
        entity.components.set(InputTargetComponent())
        entity.components.set(HoverEffectComponent())
        return entity
    }

    private static func makeDescriptor(from voxels: [BrainVoxel]) -> MeshDescriptor {
        var positions: [SIMD3<Float>] = []
        var normals: [SIMD3<Float>] = []
        var indices: [UInt32] = []

        positions.reserveCapacity(voxels.count * 24)
        normals.reserveCapacity(voxels.count * 24)
        indices.reserveCapacity(voxels.count * 36)

        for voxel in voxels {
            appendBox(center: voxel.center, size: voxel.size, positions: &positions, normals: &normals, indices: &indices)
        }

        var descriptor = MeshDescriptor(name: voxels.first?.isAccent == true ? "AccentBrain" : "WarmBrain")
        descriptor.positions = MeshBuffers.Positions(positions)
        descriptor.normals = MeshBuffers.Normals(normals)
        descriptor.primitives = .triangles(indices)
        return descriptor
    }

    private static func appendBox(
        center: SIMD3<Float>,
        size: SIMD3<Float>,
        positions: inout [SIMD3<Float>],
        normals: inout [SIMD3<Float>],
        indices: inout [UInt32]
    ) {
        let hx = size.x * 0.5
        let hy = size.y * 0.5
        let hz = size.z * 0.5

        let corners: [SIMD3<Float>] = [
            center + SIMD3(-hx, -hy, -hz),
            center + SIMD3(hx, -hy, -hz),
            center + SIMD3(hx, hy, -hz),
            center + SIMD3(-hx, hy, -hz),
            center + SIMD3(-hx, -hy, hz),
            center + SIMD3(hx, -hy, hz),
            center + SIMD3(hx, hy, hz),
            center + SIMD3(-hx, hy, hz)
        ]

        let faces: [([Int], SIMD3<Float>)] = [
            ([4, 5, 6, 7], SIMD3(0, 0, 1)),
            ([1, 0, 3, 2], SIMD3(0, 0, -1)),
            ([0, 4, 7, 3], SIMD3(-1, 0, 0)),
            ([5, 1, 2, 6], SIMD3(1, 0, 0)),
            ([3, 7, 6, 2], SIMD3(0, 1, 0)),
            ([0, 1, 5, 4], SIMD3(0, -1, 0))
        ]

        for (faceCorners, normal) in faces {
            let baseIndex = UInt32(positions.count)
            for cornerIndex in faceCorners {
                positions.append(corners[cornerIndex])
                normals.append(normal)
            }
            indices += [
                baseIndex, baseIndex + 1, baseIndex + 2,
                baseIndex, baseIndex + 2, baseIndex + 3
            ]
        }
    }
}

private enum BrainImageVoxelizer {
    static func makeVoxels(targetWidth: Int = 180) throws -> [BrainVoxel] {
        guard let image = UIImage(named: "BrainReference"),
              let cgImage = image.cgImage else {
            throw BrainMeshError.missingReferenceImage
        }

        let resized = try resizeImage(cgImage, targetWidth: targetWidth)
        let width = resized.width
        let height = resized.height
        let pixels = try rgbaPixels(from: resized)

        var occupancy = Array(repeating: 0, count: width * height)
        var colorSamples = Array(repeating: SIMD3<Float>(repeating: 0), count: width * height)

        for y in 0..<height {
            for x in 0..<width {
                let offset = ((y * width) + x) * 4
                let r = Float(pixels[offset]) / 255
                let g = Float(pixels[offset + 1]) / 255
                let b = Float(pixels[offset + 2]) / 255
                let brightness = max(r, max(g, b))
                let index = y * width + x
                colorSamples[index] = SIMD3(r, g, b)
                occupancy[index] = brightness > 0.10 ? 1 : 0
            }
        }

        let integral = makeIntegralImage(from: occupancy, width: width, height: height)

        let xStep = 0.95 / Float(width)
        let yStep = (0.95 / Float(width)) * (Float(height) / Float(width))
        let aspect = Float(width) / Float(height)

        var voxels: [BrainVoxel] = []
        voxels.reserveCapacity(occupancy.reduce(0, +))

        for y in 0..<height {
            for x in 0..<width {
                let index = y * width + x
                guard occupancy[index] == 1 else { continue }

                let color = colorSamples[index]
                let density = localDensity(integral, x: x, y: y, width: width, height: height, radius: 4)

                let xNorm = ((Float(x) / Float(width - 1)) - 0.5) * aspect
                let yNorm = 0.5 - Float(y) / Float(height - 1)

                let bridgeWeight = max(0, 1 - abs(xNorm) * 1.8)
                let hemisphereOffset = copysign(pow(abs(xNorm), 1.25), xNorm) * (0.07 + density * 0.06)
                let centralArch = (1 - abs(yNorm) * 1.5) * 0.01 * bridgeWeight
                let zCenter = hemisphereOffset + centralArch

                let zThickness = 0.006 + density * 0.045 + abs(hemisphereOffset) * 0.12
                let isAccent = color.y > color.x * 0.98 && color.y > color.z * 1.35

                voxels.append(
                    BrainVoxel(
                        center: SIMD3(xNorm * 0.75, yNorm * 0.8, zCenter),
                        size: SIMD3(xStep * 1.1, yStep * 1.1, zThickness),
                        isAccent: isAccent
                    )
                )
            }
        }

        return voxels
    }

    private static func resizeImage(_ image: CGImage, targetWidth: Int) throws -> CGImage {
        let sourceWidth = image.width
        let sourceHeight = image.height
        let targetHeight = max(1, Int((Double(targetWidth) / Double(sourceWidth)) * Double(sourceHeight)))

        let colorSpace = CGColorSpaceCreateDeviceRGB()
        guard let context = CGContext(
            data: nil,
            width: targetWidth,
            height: targetHeight,
            bitsPerComponent: 8,
            bytesPerRow: targetWidth * 4,
            space: colorSpace,
            bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
        ) else {
            throw BrainMeshError.unableToCreateContext
        }

        context.interpolationQuality = .high
        context.draw(image, in: CGRect(x: 0, y: 0, width: targetWidth, height: targetHeight))

        guard let resized = context.makeImage() else {
            throw BrainMeshError.unableToResizeImage
        }
        return resized
    }

    private static func rgbaPixels(from image: CGImage) throws -> [UInt8] {
        let width = image.width
        let height = image.height
        let bytesPerRow = width * 4
        var pixels = [UInt8](repeating: 0, count: height * bytesPerRow)

        let colorSpace = CGColorSpaceCreateDeviceRGB()
        guard let context = CGContext(
            data: &pixels,
            width: width,
            height: height,
            bitsPerComponent: 8,
            bytesPerRow: bytesPerRow,
            space: colorSpace,
            bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
        ) else {
            throw BrainMeshError.unableToCreateContext
        }

        context.draw(image, in: CGRect(x: 0, y: 0, width: width, height: height))
        return pixels
    }

    private static func makeIntegralImage(from occupancy: [Int], width: Int, height: Int) -> [Int] {
        var integral = Array(repeating: 0, count: (width + 1) * (height + 1))

        for y in 0..<height {
            var running = 0
            for x in 0..<width {
                running += occupancy[(y * width) + x]
                integral[((y + 1) * (width + 1)) + (x + 1)] = integral[(y * (width + 1)) + (x + 1)] + running
            }
        }

        return integral
    }

    private static func localDensity(
        _ integral: [Int],
        x: Int,
        y: Int,
        width: Int,
        height: Int,
        radius: Int
    ) -> Float {
        let x0 = max(0, x - radius)
        let y0 = max(0, y - radius)
        let x1 = min(width - 1, x + radius)
        let y1 = min(height - 1, y + radius)

        let stride = width + 1
        let sum =
            integral[((y1 + 1) * stride) + (x1 + 1)]
            - integral[(y0 * stride) + (x1 + 1)]
            - integral[((y1 + 1) * stride) + x0]
            + integral[(y0 * stride) + x0]

        let area = Float((x1 - x0 + 1) * (y1 - y0 + 1))
        return Float(sum) / area
    }
}

private struct BrainVoxel {
    let center: SIMD3<Float>
    let size: SIMD3<Float>
    let isAccent: Bool
}

private enum BrainMeshError: LocalizedError {
    case missingReferenceImage
    case unableToCreateContext
    case unableToResizeImage

    var errorDescription: String? {
        switch self {
        case .missingReferenceImage:
            return "The bundled `BrainReference` image could not be loaded."
        case .unableToCreateContext:
            return "A Core Graphics drawing context could not be created."
        case .unableToResizeImage:
            return "The reference image could not be resized."
        }
    }
}
