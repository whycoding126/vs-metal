//
//  VSContext.swift
//  vs-metal
//
//  Created by SATOSHI NAKAJIMA on 6/22/17.
//  Copyright © 2017 SATOSHI NAKAJIMA. All rights reserved.
//

import Foundation
import MetalKit
import MetalPerformanceShaders

// A wrapper of MTLTexture so that we can compare
struct VSTexture:Equatable {
    let texture:MTLTexture
    let identity:Int
    public static func ==(lhs: VSTexture, rhs: VSTexture) -> Bool {
        return lhs.identity == rhs.identity
    }
}

class VSContext {
    let device:MTLDevice
    let commandQueue: MTLCommandQueue
    let pixelFormat:MTLPixelFormat
    let threadGroupSize = MTLSizeMake(16,16,1)
    var threadGroupCount = MTLSizeMake(1, 1, 1) // to be filled later
    let nodes:[String:[String:Any]] = {
        let url = Bundle.main.url(forResource: "VSNodes", withExtension: "js")!
        let data = try! Data(contentsOf: url)
        let json = try! JSONSerialization.jsonObject(with: data)
        return json as! [String:[String:Any]]
    }()

    private var width = 1, height = 1 // to be set later
    private var descriptor = MTLTextureDescriptor()
    
    // stack: texture stack for the video pipeline
    // transient: popped textures to be migrated to pool later
    // pool: pool of textures to be reused for stack
    private var stack = [VSTexture]()
    private var pool = [VSTexture]()
    var hasUpdate = false
    var metalTexture:CVMetalTexture?
    
    init(device:MTLDevice, pixelFormat:MTLPixelFormat) {
        self.device = device
        self.pixelFormat = pixelFormat
        commandQueue = device.makeCommandQueue()
    }
    
    func set(metalTexture:CVMetalTexture) {
        self.metalTexture = metalTexture // HACK: extra reference (see VSProcessor)
        if let texture = CVMetalTextureGetTexture(metalTexture) {
            set(texture:texture)
        }
    }
    
    // Special type of push for the video source
    private func set(texture:MTLTexture) {
        assert(Thread.current == Thread.main)
        
        if width != texture.width || height != texture.height {
            width = texture.width
            height = texture.height
            
            descriptor.textureType = .type2D
            descriptor.pixelFormat = pixelFormat
            descriptor.width = width
            descriptor.height = height
            descriptor.usage = [.shaderRead, .shaderWrite]
            
            threadGroupCount.width = (width + threadGroupSize.width - 1) / threadGroupSize.width
            threadGroupCount.height = (height + threadGroupSize.height - 1) / threadGroupSize.height
        }

        hasUpdate = true
        stack.removeAll() // HACK: for now
        
        // HACK: Extra copy
        let textureCopy = device.makeTexture(descriptor: descriptor)
        let commandBuffer:MTLCommandBuffer = {
            let commandBuffer = commandQueue.makeCommandBuffer()
            let encoder = commandBuffer.makeBlitCommandEncoder()
            encoder.copy(from: texture, sourceSlice: 0, sourceLevel: 0, sourceOrigin: MTLOriginMake(0, 0, 0), sourceSize: MTLSizeMake(width, height, 1), to: textureCopy, destinationSlice: 0, destinationLevel: 0, destinationOrigin: MTLOriginMake(0, 0, 0))
            encoder.endEncoding()
            return commandBuffer
        }()
        commandBuffer.commit()
        
        push(texture:VSTexture(texture:textureCopy, identity:-1))
    }
    
    func pop() -> VSTexture {
        if let texture = stack.popLast() {
            return texture
        }
        print("VSC:pop underflow")
        return make() // NOTE: Allow underflow
    }
    
    func push(texture:VSTexture) {
        stack.append(texture)
    }
    
    private func getDestination() -> VSTexture {
        // Find a texture in the pool, which is not in the stack
        for texture in pool {
            guard let _ = stack.index(of:texture) else {
                return texture
            }
        }
        print("VSC:get makeTexture", pool.count)
        return make()
    }
        
    private func make() -> VSTexture {
        let ret = VSTexture(texture:device.makeTexture(descriptor: descriptor), identity:pool.count)
        pool.append(ret)
        return ret
    }
    
    func encode(nodes:[VSNode], commandBuffer:MTLCommandBuffer) {
        assert(Thread.current == Thread.main)
        hasUpdate = false
        for node in nodes {
            node.encode(commandBuffer:commandBuffer, destination:getDestination(), context:self)
        }
    }
}
