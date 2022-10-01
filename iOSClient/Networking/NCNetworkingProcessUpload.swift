//
//  NCNetworkingProcessUpload.swift
//  Nextcloud
//
//  Created by Marino Faggiana on 25/06/2020.
//  Copyright © 2020 Marino Faggiana. All rights reserved.
//
//  Author Marino Faggiana <marino.faggiana@nextcloud.com>
//
//  This program is free software: you can redistribute it and/or modify
//  it under the terms of the GNU General Public License as published by
//  the Free Software Foundation, either version 3 of the License, or
//  (at your option) any later version.
//
//  This program is distributed in the hope that it will be useful,
//  but WITHOUT ANY WARRANTY; without even the implied warranty of
//  MERCHANTABILITY or FITNESS FOR A PARTICULAR PURPOSE.  See the
//  GNU General Public License for more details.
//
//  You should have received a copy of the GNU General Public License
//  along with this program.  If not, see <http://www.gnu.org/licenses/>.
//

import UIKit
import NextcloudKit
import Photos
import Queuer

class NCNetworkingProcessUpload: NSObject {

    var timerProcess: Timer?

    override init() {
        super.init()
        startTimer()
    }

    private func startProcess() {
        if timerProcess?.isValid ?? false {
            DispatchQueue.main.async { self.process() }
        }
    }

    func startTimer() {
        timerProcess?.invalidate()
        timerProcess = Timer.scheduledTimer(timeInterval: 5, target: self, selector: #selector(process), userInfo: nil, repeats: true)
    }

    func stopTimer() {
        timerProcess?.invalidate()
    }

    @objc private func process() {
        guard let account = NCManageDatabase.shared.getActiveAccount(), UIApplication.shared.applicationState == .active else {
            return
        }

        stopTimer()

        var counterUpload: Int = 0
        let sessionSelectors = [NCGlobal.shared.selectorUploadFileNODelete, NCGlobal.shared.selectorUploadFile, NCGlobal.shared.selectorUploadAutoUpload, NCGlobal.shared.selectorUploadAutoUploadAll]
        let metadatasUpload = NCManageDatabase.shared.getMetadatas(predicate: NSPredicate(format: "status == %d OR status == %d", NCGlobal.shared.metadataStatusInUpload, NCGlobal.shared.metadataStatusUploading))
        counterUpload = metadatasUpload.count

        print("[LOG] PROCESS-UPLOAD \(counterUpload)")

        // Update Badge
        let counterBadge = NCManageDatabase.shared.getMetadatas(predicate: NSPredicate(format: "status == %d OR status == %d OR status == %d", NCGlobal.shared.metadataStatusWaitUpload, NCGlobal.shared.metadataStatusInUpload, NCGlobal.shared.metadataStatusUploading))
        NotificationCenter.default.postOnMainThread(name: NCGlobal.shared.notificationCenterUpdateBadgeNumber, userInfo: ["counter":counterBadge.count])

        NCNetworking.shared.getOcIdInBackgroundSession(queue: DispatchQueue.global(), completion: { listOcId in

            for sessionSelector in sessionSelectors {
                if counterUpload < NCGlobal.shared.maxConcurrentOperationUpload {

                    let limit = NCGlobal.shared.maxConcurrentOperationUpload - counterUpload
                    let metadatas = NCManageDatabase.shared.getAdvancedMetadatas(predicate: NSPredicate(format: "sessionSelector == %@ AND status == %d", sessionSelector, NCGlobal.shared.metadataStatusWaitUpload), page: 1, limit: limit, sorted: "date", ascending: true)
                    if metadatas.count > 0 {
                        NKCommon.shared.writeLog("[INFO] PROCESS-UPLOAD find \(metadatas.count) items")
                    }

                    for metadata in metadatas {

                        // Different account
                        if account.account != metadata.account {
                            NKCommon.shared.writeLog("[INFO] Process auto upload skipped file: \(metadata.serverUrl)/\(metadata.fileNameView) on account: \(metadata.account), because the actual account is \(account.account).")
                            continue
                        }

                        // Is already in upload background? skipped
                        if listOcId.contains(metadata.ocId) {
                            NKCommon.shared.writeLog("[INFO] Process auto upload skipped file: \(metadata.serverUrl)/\(metadata.fileNameView), because is already in session.")
                            continue
                        }

                        // Session Extension ? skipped
                        if metadata.session == NCNetworking.shared.sessionIdentifierBackgroundExtension {
                            continue
                        }

                        // Is already in upload E2EE / CHUNK ? exit [ ONLY ONE IN QUEUE ]
                        for metadata in metadatasUpload {
                            if metadata.chunk || metadata.e2eEncrypted {
                                counterUpload = NCGlobal.shared.maxConcurrentOperationUpload
                                continue
                            }
                        }

                        let semaphore = Semaphore()
                        NCUtility.shared.extractFiles(from: metadata) { metadatas in
                            if metadatas.isEmpty {
                                NCManageDatabase.shared.deleteMetadata(predicate: NSPredicate(format: "ocId == %@", metadata.ocId))
                            }
                            for metadata in metadatas {
                                #if !EXTENSION
                                if (metadata.e2eEncrypted || metadata.chunk) && UIApplication.shared.applicationState != .active {  continue }
                                #else
                                if (metadata.e2eEncrypted || metadata.chunk) { continue }
                                #endif
                                let isWiFi = NCNetworking.shared.networkReachability == NKCommon.typeReachability.reachableEthernetOrWiFi
                                if metadata.session == NCNetworking.shared.sessionIdentifierBackgroundWWan && !isWiFi { continue }
                                if let metadata = NCManageDatabase.shared.setMetadataStatus(ocId: metadata.ocId, status: NCGlobal.shared.metadataStatusInUpload) {
                                    NCNetworking.shared.upload(metadata: metadata)
                                }
                                if metadata.e2eEncrypted || metadata.chunk {
                                    counterUpload = NCGlobal.shared.maxConcurrentOperationUpload
                                } else {
                                    counterUpload += 1
                                }
                            }
                            semaphore.continue()
                        }
                        semaphore.wait()
                    }
                }
            }

            // No upload available ? --> Retry Upload in Error
            if counterUpload == 0 {
                let metadatas = NCManageDatabase.shared.getMetadatas(predicate: NSPredicate(format: "status == %d", NCGlobal.shared.metadataStatusUploadError))
                for metadata in metadatas {
                    NCManageDatabase.shared.setMetadataSession(ocId: metadata.ocId, session: NCNetworking.shared.sessionIdentifierBackground, sessionError: "", sessionTaskIdentifier: 0, status: NCGlobal.shared.metadataStatusWaitUpload)
                }
            }
             
            // verify delete Asset Local Identifiers in auto upload (DELETE Photos album)
            #if !EXTENSION
            DispatchQueue.main.async {
                if (counterUpload == 0 && !(UIApplication.shared.delegate as! AppDelegate).isPasscodePresented()) {
                    self.deleteAssetLocalIdentifiers(account: account.account) {
                        self.startTimer()
                    }
                } else {
                    self.startTimer()
                }
            }
            #endif
        })
    }

    #if !EXTENSION
    private func deleteAssetLocalIdentifiers(account: String, completition: @escaping () -> Void) {

        if UIApplication.shared.applicationState != .active {
            completition()
            return
        }
        let metadatasSessionUpload = NCManageDatabase.shared.getMetadatas(predicate: NSPredicate(format: "account == %@ AND session CONTAINS[cd] %@", account, "upload"))
        if !metadatasSessionUpload.isEmpty {
            completition()
            return
        }
        let localIdentifiers = NCManageDatabase.shared.getAssetLocalIdentifiersUploaded(account: account)
        if localIdentifiers.isEmpty {
            completition()
            return
        }
        let assets = PHAsset.fetchAssets(withLocalIdentifiers: localIdentifiers, options: nil)

        PHPhotoLibrary.shared().performChanges({
            PHAssetChangeRequest.deleteAssets(assets as NSFastEnumeration)
        }, completionHandler: { _, _ in
            DispatchQueue.main.async {
                NCManageDatabase.shared.clearAssetLocalIdentifiers(localIdentifiers, account: account)
                completition()
            }
        })
    }
    #endif

    // MARK: -

    @objc func createProcessUploads(metadatas: [tableMetadata], verifyAlreadyExists: Bool = false) {

        var metadatasForUpload: [tableMetadata] = []
        for metadata in metadatas {
            if verifyAlreadyExists {
                if NCManageDatabase.shared.getMetadata(predicate: NSPredicate(format: "account == %@ && serverUrl == %@ && fileName == %@ && session != ''", metadata.account, metadata.serverUrl, metadata.fileName)) != nil {
                    continue
                }
            }
            metadatasForUpload.append(metadata)
        }
        NCManageDatabase.shared.addMetadatas(metadatasForUpload)
        startProcess()
    }

    // MARK: -

    @objc func verifyUploadZombie() {

        var session: URLSession?

        // remove leaning upload share extension
        let metadatasUploadShareExtension = NCManageDatabase.shared.getMetadatas(predicate: NSPredicate(format: "session == %@ AND sessionSelector == %@", NKCommon.shared.sessionIdentifierUpload, NCGlobal.shared.selectorUploadFileShareExtension))
        for metadata in metadatasUploadShareExtension {
            let path = CCUtility.getDirectoryProviderStorageOcId(metadata.ocId)!
            NCManageDatabase.shared.deleteMetadata(predicate: NSPredicate(format: "ocId == %@", metadata.ocId))
            NCManageDatabase.shared.deleteChunks(account: metadata.account, ocId: metadata.ocId)
            NCUtilityFileSystem.shared.deleteFile(filePath: path)
        }
        
        // verify metadataStatusInUpload (BACKGROUND)
        let metadatasInUploadBackground = NCManageDatabase.shared.getMetadatas(
            predicate: NSPredicate(
                format: "(session == %@ OR session == %@ OR session == %@) AND status == %d AND sessionTaskIdentifier == 0",
                NCNetworking.shared.sessionIdentifierBackground,
                NCNetworking.shared.sessionIdentifierBackgroundExtension,
                NCNetworking.shared.sessionIdentifierBackgroundWWan,
                NCGlobal.shared.metadataStatusInUpload))
        for metadata in metadatasInUploadBackground {
            DispatchQueue.main.asyncAfter(deadline: .now() + 5) {
                if let metadata = NCManageDatabase.shared.getMetadata(predicate: NSPredicate(format: "ocId == %@ AND status == %d AND sessionTaskIdentifier == 0", metadata.ocId, NCGlobal.shared.metadataStatusInUpload)) {
                    NCManageDatabase.shared.setMetadataSession(ocId: metadata.ocId, session: NCNetworking.shared.sessionIdentifierBackground, sessionError: "", sessionSelector: nil, sessionTaskIdentifier: 0, status: NCGlobal.shared.metadataStatusWaitUpload)
                }
            }
        }

        // metadataStatusUploading (BACKGROUND)
        let metadatasUploadingBackground = NCManageDatabase.shared.getMetadatas(predicate: NSPredicate(format: "(session == %@ OR session == %@ OR session == %@) AND status == %d", NCNetworking.shared.sessionIdentifierBackground, NCNetworking.shared.sessionIdentifierBackgroundWWan, NCNetworking.shared.sessionIdentifierBackgroundExtension, NCGlobal.shared.metadataStatusUploading))
        for metadata in metadatasUploadingBackground {

            if metadata.session == NCNetworking.shared.sessionIdentifierBackground {
                session = NCNetworking.shared.sessionManagerBackground
            } else if metadata.session == NCNetworking.shared.sessionIdentifierBackgroundWWan {
                session = NCNetworking.shared.sessionManagerBackgroundWWan
            }

            var taskUpload: URLSessionTask?

            session?.getAllTasks(completionHandler: { tasks in
                for task in tasks {
                    if task.taskIdentifier == metadata.sessionTaskIdentifier {
                        taskUpload = task
                    }
                }

                if taskUpload == nil {
                    if let metadata = NCManageDatabase.shared.getMetadata(predicate: NSPredicate(format: "ocId == %@ AND status == %d", metadata.ocId, NCGlobal.shared.metadataStatusUploading)) {
                        NCManageDatabase.shared.setMetadataSession(ocId: metadata.ocId, session: NCNetworking.shared.sessionIdentifierBackground, sessionError: "", sessionSelector: nil, sessionTaskIdentifier: 0, status: NCGlobal.shared.metadataStatusWaitUpload)
                    }
                }
            })
        }

        // metadataStatusUploading OR metadataStatusInUpload (FOREGROUND)
        let metadatasUploading = NCManageDatabase.shared.getMetadatas(predicate: NSPredicate(format: "session == %@ AND (status == %d OR status == %d)", NKCommon.shared.sessionIdentifierUpload, NCGlobal.shared.metadataStatusUploading, NCGlobal.shared.metadataStatusInUpload))
        for metadata in metadatasUploading {
            let fileNameLocalPath = CCUtility.getDirectoryProviderStorageOcId(metadata.ocId, fileNameView: metadata.fileNameView)!
            if NCNetworking.shared.uploadRequest[fileNameLocalPath] == nil {
                NCManageDatabase.shared.setMetadataSession(ocId: metadata.ocId, session: nil, sessionError: "", sessionSelector: nil, sessionTaskIdentifier: 0, status: NCGlobal.shared.metadataStatusWaitUpload)
            }
        }

        // download
        let metadatasDownload = NCManageDatabase.shared.getMetadatas(predicate: NSPredicate(format: "session == %@", NKCommon.shared.sessionIdentifierDownload))
        for metadata in metadatasDownload {
            NCManageDatabase.shared.setMetadataSession(ocId: metadata.ocId, session: "", sessionError: "", sessionSelector: "", sessionTaskIdentifier: 0, status: NCGlobal.shared.metadataStatusNormal)
        }
    }
}
