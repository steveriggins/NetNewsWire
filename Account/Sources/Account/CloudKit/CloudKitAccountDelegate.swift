//
//  CloudKitAppDelegate.swift
//  Account
//
//  Created by Maurice Parker on 3/18/20.
//  Copyright © 2020 Ranchero Software, LLC. All rights reserved.
//

import Foundation
import AccountError
import CloudKit
import SystemConfiguration
import SyncDatabase
import RSCore
import RSParser
import Articles
import ArticlesDatabase
import RSWeb
import Secrets
import FeedFinder
import LocalAccount

enum CloudKitAccountDelegateError: LocalizedError {
	case invalidParameter
	case unknown
	
	var errorDescription: String? {
		return NSLocalizedString("An unexpected CloudKit error occurred.", comment: "An unexpected CloudKit error occurred.")
	}
}

final class CloudKitAccountDelegate: AccountDelegate, Logging {

	private let database: SyncDatabase
	
	private let container: CKContainer = {
		let orgID = Bundle.main.object(forInfoDictionaryKey: "OrganizationIdentifier") as! String
		return CKContainer(identifier: "iCloud.\(orgID).NetNewsWire")
	}()
	
	private let accountZone: CloudKitAccountZone
	private let articlesZone: CloudKitArticlesZone
	
	private let mainThreadOperationQueue = MainThreadOperationQueue()

	private lazy var refresher: LocalAccountRefresher = {
		let refresher = LocalAccountRefresher()
		refresher.delegate = self
		return refresher
	}()

	weak var account: Account?
	
	let behaviors: AccountBehaviors = []
	let isOPMLImportInProgress = false
	
	let server: String? = nil
	var credentials: Credentials?
	var accountMetadata: AccountMetadata?

	var refreshProgress = DownloadProgress(numberOfTasks: 0)
	
	init(dataFolder: String) {
		accountZone = CloudKitAccountZone(container: container)
		articlesZone = CloudKitArticlesZone(container: container)
		
		let databaseFilePath = (dataFolder as NSString).appendingPathComponent("Sync.sqlite3")
		database = SyncDatabase(databaseFilePath: databaseFilePath)
	}
	
	func receiveRemoteNotification(for account: Account, userInfo: [AnyHashable : Any]) async {
		await withCheckedContinuation { continuation in
			let op = CloudKitRemoteNotificationOperation(accountZone: accountZone, articlesZone: articlesZone, userInfo: userInfo)
			op.completionBlock = { mainThreadOperation in
				continuation.resume()
			}
			mainThreadOperationQueue.add(op)
		}
	}

	func refreshAll(for account: Account) async throws {
		guard refreshProgress.isComplete else {
			return
		}

		let reachability = SCNetworkReachabilityCreateWithName(nil, "apple.com")
		var flags = SCNetworkReachabilityFlags()
		guard SCNetworkReachabilityGetFlags(reachability!, &flags), flags.contains(.reachable) else {
			return
		}

		try await withCheckedThrowingContinuation { continuation in
			standardRefreshAll(for: account) { result in
				switch result {
				case .success():
					continuation.resume()
				case .failure(let error):
					continuation.resume(throwing: error)
				}
			}
		}
	}

	func syncArticleStatus(for account: Account) async throws {
		try await sendArticleStatus(for: account)
	}
	
	func sendArticleStatus(for account: Account) async throws {
		try await sendArticleStatus(for: account, showProgress: false)
	}
	
	func refreshArticleStatus(for account: Account) async throws {

		try await withCheckedThrowingContinuation { continuation in

			let op = CloudKitReceiveStatusOperation(articlesZone: self.articlesZone)
			op.completionBlock = { mainThreadOperaion in
				if mainThreadOperaion.isCanceled {
					continuation.resume(throwing: CloudKitAccountDelegateError.unknown)
				} else {
					continuation.resume()
				}
			}

			mainThreadOperationQueue.add(op)
		}
	}
	
	func importOPML(for account:Account, opmlFile: URL, completion: @escaping (Result<Void, Error>) -> Void) {
		guard refreshProgress.isComplete else {
			completion(.success(()))
			return
		}

		var fileData: Data?
		
		do {
			fileData = try Data(contentsOf: opmlFile)
		} catch {
			completion(.failure(error))
			return
		}
		
		guard let opmlData = fileData else {
			completion(.success(()))
			return
		}
		
		let parserData = ParserData(url: opmlFile.absoluteString, data: opmlData)
		var opmlDocument: RSOPMLDocument?
		
		do {
			opmlDocument = try RSOPMLParser.parseOPML(with: parserData)
		} catch {
			completion(.failure(error))
			return
		}
		
		guard let loadDocument = opmlDocument else {
			completion(.success(()))
			return
		}

		guard let opmlItems = loadDocument.children, let rootExternalID = account.externalID else {
			return
		}

		let normalizedItems = OPMLNormalizer.normalize(opmlItems)
		
		refreshProgress.addToNumberOfTasksAndRemaining(1)
		self.accountZone.importOPML(rootExternalID: rootExternalID, items: normalizedItems) { _ in
			self.refreshProgress.completeTask()
			self.standardRefreshAll(for: account, completion: completion)
		}
		
	}
	
	func createFeed(for account: Account, url urlString: String, name: String?, container: Container, validateFeed: Bool, completion: @escaping (Result<Feed, Error>) -> Void) {
		guard let url = URL(string: urlString) else {
			completion(.failure(LocalAccountDelegateError.invalidParameter))
			return
		}
		
		let editedName = name == nil || name!.isEmpty ? nil : name

		// Username should be part of the URL on new feed adds
		createRSSFeed(for: account, url: url, editedName: editedName, container: container, validateFeed: validateFeed, completion: completion)
	}

    func renameFeed(for account: Account, feed: Feed, name: String) async throws {
        let editedName = name.isEmpty ? nil : name
        refreshProgress.addToNumberOfTasksAndRemaining(1)

        try await withCheckedThrowingContinuation { continuation in
            accountZone.renameFeed(feed, editedName: editedName) { result in
                Task { @MainActor in
                    self.refreshProgress.completeTask()
                    switch result {
                    case .success:
                        feed.editedName = name
                        continuation.resume()
                    case .failure(let error):
                        self.processAccountError(account, error)
                        continuation.resume(throwing: error)
                    }
                }
            }
        }
    }

	func renameFeed(for account: Account, with feed: Feed, to name: String, completion: @escaping (Result<Void, Error>) -> Void) {
		let editedName = name.isEmpty ? nil : name
		refreshProgress.addToNumberOfTasksAndRemaining(1)
		accountZone.renameFeed(feed, editedName: editedName) { result in
			self.refreshProgress.completeTask()
			switch result {
			case .success:
				feed.editedName = name
				completion(.success(()))
			case .failure(let error):
				self.processAccountError(account, error)
				completion(.failure(error))
			}
		}
	}

	func removeFeed(for account: Account, with feed: Feed, from container: Container, completion: @escaping (Result<Void, Error>) -> Void) {
		removeFeedFromCloud(for: account, with: feed, from: container) { result in
			switch result {
			case .success:
				account.clearFeedMetadata(feed)
				container.removeFeed(feed)
				completion(.success(()))
			case .failure(let error):
				switch error {
				case CloudKitZoneError.corruptAccount:
					// We got into a bad state and should remove the feed to clear up the bad data
					account.clearFeedMetadata(feed)
					container.removeFeed(feed)
				default:
					completion(.failure(error))
				}
			}
		}
	}
	
	func moveFeed(for account: Account, with feed: Feed, from fromContainer: Container, to toContainer: Container, completion: @escaping (Result<Void, Error>) -> Void) {
		refreshProgress.addToNumberOfTasksAndRemaining(1)
		accountZone.moveFeed(feed, from: fromContainer, to: toContainer) { result in
			self.refreshProgress.completeTask()
			switch result {
			case .success:
				fromContainer.removeFeed(feed)
				toContainer.addFeed(feed)
				completion(.success(()))
			case .failure(let error):
				self.processAccountError(account, error)
				completion(.failure(error))
			}
		}
	}
	
	func addFeed(for account: Account, with feed: Feed, to container: Container, completion: @escaping (Result<Void, Error>) -> Void) {
		refreshProgress.addToNumberOfTasksAndRemaining(1)
		accountZone.addFeed(feed, to: container) { result in
			self.refreshProgress.completeTask()
			switch result {
			case .success:
				container.addFeed(feed)
				completion(.success(()))
			case .failure(let error):
				self.processAccountError(account, error)
				completion(.failure(error))
			}
		}
	}
	
	func restoreFeed(for account: Account, feed: Feed, container: Container, completion: @escaping (Result<Void, Error>) -> Void) {
		createFeed(for: account, url: feed.url, name: feed.editedName, container: container, validateFeed: true) { result in
			switch result {
			case .success:
				completion(.success(()))
			case .failure(let error):
				completion(.failure(error))
			}
		}
	}
	
	func createFolder(for account: Account, name: String) async throws -> Folder {
		refreshProgress.addToNumberOfTasksAndRemaining(1)

		return try await withCheckedThrowingContinuation { continuation in
			accountZone.createFolder(name: name) { result in
				self.refreshProgress.completeTask()
				switch result {
				case .success(let externalID):
					if let folder = account.ensureFolder(with: name) {
						folder.externalID = externalID
						continuation.resume(returning: folder)
					} else {
						continuation.resume(throwing: FeedbinAccountDelegateError.invalidParameter)
					}
				case .failure(let error):
					self.processAccountError(account, error)
					continuation.resume(throwing: error)
				}
			}
		}
	}
	
	func renameFolder(for account: Account, with folder: Folder, to name: String) async throws {
		refreshProgress.addToNumberOfTasksAndRemaining(1)

		try await withCheckedThrowingContinuation { continuation in
			accountZone.renameFolder(folder, to: name) { result in
				self.refreshProgress.completeTask()
				switch result {
				case .success:
					folder.name = name
					continuation.resume()
				case .failure(let error):
					self.processAccountError(account, error)
					continuation.resume(throwing: error)
				}
			}
		}
	}
	
	func removeFolder(for account: Account, with folder: Folder) async throws {

		refreshProgress.addToNumberOfTasksAndRemaining(2)

		try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, Error>) -> Void in

			accountZone.findFeedExternalIDs(for: folder) { result in
				self.refreshProgress.completeTask()
				switch result {
				case .success(let feedExternalIDs):

					let feeds = feedExternalIDs.compactMap { account.existingFeed(withExternalID: $0) }
					let group = DispatchGroup()
					var errorOccurred = false

					for feed in feeds {
						group.enter()
						self.removeFeedFromCloud(for: account, with: feed, from: folder) { [weak self] result in
							group.leave()
							if case .failure(let error) = result {
								self?.logger.error("Remove folder, remove feed error: \(error.localizedDescription, privacy: .public)")
								errorOccurred = true
							}
						}
					}

					group.notify(queue: DispatchQueue.global(qos: .background)) {
						DispatchQueue.main.async {
							guard !errorOccurred else {
								self.refreshProgress.completeTask()
								continuation.resume(throwing: CloudKitAccountDelegateError.unknown)
								return
							}

							self.accountZone.removeFolder(folder) { result in
								self.refreshProgress.completeTask()
								switch result {
								case .success:
									account.removeFolder(folder)
									continuation.resume()
								case .failure(let error):
									continuation.resume(throwing: error)
								}
							}
						}
					}

				case .failure(let error):
					self.refreshProgress.completeTask()
					self.refreshProgress.completeTask()
					self.processAccountError(account, error)
					continuation.resume(throwing: error)
				}
			}
		}

	}
	
	func restoreFolder(for account: Account, folder: Folder, completion: @escaping (Result<Void, Error>) -> Void) {
		guard let name = folder.name else {
			completion(.failure(LocalAccountDelegateError.invalidParameter))
			return
		}
		
		let feedsToRestore = folder.topLevelFeeds
		refreshProgress.addToNumberOfTasksAndRemaining(1 + feedsToRestore.count)
		
		accountZone.createFolder(name: name) { result in
			self.refreshProgress.completeTask()
			switch result {
			case .success(let externalID):
				folder.externalID = externalID
				account.addFolder(folder)
				
				let group = DispatchGroup()
				for feed in feedsToRestore {
					
					folder.topLevelFeeds.remove(feed)

					group.enter()
					self.restoreFeed(for: account, feed: feed, container: folder) { [weak self] result in
						self?.refreshProgress.completeTask()
						group.leave()
						switch result {
						case .success:
							break
						case .failure(let error):
                            self?.logger.error("Restore folder feed error: \(error.localizedDescription, privacy: .public)")
						}
					}
					
				}
				
				group.notify(queue: DispatchQueue.main) {
					account.addFolder(folder)
					completion(.success(()))
				}
				
			case .failure(let error):
				self.processAccountError(account, error)
				completion(.failure(error))
			}
		}
	}

	func markArticles(for account: Account, articles: Set<Article>, statusKey: ArticleStatus.Key, flag: Bool, completion: @escaping (Result<Void, Error>) -> Void) {
		account.update(articles, statusKey: statusKey, flag: flag) { result in
			Task { @MainActor in
				switch result {
				case .success(let articles):
					let syncStatuses = articles.map { article in
						return SyncStatus(articleID: article.articleID, key: SyncStatus.Key(statusKey), flag: flag)
					}

					try? await self.database.insertStatuses(syncStatuses)
					if let count = try? await self.database.selectPendingCount(), count > 100 {
						try? await self.sendArticleStatus(for: account, showProgress: false)
					}
					completion(.success(()))
				case .failure(let error):
					completion(.failure(error))
				}
			}
		}
	}

	func accountDidInitialize(_ account: Account) {
		self.account = account
		refreshProgress.name = account.nameForDisplay
		
		accountZone.delegate = CloudKitAcountZoneDelegate(account: account, refreshProgress: refreshProgress, articlesZone: articlesZone)
		articlesZone.delegate = CloudKitArticlesZoneDelegate(account: account, database: database, articlesZone: articlesZone)

		Task { @MainActor in
			try? await database.resetAllSelectedForProcessing()

			// Check to see if this is a new account and initialize anything we need
			if account.externalID == nil {
				accountZone.findOrCreateAccount() { [weak self] result in
					switch result {
					case .success(let externalID):
						account.externalID = externalID
						self?.initialRefreshAll(for: account) { _ in }
					case .failure(let error):
						self?.logger.error("Error adding account container: \(error.localizedDescription, privacy: .public)")
					}
				}
				accountZone.subscribeToZoneChanges()
				articlesZone.subscribeToZoneChanges()
			}
		}
	}
	
	func accountWillBeDeleted(_ account: Account) {
		accountZone.resetChangeToken()
		articlesZone.resetChangeToken()
	}

	static func validateCredentials(transport: Transport, credentials: Credentials, endpoint: URL? = nil) async throws -> Credentials? {
		nil
	}

	// MARK: Suspend and Resume (for iOS)

	func suspendNetwork() {
		refresher.suspend()
	}

	func suspendDatabase() {
		database.suspend()
	}
	
	func resume() {
		refresher.resume()
		database.resume()
	}
}

private extension CloudKitAccountDelegate {

	func fetchChangesInZone() async throws {

		try await withCheckedThrowingContinuation { continuation in
			self.accountZone.fetchChangesInZone { result in
				switch result {
				case .success:
					continuation.resume()
				case .failure(let error):
					continuation.resume(throwing: error)
				}
			}
		}
	}

	@MainActor func initialRefreshAll(for account : Account) async throws {

		refreshProgress.isIndeterminate = true
		refreshProgress.addToNumberOfTasksAndRemaining(3)

		do {
			try await fetchChangesInZone()
			refreshProgress.completeTask()

			let feeds = account.flattenedFeeds()
			refreshProgress.addToNumberOfTasksAndRemaining(feeds.count)

			try await refreshArticleStatus(for: account)
			refreshProgress.completeTask()
			refreshProgress.isIndeterminate = false

			await combinedRefresh(account, feeds)
			refreshProgress.clear()
			account.metadata.lastArticleFetchEndTime = Date()
		} catch {
			processAccountError(account, error)
			refreshProgress.clear()
			throw error
		}
	}

//	func initialRefreshAll(for account: Account, completion: @escaping (Result<Void, Error>) -> Void) {
//		
//		func fail(_ error: Error) {
//			self.processAccountError(account, error)
//			self.refreshProgress.clear()
//			completion(.failure(error))
//		}
//		
//		refreshProgress.isIndeterminate = true
//		refreshProgress.addToNumberOfTasksAndRemaining(3)
//		accountZone.fetchChangesInZone() { result in
//			self.refreshProgress.completeTask()
//
//			let feeds = account.flattenedFeeds()
//			self.refreshProgress.addToNumberOfTasksAndRemaining(feeds.count)
//
//			switch result {
//			case .success:
//				self.refreshArticleStatus(for: account) { result in
//					self.refreshProgress.completeTask()
//					self.refreshProgress.isIndeterminate = false
//					switch result {
//					case .success:
//						
//						self.combinedRefresh(account, feeds) { result in
//							self.refreshProgress.clear()
//							switch result {
//							case .success:
//								account.metadata.lastArticleFetchEndTime = Date()
//							case .failure(let error):
//								fail(error)
//							}
//						}
//
//					case .failure(let error):
//						fail(error)
//					}
//				}
//			case .failure(let error):
//				fail(error)
//			}
//		}
//
//	}

	func standardRefreshAll(for account: Account, completion: @escaping (Result<Void, Error>) -> Void) {
		
		let intialFeedsCount = account.flattenedFeeds().count
		refreshProgress.isIndeterminate = true
		refreshProgress.addToNumberOfTasksAndRemaining(3 + intialFeedsCount)

		func fail(_ error: Error) {
			self.processAccountError(account, error)
			self.refreshProgress.clear()
			completion(.failure(error))
		}
		
		accountZone.fetchChangesInZone() { result in
			switch result {
			case .success:
				
				self.refreshProgress.completeTask()
				let feeds = account.flattenedFeeds()
				self.refreshProgress.addToNumberOfTasksAndRemaining(feeds.count - intialFeedsCount)
				
				Task { @MainActor in
					do {
						try await self.refreshArticleStatus(for: account)
						self.refreshProgress.completeTask()
						self.refreshProgress.isIndeterminate = false

						self.combinedRefresh(account, feeds) { result in
							do {
								try await self.sendArticleStatus(for: account, showProgress: true)
								if case .failure(let error) = result {
									fail(error)
								} else {
									account.metadata.lastArticleFetchEndTime = Date()
									completion(.success(()))
								}
							} catch {
								fail(error)
							}
						}

					} catch {
						self.refreshProgress.completeTask()
						self.refreshProgress.isIndeterminate = false
					}




				}

				self.refreshArticleStatus(for: account) { result in
					switch result {
					case .success:
						self.refreshProgress.completeTask()
						self.refreshProgress.isIndeterminate = false
						self.combinedRefresh(account, feeds) { result in
							self.sendArticleStatus(for: account, showProgress: true) { _ in
								self.refreshProgress.clear()
								if case .failure(let error) = result {
									fail(error)
								} else {
									account.metadata.lastArticleFetchEndTime = Date()
									completion(.success(()))
								}
							}
						}
					case .failure(let error):
						fail(error)
					}
				}

			case .failure(let error):
				fail(error)
			}
		}
		
	}

	func combinedRefresh(_ account: Account, _ feeds: Set<Feed>) async {

		let feedURLs = Set(feeds.map{ $0.url })
		
		try await withCheckedContinuation { continuation in
			refresher.refreshFeedURLs(feedURLs) {
				continuation.resume()
			}
		}
	}

//    func combinedRefresh(_ account: Account, _ feeds: Set<Feed>, completion: @escaping (Result<Void, Error>) -> Void) {
//
//		let feedURLs = Set(feeds.map{ $0.url })
//        let group = DispatchGroup()
//
//        group.enter()
//        refresher.refreshFeedURLs(feedURLs) {
//            group.leave()
//        }
//
//        group.notify(queue: DispatchQueue.main) {
//            completion(.success(()))
//        }
//    }
	
	func createRSSFeed(for account: Account, url: URL, editedName: String?, container: Container, validateFeed: Bool, completion: @escaping (Result<Feed, Error>) -> Void) {

		func addDeadFeed() {
			let feed = account.createFeed(with: editedName, url: url.absoluteString, feedID: url.absoluteString, homePageURL: nil)
			container.addFeed(feed)

			self.accountZone.createFeed(url: url.absoluteString,
										   name: editedName,
										   editedName: nil,
										   homePageURL: nil,
										   container: container) { result in

				self.refreshProgress.completeTask()
				switch result {
				case .success(let externalID):
					feed.externalID = externalID
					completion(.success(feed))
				case .failure(let error):
					container.removeFeed(feed)
					completion(.failure(error))
				}
			}
		}

		refreshProgress.addToNumberOfTasksAndRemaining(5)

		Task { @MainActor in
			do {
				let feedSpecifiers = try await FeedFinder.find(url: url)
				self.refreshProgress.completeTask()

				guard let bestFeedSpecifier = FeedSpecifier.bestFeed(in: feedSpecifiers), let url = URL(string: bestFeedSpecifier.urlString) else {
					self.refreshProgress.completeTasks(3)
					if validateFeed {
						self.refreshProgress.completeTask()
						completion(.failure(AccountError.createErrorNotFound))
					} else {
						addDeadFeed()
					}
					return
				}

				if account.hasFeed(withURL: bestFeedSpecifier.urlString) {
					self.refreshProgress.completeTasks(4)
					completion(.failure(AccountError.createErrorAlreadySubscribed))
					return
				}

				let feed = account.createFeed(with: nil, url: url.absoluteString, feedID: url.absoluteString, homePageURL: nil)
				feed.editedName = editedName
				container.addFeed(feed)

				InitialFeedDownloader.download(url) { parsedFeed in
					self.refreshProgress.completeTask()

					if let parsedFeed = parsedFeed {
						account.update(feed, with: parsedFeed) { result in
							switch result {
							case .success:

								self.accountZone.createFeed(url: bestFeedSpecifier.urlString,
															name: parsedFeed.title,
															editedName: editedName,
															homePageURL: parsedFeed.homePageURL,
															container: container) { result in

									self.refreshProgress.completeTask()
									switch result {
									case .success(let externalID):
										feed.externalID = externalID
										self.sendNewArticlesToTheCloud(account, feed)
										completion(.success(feed))
									case .failure(let error):
										container.removeFeed(feed)
										self.refreshProgress.completeTasks(2)
										completion(.failure(error))
									}

								}

							case .failure(let error):
								container.removeFeed(feed)
								self.refreshProgress.completeTasks(3)
								completion(.failure(error))
							}

						}
					} else {
						self.refreshProgress.completeTasks(3)
						container.removeFeed(feed)
						completion(.failure(AccountError.createErrorNotFound))
					}

				}
			} catch {
				self.refreshProgress.completeTasks(4)
				if validateFeed {
					self.refreshProgress.completeTask()
					completion(.failure(AccountError.createErrorNotFound))
					return
				} else {
					addDeadFeed()
				}
			}
		}
	}

	func sendNewArticlesToTheCloud(_ account: Account, _ feed: Feed) {
		account.fetchArticlesAsync(.feed(feed)) { result in
			switch result {
			case .success(let articles):
				self.storeArticleChanges(new: articles, updated: Set<Article>(), deleted: Set<Article>()) {
					self.refreshProgress.completeTask()

					Task { @MainActor in
						do {
							try await self.sendArticleStatus(for: account, showProgress: true)
							try await self.refreshArticleStatus(for: account)
						} catch {
							self.logger.error("CloudKit Feed send articles error: \(error.localizedDescription, privacy: .public)")
						}
					}
				}
			case .failure(let error):
                self.logger.error("CloudKit Feed send articles error: \(error.localizedDescription, privacy: .public)")
			}
		}
	}
	
	func processAccountError(_ account: Account, _ error: Error) {
		if case CloudKitZoneError.userDeletedZone = error {
			account.removeFeeds(account.topLevelFeeds)
			for folder in account.folders ?? Set<Folder>() {
				account.removeFolder(folder)
			}
		}
	}
	
	func storeArticleChanges(new: Set<Article>?, updated: Set<Article>?, deleted: Set<Article>?, completion: @escaping () -> Void) {
		// New records with a read status aren't really new, they just didn't have the read article stored
		let group = DispatchGroup()
		if let new = new {
			let filteredNew = new.filter { $0.status.read == false }
			group.enter()
			insertSyncStatuses(articles: filteredNew, statusKey: .new, flag: true) {
				group.leave()
			}
		}

		group.enter()
		insertSyncStatuses(articles: updated, statusKey: .new, flag: false) {
			group.leave()
		}
		
		group.enter()
		insertSyncStatuses(articles: deleted, statusKey: .deleted, flag: true) {
			group.leave()
		}
		
		group.notify(queue: DispatchQueue.global(qos: .userInitiated)) {
			DispatchQueue.main.async {
				completion()
			}
		}
	}
	
	func insertSyncStatuses(articles: Set<Article>?, statusKey: SyncStatus.Key, flag: Bool, completion: @escaping () -> Void) {
		guard let articles = articles, !articles.isEmpty else {
			completion()
			return
		}
		let syncStatuses = articles.map { article in
			return SyncStatus(articleID: article.articleID, key: statusKey, flag: flag)
		}
		Task { @MainActor in
			try? await database.insertStatuses(syncStatuses)
			completion()
		}
	}

	func sendArticleStatus(for account: Account, showProgress: Bool) async throws {

		try await withCheckedThrowingContinuation { continuation in
			let op = CloudKitSendStatusOperation(account: account,
												 articlesZone: self.articlesZone,
												 refreshProgress: self.refreshProgress,
												 showProgress: showProgress,
												 database: self.database)
			op.completionBlock = { mainThreadOperation in
				if mainThreadOperation.isCanceled {
					continuation.resume(throwing: CloudKitAccountDelegateError.unknown)
				} else {
					continuation.resume()
				}
			}

			mainThreadOperationQueue.add(op)
		}
	}
	

	func removeFeedFromCloud(for account: Account, with feed: Feed, from container: Container, completion: @escaping (Result<Void, Error>) -> Void) {
		refreshProgress.addToNumberOfTasksAndRemaining(2)
		accountZone.removeFeed(feed, from: container) { result in
			self.refreshProgress.completeTask()
			switch result {
			case .success:
				guard let feedExternalID = feed.externalID else {
					completion(.success(()))
					return
				}
				self.articlesZone.deleteArticles(feedExternalID) { result in
					feed.dropConditionalGetInfo()
					self.refreshProgress.completeTask()
					completion(result)
				}
			case .failure(let error):
				self.refreshProgress.completeTask()
				self.processAccountError(account, error)
				completion(.failure(error))
			}
		}
	}
	
}

extension CloudKitAccountDelegate: LocalAccountRefresherDelegate {

	func localAccountRefresher(_ refresher: LocalAccountRefresher, requestForFeedURL feedURL: String) -> URLRequest? {

		guard let url = URL(string: feedURL) else {
			return nil
		}

		var request = URLRequest(url: url)
		if let feed = account?.existingFeed(withURL: feedURL) {
			feed.conditionalGetInfo?.addRequestHeadersToURLRequest(&request)
		}

		return request
	}

	func localAccountRefresher(_ refresher: LocalAccountRefresher, feedURL: String, response: URLResponse?, data: Data, error: Error?, completion: @escaping () -> Void) {

		guard !data.isEmpty else {
			completion()
			return
		}

		if let error {
			print("Error downloading \(feedURL) - \(error)")
			completion()
			return
		}

		guard let feed = account?.existingFeed(withURL: feedURL) else {
			completion()
			return
		}

		processFeed(feed, response, data, completion)
	}

	func localAccountRefresher(_ refresher: LocalAccountRefresher, requestCompletedForFeedURL: String) {
		refreshProgress.completeTask()
	}
}

private extension CloudKitAccountDelegate {

	func processFeed(_ feed: Feed, _ response: URLResponse?, _ data: Data, _ completion: @escaping () -> Void) {

		let dataHash = data.md5String
		if dataHash == feed.contentHash {
			completion()
			return
		}

		let parserData = ParserData(url: feed.url, data: data)
		FeedParser.parse(parserData) { (parsedFeed, error) in

			Task { @MainActor in
				guard let account = self.account, let parsedFeed = parsedFeed, error == nil else {
					completion()
					return
				}

				account.update(feed, with: parsedFeed) { result in
					switch result {

					case .success(let articleChanges):
						if let httpResponse = response as? HTTPURLResponse {
							feed.conditionalGetInfo = HTTPConditionalGetInfo(urlResponse: httpResponse)
						}
						feed.contentHash = dataHash

						self.storeArticleChanges(new: articleChanges.newArticles,
												 updated: articleChanges.updatedArticles,
												 deleted: articleChanges.deletedArticles,
												 completion: completion)

					case .failure:
						completion()
					}
				}
			}
		}
	}
}
