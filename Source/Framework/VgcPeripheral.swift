//
//  VirtualGameControllerPeripheral.swift
//  PeripheralVirtualGameControlleriOSSample
//
//  Created by Rob Reuss on 9/13/15.
//  Copyright © 2015 Rob Reuss. All rights reserved.
//
//  Testing git

import Foundation

// No CoreBluetooth or GameController on WatchOS
#if os(iOS) || os(OSX) || os(tvOS)
    import CoreBluetooth
    import GameController
#endif

#if os(iOS)
    import UIKit
    import AudioToolbox
#endif

public let VgcPeripheralDidConnectNotification:      String = "VgcPeripheralDidConnectNotification"
public let VgcPeripheralConnectionFailedNotification:String = "VgcPeripheralConnectionFailed"
public let VgcPeripheralDidDisconnectNotification:   String = "VgcPeripheralDidDisconnectNotification"
public let VgcPeripheralFoundService:                String = "VgcPeripheralFoundService"
public let VgcPeripheralLostService:                 String = "VgcPeripheralLostService"
public let VgcPeripheralDidResetBrowser:             String = "VgcPeripheralDidResetBrowser"
public let VgcSystemMessageNotification:             String = "VgcSystemMessageNotification"
public let VgcPeripheralSetupNotification:           String = "VgcPeripheralSetupNotification"
public let VgcNewPlayerIndexNotification:            String = "VgcNewPlayerIndexNotification"

public class Peripheral: NSObject {
    
    private var vgcDeviceInfo: DeviceInfo!
    var browser: VgcBrowser!
    var playerIndex: GCControllerPlayerIndex!
    weak var controller: VgcController!
    
    #if !(os(tvOS)) && !(os(OSX))
    public var motion: VgcMotionManager!
    #endif

    public var haveConnectionToCentral: Bool = false
    var haveOpenStreamsToCentral: Bool = false
    var connectionAcknowledgementWaitTimeout: NSTimer!
    
    override init() {
        
        super.init()

        haveConnectionToCentral = false
        
        #if !os(watchOS)
            browser = VgcBrowser(peripheral: self)
        #endif
        
        print("Setting up motion manager on peripheral")
        #if !os(OSX) && !os(tvOS)
        motion = VgcMotionManager()
        #endif
        
        playerIndex = GCControllerPlayerIndex.IndexUnset
         
    }
    
    deinit {
        print("Peripheral deinitalized")
        if controller != nil { controller.peripheral = nil }
        controller = nil
    }
    
    ///
    /// Key method used to send a change in an element's state to the
    /// Central or Bridge that we're currently connected to with this
    /// Peripheral.  "State" in this case refers to the Element "value"
    /// property.
    ///
    public func sendElementState(element: Element) {
        
        // As a Peripheral, we don't need a connection to send if we're an EnhancementBridge, using instead the
        // stream associated with the hardware controllers VgcController.
        if haveConnectionToCentral == true || VgcManager.appRole == .EnhancementBridge {
            
            //print("Sending: \(element.name): \(element.value)")
            
            // If we're enhancing a hardware controller with virtual elements, we pass values through to the controller
            // so they appear to the Central as coming from the hardware controller
            if VgcManager.appRole == .EnhancementBridge && VgcController.enhancedController != nil {
                VgcController.enhancedController.peripheral.browser.sendElementStateOverNetService(element)
            } else {
                browser.sendElementStateOverNetService(element)
            }
            
            //print("Element to be mapped: \(element.name)")
            if VgcManager.usePeripheralSideMapping == true {
                // Only map an element if it isn't the result of a mapping
                if (element.mappingComplete == false) {
                    mapElement(element, peripheral: self)
                }
            }
            
            element.mappingComplete = false
            
        } else {
            
            print("ERROR: Attempted to send without a connection: \(element.name): \(element.value)")
            
        }
        
    }
    
    ///
    /// DeviceInfo for the controller represented by this Peripheral instance.
    ///
    public var deviceInfo: DeviceInfo! {
        
        get {
            if vgcDeviceInfo == nil {
                print("ERROR: Required value deviceInfo not set")
                return nil
            }
            return vgcDeviceInfo
        }
        
        set {
            
            vgcDeviceInfo = newValue
            
            #if os(iOS)

                motion.deviceSupportsMotion = deviceInfo.supportsMotion
                
                // Override device info parameter if the hardware doesn't support motion
                if motion.manager.deviceMotionAvailable == false { deviceInfo.supportsMotion = false } else { deviceInfo.supportsMotion = true }
                
            #endif
            
            haveConnectionToCentral = false
            
        }
        
    }
    
    ///
    /// Connect to a Central or Bridge using a VgcService object obtained
    /// by browsing the network.
    ///
    public func connectToService(vgcService: VgcService) {
        browser.connectToService(vgcService)
    }
    
    public func disconnectFromService() {
        
        if haveConnectionToCentral == false { return }
        
        print("Disconnecting from Central")
        
        haveConnectionToCentral = false
        
        browser.disconnectFromCentral()
        
    }
    
    public func browseForServices() {
        
        browser.reset()
        
        print("Browsing for services...")
        
        NSNotificationCenter.defaultCenter().postNotificationName(VgcPeripheralDidResetBrowser, object: nil)
        
        // If we're a bridge, this peripheral is a controller-specific instance.  If the controller is no
        // longer in the array of controllers, it means it has disconnected and we don't want to advertise it
        // any longer.
        if deviceIsTypeOfBridge() {
            let (existsAlready, _) = VgcController.controllerAlreadyExists(controller)
            if existsAlready == false {
                print("Refusing to announce Bridge-to-Central peripheral because it's controller no longer exists.  If the controller is MFi, it may have gone to sleep.")
                return
            }
        }
        
        browser.browseForCentral()
        
    }
    
    public func stopBrowsingForServices() {
        
        if deviceIsTypeOfBridge() {
            print("Refusing to stop browsing for service because I am a BRIDGE")
        } else {
            print("Stopping browsing for services")
        }
        browser.stopBrowsing()
        
    }
    
    public var availableServices: [VgcService] {
        get {
            let services = [VgcService](browser.serviceLookup.values)
            return services
        }
    }
    
    func gotConnectionAcknowledgementTimeout(timer: NSTimer) {
        
        print("Got connection acknowledgement timeout")

        browser.disconnect()
        
        NSNotificationCenter.defaultCenter().postNotificationName(VgcPeripheralConnectionFailedNotification, object: nil)
        
        connectionAcknowledgementWaitTimeout.invalidate()
        
    }
    
    func gotConnectionToCentral() {
        
        print("Got connection to Central (Already? \(haveConnectionToCentral))")
        
        if (haveOpenStreamsToCentral == true) { return }
        
        haveOpenStreamsToCentral = true
        
        connectionAcknowledgementWaitTimeout = NSTimer.scheduledTimerWithTimeInterval(10.0, target: self, selector: "gotConnectionAcknowledgementTimeout:", userInfo: nil, repeats: false)
        
        if deviceIsTypeOfBridge() {
            
            bridgePeripheralDeviceInfoToCentral(controller)
            
        } else {
            
            sendDeviceInfo(deviceInfo)
            
        }
        
    }
    
    func lostConnectionToCentral(vgcService: VgcService) {
        
        print("Peripheral lost connection to \(vgcService.fullName)")
        haveConnectionToCentral = false
        
        NSNotificationCenter.defaultCenter().postNotificationName(VgcPeripheralDidDisconnectNotification, object: nil)
        NSNotificationCenter.defaultCenter().postNotificationName(VgcPeripheralLostService, object: vgcService)
        
        // Avoid situation where a "ghost" instance will end up on the Bridge after a Peripheral
        // disconnects.  This provides support for the situation where a Central disconnects, but
        // a Peripheral is still connected to the Bridge - when the Central returns the Bridge will
        // connect any Peripherals to it.
        if controller != nil { browser.browseForCentral() }

        #if !(os(tvOS))  && !(os(OSX))
            if !deviceIsTypeOfBridge() {
                print("Stopping motion data")
                motion.stop()
            }
        #endif
        
    }
    
    func sendDeviceInfo(deviceInfo: DeviceInfo) {
        
        if (haveOpenStreamsToCentral == false) {
            print("No streams to Central so not sending controller device info")
            return
        }
        
        print("Sending device info for controller \(deviceInfo.vendorName) to \(browser.connectedVgcService.fullName)")
        
        NSKeyedArchiver.setClassName("DeviceInfo", forClass: DeviceInfo.self)
        let element = VgcManager.elements.deviceInfoElement
        element.value = NSKeyedArchiver.archivedDataWithRootObject(deviceInfo)
        print("\(deviceInfo)")
        
        browser.sendDeviceInfoElement(element)

    }
    
    func bridgePeripheralDeviceInfoToCentral(controller: VgcController) {
        
        print("Forwarding controller \(controller.deviceInfo.vendorName) to Central")
        
        let deviceInfo = controller.deviceInfo.copy() as! DeviceInfo
        deviceInfo.vendorName = deviceInfo.vendorName + " (Bridged)"
        if deviceInfo.controllerType == .MFiHardware { deviceInfo.controllerType = .BridgedMFiHardware }
        if deviceInfo.controllerType == .ICadeHardware { deviceInfo.controllerType = .BridgedICadeHardware }
        if deviceInfo.attachedToDevice {
            deviceInfo.profileType = .ExtendedGamepad
            deviceInfo.supportsMotion = true
        }
        if VgcManager.appRole == .EnhancementBridge { deviceInfo.supportsMotion = true }
        
        // microGamepad is only supported when running on Apple TV, so we transform to
        // Gamepad when bridging it over to a Central on iOS or OSX
        if deviceInfo.profileType == .MicroGamepad { deviceInfo.profileType = .Gamepad }
        sendDeviceInfo(deviceInfo)
        
    }
    
    func mapElement(elementToBeMapped: Element, peripheral: Peripheral) {
        
        if let mappedElementIdentifier = Elements.customMappings.mappings[elementToBeMapped.identifier] {
            
            let mappedElement = VgcManager.elements.elementFromIdentifier(mappedElementIdentifier)
            mappedElement.mappingComplete = true
            print("   Mapping \(elementToBeMapped.name) to \(mappedElement.name)")
            mappedElement.value = elementToBeMapped.value
            sendElementState(mappedElement)
            
        }
    }
    
    func vibrateDevice() {
        #if os(iOS)
        AudioServicesPlayAlertSound(UInt32(kSystemSoundID_Vibrate))
        #endif
    }

    
}

