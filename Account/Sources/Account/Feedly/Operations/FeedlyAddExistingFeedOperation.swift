//
//  FeedlyAddExistingFeedOperation.swift
//  Account
//
//  Created by Kiel Gillard on 27/11/19.
//  Copyright © 2019 Ranchero Software, LLC. All rights reserved.
//

import Foundation
import RSWeb
import RSCore
import Secrets

class FeedlyAddExistingFeedOperation: FeedlyOperation, FeedlyOperationDelegate, FeedlyCheckpointOperationDelegate, Logging {

	private let operationQueue = MainThreadOperationQueue()
	var addCompletionHandler: ((Result<Void, Error>) -> ())?

    init(account: Account, credentials: Credentials, resource: FeedlyFeedResourceID, service: FeedlyAddFeedToCollectionService, container: Container, progress: DownloadProgress, customFeedName: String? = nil) throws {
		
		let validator = FeedlyFeedContainerValidator(container: container)
		let (folder, collectionID) = try validator.getValidContainer()
		
		self.operationQueue.suspend()

		super.init()
		
		self.downloadProgress = progress
		
		let addRequest = FeedlyAddFeedToCollectionOperation(account: account, folder: folder, feedResource: resource, feedName: customFeedName, collectionID: collectionID, service: service)
		addRequest.delegate = self
		addRequest.downloadProgress = progress
		self.operationQueue.add(addRequest)
		
		let createFeeds = FeedlyCreateFeedsForCollectionFoldersOperation(account: account, feedsAndFoldersProvider: addRequest)
		createFeeds.downloadProgress = progress
		createFeeds.addDependency(addRequest)
		self.operationQueue.add(createFeeds)
		
		let finishOperation = FeedlyCheckpointOperation()
		finishOperation.checkpointDelegate = self
		finishOperation.downloadProgress = progress
		finishOperation.addDependency(createFeeds)
		self.operationQueue.add(finishOperation)
	}
	
	override func run() {
		operationQueue.resume()
	}

	override func didCancel() {
		operationQueue.cancelAllOperations()
		addCompletionHandler = nil
		super.didCancel()
	}
	
	func feedlyOperation(_ operation: FeedlyOperation, didFailWith error: Error) {
		addCompletionHandler?(.failure(error))
		addCompletionHandler = nil
		
		cancel()
	}
	
	func feedlyCheckpointOperationDidReachCheckpoint(_ operation: FeedlyCheckpointOperation) {
		guard !isCanceled else {
			return
		}
		
		addCompletionHandler?(.success(()))
		addCompletionHandler = nil
		
		didFinish()
	}
}
