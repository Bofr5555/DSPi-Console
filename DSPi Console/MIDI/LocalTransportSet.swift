//
//  LocalTransportSet.swift
//  DSPi Console
//
//  Several local transports behind one: the iOS app's DSPi on USB MIDI and
//  its demo device in one device list.  `CompositeTransport.local` is a
//  single transport, so this sits in that slot.  Selection goes to whichever
//  member lists the device; the connection, selection, error and
//  notification streams follow the member in use.
//
//  Members are in priority order.  A member that selects a device by itself
//  (a DSPi plugged in) takes over from a lower-priority member (the demo
//  device), or from any member with nothing selected.
//

import Foundation
import Combine

final class LocalTransportSet: DeviceTransport {
    private let members: [any DeviceTransport]
    private var active: any DeviceTransport
    private let lock = NSLock()
    /// Each member's list as last emitted (a publisher may fire before the
    /// member's property holds the new value).
    private var lists: [[DSPiDevice]]

    private let connectedSubject = CurrentValueSubject<Bool, Never>(false)
    private let devicesSubject = CurrentValueSubject<[DSPiDevice], Never>([])
    private let selectedSubject = CurrentValueSubject<DSPiDevice?, Never>(nil)
    private let errorSubject = CurrentValueSubject<String?, Never>(nil)
    private let fanout = NotificationFanout()
    private var memberCancellables = Set<AnyCancellable>()
    private var activeCancellables = Set<AnyCancellable>()

    init(_ members: [any DeviceTransport]) {
        precondition(!members.isEmpty)
        self.members = members
        self.active = members[0]
        self.lists = members.map { $0.availableDevices }
        attach(to: members[0])
        for (i, member) in members.enumerated() {
            member.availableDevicesPublisher
                .sink { [weak self] devices in self?.listChanged(member: i, devices) }
                .store(in: &memberCancellables)
            member.selectedDevicePublisher
                .sink { [weak self] device in self?.memberSelected(i, device) }
                .store(in: &memberCancellables)
        }
    }

    private func listChanged(member: Int, _ devices: [DSPiDevice]) {
        lock.lock()
        lists[member] = devices
        var merged: [DSPiDevice] = []
        for list in lists { merged += list.filter { d in !merged.contains(d) } }
        lock.unlock()
        devicesSubject.send(merged)
    }

    private func index(of transport: any DeviceTransport) -> Int {
        members.firstIndex { $0 === transport } ?? members.count
    }

    private func memberSelected(_ i: Int, _ device: DSPiDevice?) {
        guard device != nil else { return }
        lock.lock(); let current = active; lock.unlock()
        let member = members[i]
        guard member !== current else { return }
        if current.selectedDevice == nil || i < index(of: current) {
            current.disconnect()
            attach(to: member)
        } else {
            // The user's choice stands; the newcomer lets go.
            member.disconnect()
        }
    }

    private func attach(to transport: any DeviceTransport) {
        lock.lock(); active = transport; lock.unlock()
        activeCancellables.removeAll()
        transport.isConnectedPublisher.sink { [weak self] in self?.connectedSubject.send($0) }
            .store(in: &activeCancellables)
        transport.selectedDevicePublisher.sink { [weak self] in self?.selectedSubject.send($0) }
            .store(in: &activeCancellables)
        transport.errorMessagePublisher.sink { [weak self] in self?.errorSubject.send($0) }
            .store(in: &activeCancellables)
        transport.addNotificationObserver { [weak self] in self?.fanout.publish($0) }
            .store(in: &activeCancellables)
    }

    private var current: any DeviceTransport { lock.lock(); defer { lock.unlock() }; return active }

    // MARK: - DeviceTransport

    var session: LinkSessionID { current.session }
    var generation: UInt64 { current.generation }
    var isConnected: Bool { connectedSubject.value }
    var isConnectedPublisher: AnyPublisher<Bool, Never> { connectedSubject.eraseToAnyPublisher() }
    var availableDevices: [DSPiDevice] { devicesSubject.value }
    var availableDevicesPublisher: AnyPublisher<[DSPiDevice], Never> { devicesSubject.eraseToAnyPublisher() }
    var selectedDevice: DSPiDevice? { selectedSubject.value }
    var selectedDevicePublisher: AnyPublisher<DSPiDevice?, Never> { selectedSubject.eraseToAnyPublisher() }
    var errorMessage: String? { errorSubject.value }
    var errorMessagePublisher: AnyPublisher<String?, Never> { errorSubject.eraseToAnyPublisher() }

    func selectDevice(_ device: DSPiDevice) {
        lock.lock(); let owner = lists.firstIndex { $0.contains(device) }; lock.unlock()
        guard let i = owner else { return }
        let member = members[i]
        let previous = current
        if member !== previous {
            previous.disconnect()
            attach(to: member)
        }
        member.selectDevice(device)
    }

    func reconnect() { current.reconnect() }
    func disconnect() { current.disconnect() }
    func markDisconnected() { current.markDisconnected() }

    func sendControlRequest(request: UInt8, value: UInt16, index: UInt16, data: Data) {
        current.sendControlRequest(request: request, value: value, index: index, data: data)
    }

    func getControlResult(request: UInt8, value: UInt16, index: UInt16, length: UInt16) -> Result<Data, LinkStatus> {
        current.getControlResult(request: request, value: value, index: index, length: length)
    }

    func addNotificationObserver(_ handler: @escaping (LinkNotification) -> Void) -> AnyCancellable {
        fanout.add(handler)
    }
}
