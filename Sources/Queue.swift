/**
 * Copyright IBM Corporation 2015
 *
 * Licensed under the Apache License, Version 2.0 (the "License");
 * you may not use this file except in compliance with the License.
 * You may obtain a copy of the License at
 *
 * http://www.apache.org/licenses/LICENSE-2.0
 *
 * Unless required by applicable law or agreed to in writing, software
 * distributed under the License is distributed on an "AS IS" BASIS,
 * WITHOUT WARRANTIES OR CONDITIONS OF ANY KIND, either express or implied.
 * See the License for the specific language governing permissions and
 * limitations under the License.
 **/

import Dispatch

// MARK: Queue

internal class Queue {

    /// 
    /// Lock to ensure
    ///
    private static var onMainOnceLock : Int = 0

    ///
    /// Handle to the libDispatch queue
    ///
    private let osQueue: dispatch_queue_t


    ///
    /// Initializes a Queue instance
    ///
    /// - Parameter type:  QueueType (SERIAL or PARALLEL)
    /// - Parameter label: Optional String describing the Queue
    ///
    /// - Returns: Queue instance 
    ///
    internal init(type: QueueType, label: String?=nil) {
        let concurrent = DISPATCH_QUEUE_CONCURRENT
        let serial = DISPATCH_QUEUE_SERIAL

        osQueue = dispatch_queue_create(label != nil ? label! : "",
            type == QueueType.PARALLEL ? concurrent : serial)
    }


    ///
    /// Run a block asynchronously
    /// 
    /// - Parameter block: a closure () -> Void  
    ///
    internal func queueAsync(_ block: () -> Void) {
        dispatch_async(osQueue, block)
    }

    ///
    /// Run a block synchronously
    ///
    /// - Parameter block: a closure () -> Void
    ///
    internal func queueSync(_ block: () -> Void) {
        dispatch_sync(osQueue, block)
    }


    /// 
    /// Run a block once a main lock has been obtained
    ///
    /// - Parameter queue: Queue
    /// - Parameter block: a closure () -> Void 
    ///
    internal static func queueIfFirstOnMain(queue: Queue, block: () -> Void) {
        var onQueue = true

        SysUtils.doOnce(&onMainOnceLock) {
            dispatch_async(dispatch_get_main_queue(), block);
            onQueue = false
        }

        if  onQueue {
            queue.queueAsync(block)
        }
    }
}

///
/// QueueType values
///
internal enum QueueType {

    case SERIAL, PARALLEL

}
