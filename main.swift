import SwiftUI
import UniformTypeIdentifiers
import Combine
import IOKit
import IOKit.usb


struct ContentView: View {
	@StateObject private var backend = OdinBackend()
	
	@State private var bootloader: String = "Select bootloader file"
	@State private var filesystem: String = "Select filesystem file"
	@State private var celltower: String = "Select cell tower file"
	@State private var csc: String = "Select csc file"
	
	var body: some View {
		VStack(spacing: 20) {
			HStack {
				Circle()
					.fill(backend.isDeviceConnected ? Color.gray : Color.white)
					.frame(width: 12, height: 12)
				Text(backend.isDeviceConnected ? "Samsung device detected please insert a BL, AP, CP, CSC file" : "No device connected! Please plug in your device.")
					.font(.headline)
			}
			.padding(.top)
			
			Divider()
			
			VStack(alignment: .leading, spacing: 15) {
				FilePickerRow(label: "BL", path: $bootloader)
				FilePickerRow(label: "AP", path: $filesystem)
				FilePickerRow(label: "CP", path: $celltower)
				FilePickerRow(label: "CSC", path: $csc)
			}
			.padding(.horizontal)
			
			Divider()
			
			VStack {
				ProgressView(value: backend.flashProgress, total: 1.0)
					.padding(.horizontal)
				Button(action: {
					backend.flash(bl: bootloader, ap: filesystem, cp: celltower, csc: csc)
				}) {
					Text("Flash OS")
						.font(.system(size: 14, weight: .bold))
						.frame(maxWidth: .infinity)
						.padding(.vertical, 10)
				}
				.buttonStyle(.borderedProminent)
				.disabled(!backend.isDeviceConnected || filesystem.contains("Select"))
				.tint(.blue)
			}
			.padding()
		}
		.frame(width: 450, height: 500)
	}
}

struct FilePickerRow: View {
	let label: String
	@Binding var path: String
	
	var body: some View {
		HStack {
			Text(label)
				.frame(width: 40, alignment: .leading)
				.font(.system(.body, design: .monospaced))
			
			Text(path)
				.font(.caption)
				.foregroundColor(.secondary)
				.lineLimit(1)
				.truncationMode(.middle)
				.padding(.horizontal, 8)
				.frame(maxWidth: .infinity, alignment: .leading)
				.background(Color(NSColor.controlBackgroundColor))
				.cornerRadius(4)
			Button("Select") {
				selectFile()
			}
		}
	}
	
	func selectFile() {
		let panel = NSOpenPanel()
		panel.allowsMultipleSelection = false
		panel.canChooseDirectories = false
		panel.allowedContentTypes = [.init(filenameExtension: "tar")!, .init(filenameExtension: "md5")!]
		
		if panel.runModal() == .OK {
			self.path = panel.url?.path ?? "Error"
		}
	}
}

class OdinBackend: ObservableObject {
	@Published var isDeviceConnected: Bool = false
	@Published var flashProgress: Double = 0.0
	@Published var message: String = "Ready"
	
	private var device: io_object_t = 0
	private var interface: UnsafeMutablePointer<UnsafeMutablePointer<IOUSBInterfaceInterface>?>? = nil
	private var cancellables = Set<AnyCancellable>()
	
	
	func openConnection() -> Bool {
		let kDeviceClassNonappleVendorsSamsung = 0x04E8
		let matchingDict = IOServiceMatching(kIOUSBDeviceClassName) as NSMutableDictionary
		matchingDict[kUSBVendorID] = kDeviceClassNonappleVendorsSamsung
		
		var iterator: io_iterator_t = 0
		let log = IOServiceGetMatchingServices(kIOMasterPortDefault, matchingDict, &iterator)
		
		guard log == KERN_SUCCESS else {
			updateUI("IOKit matching error: kern_success no")
			return false
		}
		
		let foundDevices = IOIteratorNext(iterator)
		IOObjectRelease(iterator)
		
		if device != 0 {
			self.device = foundDevices
			self.isDeviceConnected = true
			updateUI("Samsung device detected")
			return true
		}
		
		self.isDeviceConnected = false
		updateUI("No device detected try again later")
		return false
	}
	
	func flash(bl: String, ap: String, cp: String, csc: String) {
		Just(())
			.receive(on: DispatchQueue.global(qos: .userInitiated))
			.sink { [weak self] _ in
				guard let self = self else { return }
				
				guard self.openConnection() else { return }
				
				guard self.sendHandshake() else  {
					self.updateUI("Handshake failed")
					return
				}
				
				let firmwares = [("BL", bl), ("AP", ap), ("CP", cp), ("CSC", csc)]
				for (label, path) in firmwares where !path.contains("Select") {
					self.updateUI("Transferring \(label)...")
					if !self.transfer(at: path) {
						self.updateUI("Failed to transfer \(label)")
						return
					}
				}
				
				self.endSession()
				self.updateUI("PASS | Successfully transferred files, rebooting...")
			}
			.store(in: &cancellables)
		
	}
	
	private func sendHandshake() -> Bool {
		guard let data = "ODIN".data(using: .utf8) else { return false }
		return usbWrite(data: data)
	}
	
	private func transfer(at path: String) -> Bool {
		let filepath = URL(fileURLWithPath: path)
		do {
			let filedata = try Data(contentsOf: filepath, options: .mappedIfSafe)
			let chunksize = 131072
			var offset = 0
			
			
			while offset < filedata.count {
				let currentchunksize = min(chunksize, filedata.count - offset)
				let chunk = filedata.subdata(in: offset..<(offset + currentchunksize))
				
				if !usbWrite(data: chunk) { return false }
				
				offset += currentchunksize
				let progress = Double(offset) / Double(filedata.count)
				
				DispatchQueue.main.async {
					self.flashProgress = progress
				}
			}
			return true
			
		} catch {
			return false
		}
	}
	
	private func usbWrite(data: Data) -> Bool {
		return data.withUnsafeBytes { (buffer: UnsafeRawBufferPointer) -> Bool in
			guard buffer.baseAddress != nil else { return false }
			
			print("log USB: sent \(data.count) bytes")
			return true
		}
		
	}
	
	private func endSession() {
		let rebootCommand = Data([0x00, 0x00, 0x00, 0x02])
		_ = usbWrite(data: rebootCommand)
	}
	
	private func updateUI(_ message: String) {
		DispatchQueue.main.async {
			self.message = message
		}
	}
		
struct ContentView_Previews: PreviewProvider {
		static var previews: some View {
			ContentView()
		}
	}
}

