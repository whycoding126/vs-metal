//
//  VSScript.swift
//  vs-metal
//
//  Created by SATOSHI NAKAJIMA on 6/23/17.
//  Copyright © 2017 SATOSHI NAKAJIMA. All rights reserved.
//

import Foundation
import MetalPerformanceShaders

/// An object represents a VideoShader script, which describes the video pipeline. 
/// It has to be compiled into a VSRuntime object (by calling its compile() method)
/// to process the video. 
class VSScript {
    private static let nodeInfos:[String:[String:Any]] = {
        let url = Bundle.main.url(forResource: "VSNodes", withExtension: "js")!
        let data = try! Data(contentsOf: url)
        let json = try! JSONSerialization.jsonObject(with: data)
        return json as! [String:[String:Any]]
    }()
    
    private static func getNodeInfo(name:String) -> [String:Any]? {
        return VSScript.nodeInfos[name]
    }

    private var pipeline:[[String:Any]]
    private let constants:[String:[Float]]
    private let variables:[String:[String:Any]]
    
    private init(json:[String:Any], pipeline:[[String:Any]]) {
        self.pipeline = pipeline
        self.constants = json["constants"] as? [String:[Float]] ?? [String:[Float]]()
        self.variables = json["variables"] as? [String:[String:Any]] ?? [String:[String:Any]]()
    }
    
    /// Initialize an empty script object
    init() {
        self.pipeline = [[String:Any]]()
        self.constants = [String:[Float]]()
        self.variables = [String:[String:Any]]()
    }
    
    /// Append a node to the script object
    ///
    /// - Parameter node: A node with "name" and optional "attr" properties
    /// - Returns: the script object itself
    func append(node:[String:Any]) -> VSScript {
        pipeline.append(node)
        return self
    }

    /// Create a script object from the specified script file.
    ///
    /// - Parameter from: the URL of the script file
    /// - Returns: a script object
    static func load(from:URL?) -> VSScript? {
        guard let url = from else {
            return nil
        }
        do {
            let data = try Data(contentsOf: url)
            if let json = try JSONSerialization.jsonObject(with: data) as? [String:Any],
               let pipeline = json["pipeline"] as? [[String:Any]] {
                return VSScript(json:json, pipeline: pipeline)
            }
        } catch {
        }
        return nil
    }
    
    private static func makeNode(nodeName:String, params paramsIn:[String:Any]?, context:VSContext) -> VSNode? {
        guard let info = VSScript.getNodeInfo(name: nodeName) else {
            print("### VSScript:makeNode Invalid node name", nodeName)
            return nil
        }
        var params = [String:Any]()
        var attributeNames = [String]()
        if let attrs = info["attr"] as? [[String:Any]] {
            for attr in attrs {
                if let attributeName=attr["name"] as? String,
                    var defaults=attr["default"] as? [Float] {
                    if let values = paramsIn?[attributeName] as? [Float], values.count <= defaults.count {
                        //print("VSC:makeNode overriding", name)
                        for (index, value) in values.enumerated() {
                            defaults[index] = value
                        }
                    }
                    attributeNames.append(attributeName)
                    params[attributeName] = defaults
                }
            }
        }
        
        if let node = VSController.makeNode(name: nodeName) {
            return node
        } else if let node = VSMPSFilter.makeNode(name: nodeName, params: params, context: context) {
            return node
        }

        let buffers = attributeNames.map({ (name) -> MTLBuffer in
            let values = params[name] as! [Float]
            let length = MemoryLayout.size(ofValue: values[0]) * values.count
            let buffer = context.device.makeBuffer(length: (length + 15) / 16 * 16, options: .storageModeShared)
            memcpy(buffer.contents(), values, length)
            if let key = paramsIn?[name] as? String {
                context.registerNamedBuffer(key: key, buffer: buffer)
            }
            return buffer
        })
        let sourceCount = info["sources"] as? Int ?? 1
        return VSFilter.makeNode(name: nodeName, buffers: buffers, sourceCount: sourceCount, context: context)
    }
    
    /// Generate a runtime from the script and initialize the pipeline context.
    ///
    /// - Parameter context: pipeline context
    /// - Returns: a runtime generated from the script
    func compile(context:VSContext) -> VSRuntime {
        let nodes = (self.pipeline.map { (item) -> VSNode? in
            if let name=item["name"] as? String {
                return VSScript.makeNode(nodeName: name, params: item["attr"] as? [String:Any], context:context)
            }
            return nil
        }).flatMap { $0 }
    
        context.updateNamedBuffers(with: self.constants)
        
        let dynamicVariables = (self.variables.map { (key, params) -> VSDynamicVariable? in
            if let type = params["type"] as? String {
                switch(type) {
                case "sin":
                    return VSTimer(key: key, params: params)
                default:
                    break
                }
            }
            return nil
        }).flatMap { $0 }
        
        return VSRuntime(nodes:nodes, dynamicVariables:dynamicVariables)
    }
}
