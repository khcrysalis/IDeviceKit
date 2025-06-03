//
//  IDeviceSwiftError.swift
//  IDeviceKit
//
//  Created by samara on 3.06.2025.
//

import Foundation
import IDevice

struct IDeviceSwiftError: Error {
	let message: String
	let code: Int32
	
	init(_ error: IdeviceFfiError?) {
		self.message = error?.message.flatMap {
			String(cString: $0)
		} ?? ""
		self.code = error?.code ?? 0
	}
	
	init(_ error: UnsafeMutablePointer<IdeviceFfiError>?) {
		if let cMessage = error?.pointee.message {
			self.message = String(cString: cMessage)
		} else {
			self.message = ""
		}
		self.code = error?.pointee.code ?? 0
	}
	
	init(
		_ code: Int32 = -7001, // our custom error hehe
		message: String
	) {
		self.message = message
		self.code = code
	}
}
