//
//  InstallerStatusViewModel.swift
//  IDeviceKit
//
//  Created by samara on 3.06.2025.
//

import Combine

extension InstallerStatusViewModel {
	enum InstallerStatus {
		case none
		case ready
		case sendingManifest
		case sendingPayload
		case installing
		case completed(Result<Void, Error>)
		case broken(Error)
	}
}

class InstallerStatusViewModel: ObservableObject {
	@Published var status: InstallerStatus
	@Published var uploadProgress: Double = 0.0
	@Published var packageProgress: Double = 0.0
	@Published var installProgress: Double = 0.0
	
	var isDevice: Bool = true
	
	var overallProgress: Double {
		if isDevice {
			(installProgress + uploadProgress + packageProgress) / 3.0
		} else {
			packageProgress
		}
	}
	
	var isCompleted: Bool {
		if case .completed = status {
			true
		} else {
			false
		}
	}
	
	init(status: InstallerStatus = .none) {
		self.status = status
	}
}
