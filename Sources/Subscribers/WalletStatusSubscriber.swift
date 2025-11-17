//
//  WalletStatusSubscriber.swift
//  Verge Currency
//
//  Created by Swen van Zanten on 11/05/2020.
//  Updated by ChatGPT 2025/11/08
//

import Foundation
import Logging
import Tor


class WalletStatusSubscriber: Subscriber {
    
    enum WalletStatusError: Error {
        case statusNotComplete(status: Vws.WalletStatus)
    }
    
    let applicationRepository: ApplicationRepository
    let walletManager: WalletManagerProtocol
    let log: Logging.Logger
    let fileManager = FileManager.default
    private var torThread: TorThread?
    private var torStarted = false

    // Lazy property for Tor data directory
    lazy var torDataDirectory: URL = {
        let appSupportURL: URL
        do {
            appSupportURL = try fileManager.url(
                for: .applicationSupportDirectory,
                in: .userDomainMask,
                appropriateFor: nil,
                create: true
            )
        } catch {
            fatalError("Unable to access Application Support directory: \(error)")
        }

        let torDir = appSupportURL.appendingPathComponent("tor")
        if !fileManager.fileExists(atPath: torDir.path) {
            do {
                try fileManager.createDirectory(
                    at: torDir,
                    withIntermediateDirectories: true
                )
            } catch {
                fatalError("Unable to create Tor data directory: \(error)")
            }
        }
        return torDir
    }()
    
    // MARK: - Init
    init(applicationRepository: ApplicationRepository,
         walletManager: WalletManagerProtocol,
         log: Logging.Logger) {
        self.applicationRepository = applicationRepository
        self.walletManager = walletManager
        self.log = log
    }

    // MARK: - Tor Configuration
    func makeSafeTorConfiguration(dataDirectory: URL) -> TorConfiguration {
        let config = TorConfiguration()
        
        // Directories
        config.dataDirectory = dataDirectory
        config.cacheDirectory = dataDirectory.appendingPathComponent("cache")
        
        // Networking
        config.socksPort = 0               // system assigns free port
        config.dnsPort = 0                 // system assigns free port
        config.clientOnly = true           // iOS app should not relay traffic
        
        // Optional: reduce disk usage
        config.avoidDiskWrites = true
        
        // Logging
        config.logfile = nil               // disable logging to file
        
        // Tor files
        config.geoipFile = nil             // optional, reduces memory
        config.geoip6File = nil
        
        // Control port
        config.autoControlPort = true
        config.cookieAuthentication = true
        
        // Extra options
        config.options = [
            "MaxCircuitDirtiness": "60",   // lower default 10 min
            "NumCPUs": "1"                 // reduce CPU usage
        ]
        
        return config
    }

    // MARK: - Start Tor
    func startTorIfNeeded(completion: @escaping (Bool) -> Void) {
        guard !torStarted else {
            completion(true)
            return
        }
        
        DispatchQueue.global(qos: .background).async {
            let config = self.makeSafeTorConfiguration(dataDirectory: self.torDataDirectory)
            
            do {
                let thread = try TorThread(configuration: config)
                thread.start()
                
                self.torThread = thread
                self.torStarted = true
                
                DispatchQueue.main.async {
                    completion(true)
                }
            } catch {
                self.log.error("Failed to start Tor: \(error)")
                DispatchQueue.main.async {
                    completion(false)
                }

            }
        }
    }

    // MARK: - Application Boot Handling
    @objc func didBootApplication(notification: Notification) {
        guard self.applicationRepository.setup else {
            return
        }

        Task.detached { [weak self] in
            guard let self = self else { return }

            do {
                let status = try await withCheckedThrowingContinuation { continuation in
                    self.walletManager.getStatus()
                        .then { walletStatus in
                            continuation.resume(returning: walletStatus)
                        }
                        .catch { error in
                            continuation.resume(throwing: error)
                        }
                }
                var walletStatus = status.wallet?.status

                self.log.info("wallet status fetched: \(walletStatus ?? "nil")")

                if walletStatus == "none" || walletStatus != "complete" {
                    self.log.info("wallet status not completed")
                    let walletStatusResult = try await withCheckedThrowingContinuation { continuation in
                        self.walletManager.getWallet()
                            .then { walletStatus in
                                continuation.resume(returning: walletStatus)
                            }
                            .catch { error in
                                continuation.resume(throwing: error)
                            }
                    }
                    walletStatus = walletStatusResult.wallet?.status
                    
                    if walletStatusResult.wallet?.scanStatus != "success" {
                        self.log.info("wallet scan status not succeeded: \(walletStatus ?? "nil")")
                        _ = try await withCheckedThrowingContinuation { continuation in
                            self.walletManager.scanWallet()
                                .then { result in
                                    continuation.resume(returning: result)
                                }
                                .catch { error in
                                    continuation.resume(throwing: error)
                                }
                        }
                    }
                } else {
                    if status.wallet?.scanStatus != "success" {
                        self.log.info("wallet scan status not succeeded: \(walletStatus ?? "nil")")
                        _ = try await withCheckedThrowingContinuation { continuation in
                            self.walletManager.scanWallet()
                                .then { result in
                                    continuation.resume(returning: result)
                                }
                                .catch { error in
                                    continuation.resume(throwing: error)
                                }
                        }
                    }
                }

                self.log.info("wallet status final: \(walletStatus ?? "nil")")
//                self.startTorIfNeeded { success in
//                    if success {
//                        self.log.info("Tor started successfully")
//                    } else {
//                        self.log.error("Failed to start Tor")
//                    }
//                }


            } catch {
                self.log.error("wallet status unexpected error: \(error.localizedDescription)")
            }
        }
    }


    override func getSubscribedEvents() -> [Notification.Name: Selector] {
        return [
            .didBootApplication: #selector(didBootApplication(notification:))
        ]
    }
}
