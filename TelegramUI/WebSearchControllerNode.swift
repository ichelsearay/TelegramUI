import Foundation
import AsyncDisplayKit
import Postbox
import SwiftSignalKit
import Display
import TelegramCore

private struct WebSearchContextResultStableId: Hashable {
    let result: ChatContextResult
    
    var hashValue: Int {
        return result.id.hashValue
    }
    
    static func ==(lhs: WebSearchContextResultStableId, rhs: WebSearchContextResultStableId) -> Bool {
        return lhs.result == rhs.result
    }
}

private struct WebSearchEntry: Comparable, Identifiable {
    let index: Int
    let result: ChatContextResult
    
    var stableId: WebSearchContextResultStableId {
        return WebSearchContextResultStableId(result: self.result)
    }
    
    static func ==(lhs: WebSearchEntry, rhs: WebSearchEntry) -> Bool {
        return lhs.index == rhs.index && lhs.result == rhs.result
    }
    
    static func <(lhs: WebSearchEntry, rhs: WebSearchEntry) -> Bool {
        return lhs.index < rhs.index
    }
    
    func item(account: Account, theme: PresentationTheme, interfaceState: WebSearchInterfaceState, controllerInteraction: WebSearchControllerInteraction) -> GridItem {
        return WebSearchItem(account: account, theme: theme, interfaceState: interfaceState, result: self.result, controllerInteraction: controllerInteraction)
    }
}

private struct WebSearchTransition {
    let deleteItems: [Int]
    let insertItems: [GridNodeInsertItem]
    let updateItems: [GridNodeUpdateItem]
    let entryCount: Int
    let hasMore: Bool
}

private final class HorizontalListContextResultsOpaqueState {
    let entryCount: Int
    let hasMore: Bool
    
    init(entryCount: Int, hasMore: Bool) {
        self.entryCount = entryCount
        self.hasMore = hasMore
    }
}

private func preparedTransition(from fromEntries: [WebSearchEntry], to toEntries: [WebSearchEntry], hasMore: Bool, account: Account, theme: PresentationTheme, interfaceState: WebSearchInterfaceState, controllerInteraction: WebSearchControllerInteraction) -> WebSearchTransition {
    let (deleteIndices, indicesAndItems, updateIndices) = mergeListsStableWithUpdates(leftList: fromEntries, rightList: toEntries)
    
    let insertions = indicesAndItems.map { GridNodeInsertItem(index: $0.0, item: $0.1.item(account: account, theme: theme, interfaceState: interfaceState, controllerInteraction: controllerInteraction), previousIndex: $0.2) }
    let updates = updateIndices.map { GridNodeUpdateItem(index: $0.0, previousIndex: $0.2, item: $0.1.item(account: account, theme: theme, interfaceState: interfaceState, controllerInteraction: controllerInteraction)) }
    
    return WebSearchTransition(deleteItems: deleteIndices, insertItems: insertions, updateItems: updates, entryCount: toEntries.count, hasMore: hasMore)
}

private func gridNodeLayoutForContainerLayout(size: CGSize) -> GridNodeLayoutType {
    let side = floorToScreenPixels((size.width - 3.0) / 4.0)
    return .fixed(itemSize: CGSize(width: side, height: side), fillWidth: true, lineSpacing: 1.0, itemSpacing: 1.0)
}

class WebSearchControllerNode: ASDisplayNode {
    private let account: Account
    private var theme: PresentationTheme
    private var strings: PresentationStrings
    
    private let controllerInteraction: WebSearchControllerInteraction
    private var webSearchInterfaceState: WebSearchInterfaceState
    private let webSearchInterfaceStatePromise: ValuePromise<WebSearchInterfaceState>
    
    private let segmentedBackgroundNode: ASDisplayNode
    private let segmentedSeparatorNode: ASDisplayNode
    private let segmentedControl: UISegmentedControl
    
    private let toolbarBackgroundNode: ASDisplayNode
    private let toolbarSeparatorNode: ASDisplayNode
    private let cancelButton: HighlightableButtonNode
    private let sendButton: HighlightableButtonNode
    
    private let attributionNode: ASImageNode
    
    private let gridNode: GridNode
    private var enqueuedTransitions: [(WebSearchTransition, Bool)] = []
    private var dequeuedInitialTransitionOnLayout = false
    
    private var currentExternalResults: ChatContextResultCollection?
    private var currentProcessedResults: ChatContextResultCollection?
    private var currentEntries: [WebSearchEntry]?
    private var isLoadingMore = false
    
    private let results =  ValuePromise<ChatContextResultCollection>(ignoreRepeated: true)
    
    
    private let disposable = MetaDisposable()
    private let loadMoreDisposable = MetaDisposable()
    
    private var containerLayout: (ContainerViewLayout, CGFloat)?
    
    var requestUpdateInterfaceState: (Bool, (WebSearchInterfaceState) -> WebSearchInterfaceState) -> Void = { _, _ in }
    var cancel: (() -> Void)?
    
    init(account: Account, theme: PresentationTheme, strings: PresentationStrings, controllerInteraction: WebSearchControllerInteraction) {
        self.account = account
        self.theme = theme
        self.strings = strings
        self.controllerInteraction = controllerInteraction
        
        self.webSearchInterfaceState = WebSearchInterfaceState(presentationData: account.telegramApplicationContext.currentPresentationData.with { $0 })
        self.webSearchInterfaceStatePromise = ValuePromise(self.webSearchInterfaceState, ignoreRepeated: true)
        
        self.segmentedBackgroundNode = ASDisplayNode()
        self.segmentedSeparatorNode = ASDisplayNode()
        
        self.segmentedControl = UISegmentedControl(items: [strings.WebSearch_Images, strings.WebSearch_GIFs])
        self.segmentedControl.selectedSegmentIndex = 0
        
        self.toolbarBackgroundNode = ASDisplayNode()
        self.toolbarSeparatorNode = ASDisplayNode()
        
        self.attributionNode = ASImageNode()
        
        self.cancelButton = HighlightableButtonNode()
        self.sendButton = HighlightableButtonNode()
        
        self.gridNode = GridNode()
        self.gridNode.backgroundColor = theme.list.plainBackgroundColor
        
        super.init()
        
        self.setViewBlock({
            return UITracingLayerView()
        })
        
        self.addSubnode(self.gridNode)
        self.addSubnode(self.segmentedBackgroundNode)
        self.addSubnode(self.segmentedSeparatorNode)
        self.view.addSubview(self.segmentedControl)
        self.addSubnode(self.toolbarBackgroundNode)
        self.addSubnode(self.toolbarSeparatorNode)
        self.addSubnode(self.cancelButton)
        self.addSubnode(self.sendButton)
        self.addSubnode(self.attributionNode)
        
        self.segmentedControl.addTarget(self, action: #selector(self.indexChanged), for: .valueChanged)
        self.cancelButton.addTarget(self, action: #selector(self.cancelPressed), forControlEvents: .touchUpInside)
        self.sendButton.addTarget(self, action: #selector(self.sendPressed), forControlEvents: .touchUpInside)
        
        self.applyPresentationData()
        
        self.disposable.set((combineLatest(self.results.get(), self.webSearchInterfaceStatePromise.get())
        |> deliverOnMainQueue).start(next: { [weak self] results, interfaceState in
            if let strongSelf = self {
                strongSelf.updateInternalResults(results, interfaceState: interfaceState)
            }
        }))
        
        self.gridNode.visibleItemsUpdated = { [weak self] visibleItems in
            //state.hasMore &&
            //if visibleItems.bottom.0 <= state.entryCount - 10 {
            //    strongSelf.loadMore()
            //}
        }
        
//        let selectorRecogizner = ChatGridLiveSelectorRecognizer(target: self, action: #selector(self.panGesture(_:)))
//        selectorRecogizner.shouldBegin = { [weak controllerInteraction] in
//            return controllerInteraction?.selectionState != nil
//        }
//        self.view.addGestureRecognizer(selectorRecogizner)
    }
    
    deinit {
        self.loadMoreDisposable.dispose()
    }
    
    func updatePresentationData(theme: PresentationTheme, strings: PresentationStrings) {
        let themeUpdated = theme !== self.theme
        self.theme = theme
        self.strings = strings
        
        self.applyPresentationData(themeUpdated: themeUpdated)
    }
    
    func applyPresentationData(themeUpdated: Bool = true) {
        self.cancelButton.setTitle(self.strings.Common_Cancel, with: Font.regular(17.0), with: self.theme.rootController.navigationBar.accentTextColor, for: .normal)
        self.sendButton.setTitle(self.strings.MediaPicker_Send, with: Font.medium(17.0), with: self.theme.rootController.navigationBar.accentTextColor, for: .normal)
        
        if themeUpdated {
            self.backgroundColor = self.theme.chatList.backgroundColor
            
            self.segmentedBackgroundNode.backgroundColor = self.theme.rootController.navigationBar.backgroundColor
            self.segmentedSeparatorNode.backgroundColor = self.theme.rootController.navigationBar.separatorColor
            self.segmentedControl.tintColor = self.theme.rootController.navigationBar.accentTextColor
            self.toolbarBackgroundNode.backgroundColor = self.theme.rootController.navigationBar.backgroundColor
            self.toolbarSeparatorNode.backgroundColor = self.theme.rootController.navigationBar.separatorColor
            
            self.attributionNode.image = generateTintedImage(image: UIImage(bundleImageName: "Media Grid/Giphy"), color: self.theme.list.itemSecondaryTextColor)
        }
    }
    
    func animateIn(completion: (() -> Void)? = nil) {
        self.layer.animatePosition(from: CGPoint(x: self.layer.position.x, y: self.layer.position.y + self.layer.bounds.size.height), to: self.layer.position, duration: 0.5, timingFunction: kCAMediaTimingFunctionSpring)
    }
    
    func animateOut(completion: (() -> Void)? = nil) {
        self.layer.animatePosition(from: self.layer.position, to: CGPoint(x: self.layer.position.x, y: self.layer.position.y + self.layer.bounds.size.height), duration: 0.2, timingFunction: kCAMediaTimingFunctionEaseInEaseOut, removeOnCompletion: false, completion: { _ in
            completion?()
        })
    }
    
    func containerLayoutUpdated(_ layout: ContainerViewLayout, navigationBarHeight: CGFloat, transition: ContainedViewLayoutTransition) {
        self.containerLayout = (layout, navigationBarHeight)
        
        var insets = layout.insets(options: [.input])
        insets.top += navigationBarHeight
        
        let segmentedHeight: CGFloat = 40.0
        let panelY: CGFloat = insets.top - UIScreenPixel - 4.0
        
        transition.updateFrame(node: self.segmentedBackgroundNode, frame: CGRect(origin: CGPoint(x: 0.0, y: panelY), size: CGSize(width: layout.size.width, height: segmentedHeight)))
        transition.updateFrame(node: self.segmentedSeparatorNode, frame: CGRect(origin: CGPoint(x: 0.0, y: panelY + segmentedHeight), size: CGSize(width: layout.size.width, height: UIScreenPixel)))
        
        var controlSize = self.segmentedControl.sizeThatFits(layout.size)
        controlSize.width = layout.size.width - layout.safeInsets.left - layout.safeInsets.right - 8.0 * 2.0
        
        transition.updateFrame(view: self.segmentedControl, frame: CGRect(origin: CGPoint(x: layout.safeInsets.left + floor((layout.size.width - layout.safeInsets.left - layout.safeInsets.right - controlSize.width) / 2.0), y: panelY + floor((segmentedHeight - controlSize.height) / 2.0)), size: controlSize))
        
        let toolbarHeight: CGFloat = 44.0
        let toolbarY = layout.size.height - toolbarHeight - insets.bottom
        transition.updateFrame(node: self.toolbarBackgroundNode, frame: CGRect(origin: CGPoint(x: 0.0, y: toolbarY), size: CGSize(width: layout.size.width, height: toolbarHeight + insets.bottom)))
        transition.updateFrame(node: self.toolbarSeparatorNode, frame: CGRect(origin: CGPoint(x: 0.0, y: toolbarY), size: CGSize(width: layout.size.width, height: UIScreenPixel)))
        
        if let image = self.attributionNode.image {
            transition.updateFrame(node: self.attributionNode, frame: CGRect(origin: CGPoint(x: floor((layout.size.width - image.size.width) / 2.0), y: toolbarY + floor((toolbarHeight - image.size.height) / 2.0)), size: image.size))
            transition.updateAlpha(node: self.attributionNode, alpha: self.webSearchInterfaceState.state?.mode == .gifs ? 1.0 : 0.0)
        }
        
        let toolbarPadding: CGFloat = 15.0
        let cancelSize = self.cancelButton.measure(CGSize(width: layout.size.width, height: toolbarHeight))
        transition.updateFrame(node: self.cancelButton, frame: CGRect(origin: CGPoint(x: toolbarPadding + layout.safeInsets.left, y: toolbarY), size: CGSize(width: cancelSize.width, height: toolbarHeight)))
        
        let sendSize = self.sendButton.measure(CGSize(width: layout.size.width, height: toolbarHeight))
        transition.updateFrame(node: self.sendButton, frame: CGRect(origin: CGPoint(x: layout.size.width - toolbarPadding - layout.safeInsets.right - sendSize.width, y: toolbarY), size: CGSize(width: sendSize.width, height: toolbarHeight)))
        
        let previousBounds = self.gridNode.bounds
        self.gridNode.bounds = CGRect(x: previousBounds.origin.x, y: previousBounds.origin.y, width: layout.size.width, height: layout.size.height)
        self.gridNode.position = CGPoint(x: layout.size.width / 2.0, y: layout.size.height / 2.0)
        
        insets.top += segmentedHeight
        insets.bottom += toolbarHeight
        self.gridNode.transaction(GridNodeTransaction(deleteItems: [], insertItems: [], updateItems: [], scrollToItem: nil, updateLayout: GridNodeUpdateLayout(layout: GridNodeLayout(size: layout.size, insets: insets, preloadSize: 400.0, type: gridNodeLayoutForContainerLayout(size: layout.size)), transition: .immediate), itemTransition: .immediate, stationaryItems: .none,updateFirstIndexInSectionOffset: nil), completion: { _ in })
        
        if !self.dequeuedInitialTransitionOnLayout {
            self.dequeuedInitialTransitionOnLayout = true
            self.dequeueTransition()
        }
    }
    
    func updateInterfaceState(_ interfaceState: WebSearchInterfaceState, animated: Bool) {
        self.webSearchInterfaceState = interfaceState
        self.webSearchInterfaceStatePromise.set(self.webSearchInterfaceState)
        
        if let state = interfaceState.state {
            self.segmentedControl.selectedSegmentIndex = Int(state.mode.rawValue)
        }
        
        if let validLayout = self.containerLayout {
            self.containerLayoutUpdated(validLayout.0, navigationBarHeight: validLayout.1, transition: animated ? .animated(duration: 0.4, curve: .spring) : .immediate)
        }
    }
    
    func updateResults(_ results: ChatContextResultCollection) {
        if self.currentExternalResults == results {
            return
        }
        self.currentExternalResults = results
        self.currentProcessedResults = results
        
        self.isLoadingMore = false
        self.loadMoreDisposable.set(nil)
        self.results.set(results)
    }
    
    private func loadMore() {
        guard !self.isLoadingMore, let currentProcessedResults = self.currentProcessedResults, let nextOffset = currentProcessedResults.nextOffset else {
            return
        }
        self.isLoadingMore = true
        self.loadMoreDisposable.set((requestChatContextResults(account: self.account, botId: currentProcessedResults.botId, peerId: currentProcessedResults.peerId, query: currentProcessedResults.query, location: .single(currentProcessedResults.geoPoint), offset: nextOffset)
            |> deliverOnMainQueue).start(next: { [weak self] nextResults in
                guard let strongSelf = self, let nextResults = nextResults else {
                    return
                }
                strongSelf.isLoadingMore = false
                var results: [ChatContextResult] = []
                for result in currentProcessedResults.results {
                    results.append(result)
                }
                for result in nextResults.results {
                    results.append(result)
                }
                let mergedResults = ChatContextResultCollection(botId: currentProcessedResults.botId, peerId: currentProcessedResults.peerId, query: currentProcessedResults.query, geoPoint: currentProcessedResults.geoPoint, queryId: nextResults.queryId, nextOffset: nextResults.nextOffset, presentation: currentProcessedResults.presentation, switchPeer: currentProcessedResults.switchPeer, results: results, cacheTimeout: currentProcessedResults.cacheTimeout)
                strongSelf.currentProcessedResults = mergedResults
                strongSelf.results.set(mergedResults)
            }))
    }
    
    private func updateInternalResults(_ results: ChatContextResultCollection, interfaceState: WebSearchInterfaceState) {
        var entries: [WebSearchEntry] = []
        var index = 0
        var resultIds = Set<WebSearchContextResultStableId>()
        for result in results.results {
            let entry = WebSearchEntry(index: index, result: result)
            if resultIds.contains(entry.stableId) {
                continue
            } else {
                resultIds.insert(entry.stableId)
            }
            entries.append(entry)
            index += 1
        }
        
        let firstTime = self.currentEntries == nil
        let transition = preparedTransition(from: self.currentEntries ?? [], to: entries, hasMore: results.nextOffset != nil, account: self.account, theme: interfaceState.presentationData.theme, interfaceState: interfaceState, controllerInteraction: self.controllerInteraction)
        self.currentEntries = entries
        self.enqueueTransition(transition, firstTime: firstTime)
    }
    
    private func enqueueTransition(_ transition: WebSearchTransition, firstTime: Bool) {
        self.enqueuedTransitions.append((transition, firstTime))
        
        if self.containerLayout != nil {
            while !self.enqueuedTransitions.isEmpty {
                self.dequeueTransition()
            }
        }
    }
    
    private func dequeueTransition() {
        if let (transition, firstTime) = self.enqueuedTransitions.first {
            self.enqueuedTransitions.remove(at: 0)
            
            let completion: (GridNodeDisplayedItemRange) -> Void = { [weak self] visibleRange in
                if let strongSelf = self {
                }
            }
            
            self.gridNode.transaction(GridNodeTransaction(deleteItems: transition.deleteItems, insertItems: transition.insertItems, updateItems: transition.updateItems, scrollToItem: nil, updateLayout: nil, itemTransition: .immediate, stationaryItems: .none, updateFirstIndexInSectionOffset: nil), completion: completion)
        }
    }
    
    @objc private func indexChanged() {
        self.requestUpdateInterfaceState(true) { current in
            if let mode = WebSearchMode(rawValue: Int32(self.segmentedControl.selectedSegmentIndex)) {
                return current.withUpdatedMode(mode)
            }
            return current
        }
    }
    
    @objc private func cancelPressed() {
        self.cancel?()
    }
    
    @objc private func sendPressed() {
        if let results = self.currentProcessedResults {
            self.controllerInteraction.sendSelected(results)
        }
        self.cancel?()
    }
}