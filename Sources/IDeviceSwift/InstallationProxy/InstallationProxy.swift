//
//  ConduitInstaller.swift
//  Feather
//
//  Created by samara on 23.04.2025.
//

import Foundation
import SwiftUI
import IDevice
import UIKit.UIApplication

public class InstallationProxy: Identifiable, ObservableObject {
	private let _heartbeat = HeartbeatManager.shared
	private let _uuid = UUID().uuidString
	
	typealias AfcClientHandle = OpaquePointer
	typealias AfcFileHandle = OpaquePointer
	typealias InstallationProxyClientHandle = OpaquePointer
	
	@ObservedObject
	public var viewModel: InstallerStatusViewModel
	
	public init(viewModel: InstallerStatusViewModel) {
		self.viewModel = viewModel
	}
	
	public func install(at url: URL, suspend: Bool = false) async throws {
		var afcClient: AfcClientHandle?
		var fileHandle: AfcFileHandle?
		var installproxy: InstallationProxyClientHandle?
		
		try await Task.detached(priority: .utility) {
			guard FileManager.default.fileExists(atPath: HeartbeatManager.pairingFile()) else {
				throw IDeviceSwiftError(message: "Missing Pairing")
			}
			
			if await self._heartbeat.isRsd {
				guard await self._heartbeat.ensureRSDTunnel() else {
					throw IDeviceSwiftError(message: "Missing Pairing")
				}
			} else {
				guard await self._heartbeat.checkSocketConnection().isConnected else {
					throw IDeviceSwiftError(message: "Missing Pairing")
				}
			}
			
			defer {
				afc_client_free(afcClient)
				installation_proxy_client_free(installproxy)
			}
			
			let heartbeat = await self._heartbeat
			
			if heartbeat.isRsd {
				guard let adapter = heartbeat.adapter else {
					throw IDeviceSwiftError(message: "Cannot find RSD adapter")
				}
				
				guard let handshake = heartbeat.handshake else {
					throw IDeviceSwiftError(message: "Cannot find RSD handshake")
				}
	
				guard afc_client_connect_rsd(adapter, handshake, &afcClient) == nil else {
					throw IDeviceSwiftError(message: "Cannot connect to AFC")
				}
			} else {
				guard let provider = heartbeat.provider else {
					throw IDeviceSwiftError(message: "Cannot find TCP provider")
				}
				
				guard afc_client_connect(provider, &afcClient) == nil else {
					throw IDeviceSwiftError(message: "Cannot connect to AFC")
				}
			}
			
			let stagingDir = "PublicStaging"
			
			let afc_make_directory_result =  afc_make_directory(afcClient, stagingDir)
			guard afc_make_directory_result == nil else {
				throw IDeviceSwiftError(afc_make_directory_result)
			}
			
			print("1")
			
			let remoteDir = "/\(stagingDir)/\(self._uuid).ipa"
			
			let afc_file_open_result = afc_file_open(afcClient, remoteDir, AfcWrOnly, &fileHandle)
			guard afc_file_open_result == nil else {
				throw IDeviceSwiftError(afc_file_open_result)
			}
			
			print("2")
			
			try await self._updateStatus(with: .sendingPayload)
			
			guard let fileHandle = fileHandle else {
				throw IDeviceSwiftError(message: "Missing File Handle")
			}
			
			let data = try Data(contentsOf: url)
			let totalSize = data.count
			let chunkSize = 64 * 1024 * 1024 // 67mb
			var totalBytesWritten = 0
			
			guard let rawBuffer = data.withUnsafeBytes({ $0.baseAddress })?.assumingMemoryBound(to: UInt8.self) else {
				throw IDeviceSwiftError(message: "Error writing to AFC")
			}
			
			while totalBytesWritten < totalSize {
				let bytesLeft = totalSize - totalBytesWritten
				let bytesToWrite = min(chunkSize, bytesLeft)
				let writePtr = rawBuffer.advanced(by: totalBytesWritten)
				
				let result = afc_file_write(fileHandle, writePtr, bytesToWrite)
				if result != nil {
					throw IDeviceSwiftError(result)
				}
				
				totalBytesWritten += bytesToWrite
				
				let progress = Double(totalBytesWritten) / Double(totalSize)
				try await self._updateUploadProgress(with: progress)
			}
			
			print(2)
			
			let afc_file_close_result = afc_file_close(fileHandle)
			guard afc_file_close_result == nil else {
				throw IDeviceSwiftError(afc_file_close_result)
			}
			
			try await self._updateStatus(with: .installing)
			
			
			if heartbeat.isRsd {
				guard let adapter = heartbeat.adapter else {
					throw IDeviceSwiftError(message: "Cannot find RSD adapter")
				}
				
				guard let handshake = heartbeat.handshake else {
					throw IDeviceSwiftError(message: "Cannot find RSD handshake")
				}
				
				print(3)
				
				let installation_proxy_connect_rsd_result = installation_proxy_connect_rsd(adapter, handshake, &installproxy)
				guard installation_proxy_connect_rsd_result == nil else {
					throw IDeviceSwiftError(installation_proxy_connect_rsd_result)
				}
			} else {
				guard let provider = heartbeat.provider else {
					throw IDeviceSwiftError(message: "Cannot find TCP provider")
				}
				let installation_proxy_connect_result = installation_proxy_connect(provider, &installproxy)
				guard installation_proxy_connect_result == nil else {
					throw IDeviceSwiftError(installation_proxy_connect_result)
				}
			}
			
			print(4)
			
			let ownedPath = strdup(remoteDir)
			defer { free(ownedPath) }

			func runInstall() -> UnsafeMutablePointer<IdeviceFfiError>? {
				installation_proxy_install_with_callback(
					installproxy,
					ownedPath,
					nil, // options
					Self._installationProgressCallback,
					Unmanaged.passUnretained(self).toOpaque()
				)
			}

			if suspend {
				// For suspend(self-install) cases app must exit so that installd can actually
				// update the app. Do a best effort to catch fast installation failures.
				let earlyError: UnsafeMutablePointer<IdeviceFfiError>? = await withCheckedContinuation { continuation in
					let resumeQueue = DispatchQueue(label: "InstallationProxy.asyncSelfInstall")
					var didResume = false

					func resumeOnce(_ value: UnsafeMutablePointer<IdeviceFfiError>?) {
						resumeQueue.async {
							guard !didResume else { return }
							didResume = true
							continuation.resume(returning: value)
						}
					}

					DispatchQueue.global(qos: .utility).async {
						resumeOnce(runInstall())
					}

					// breathing room for install request to reach installd
					DispatchQueue.global(qos: .utility).asyncAfter(deadline: .now() + 1.5) {
						resumeOnce(nil)
					}
				}

				if let earlyError {
					throw IDeviceSwiftError(earlyError)
				}

				// ensure we actually suspend app
				await MainActor.run() {
					UIApplication.shared.perform(#selector(NSXPCConnection.suspend))
				}

				// breathing room for app to suspend
				try await Task.sleep(nanoseconds: 350_000_000)

				CFPreferencesAppSynchronize(kCFPreferencesCurrentApplication)
				exit(0)
			}

			let installError = runInstall()
			
			guard installError == nil else {
				throw IDeviceSwiftError(installError)
			}
			
			try await Task.sleep(nanoseconds: 350_000_000)
			try await self._updateStatus(with: .completed(.success(())))
		}.value
	}
	
	private func _updateStatus(with status: InstallerStatusViewModel.InstallerStatus) async throws {
		await MainActor.run {
			self.viewModel.status = status
		}
	}
	
	private func _updateUploadProgress(with status: Double) async throws {
		await MainActor.run {
			self.viewModel.uploadProgress = status
		}
	}
	
	nonisolated static private let _installationProgressCallback: @convention(c) (
		UInt64,
		UnsafeMutableRawPointer?
	) -> Void = { progress, context in
		guard let context = context else { return }
		let installer = Unmanaged<InstallationProxy>.fromOpaque(context).takeUnretainedValue()
		Task {
			try? await installer._updateInstallProgress(with: Double(progress) / 100.0)
		}
	}
	
	private func _updateInstallProgress(with status: Double) async throws {
		await MainActor.run {
			self.viewModel.installProgress = status
		}
	}
}
